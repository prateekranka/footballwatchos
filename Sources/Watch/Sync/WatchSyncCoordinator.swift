import Combine
import Foundation
@preconcurrency import WatchConnectivity

enum WatchSyncPresentation: Equatable, Sendable {
    case waitingForIPhone
    case importedOnIPhone
    case needsAttention

    var title: String {
        switch self {
        case .waitingForIPhone:
            return "Waiting for iPhone"
        case .importedOnIPhone:
            return "Imported on iPhone"
        case .needsAttention:
            return "Sync needs attention"
        }
    }
}

struct WatchSyncEnqueueResult: Sendable, Equatable {
    let key: WatchTransferOutboxKeyV1?
    let presentation: WatchSyncPresentation
}

/// Bridges launch-time package discovery into the WatchConnectivity outbox.
///
/// Only a live seal used to enqueue its package for transfer, so a recovered
/// `.partial` (or a sealed package whose enqueue was interrupted by a crash)
/// could sit in Watch storage forever while the iPhone stayed empty. Every
/// submission is digest-keyed and idempotent in the outbox, so re-submitting
/// the same file across launches cannot create duplicate transfers.
@MainActor
final class LaunchRecoverySync {
    static let maximumSubmissionsPerFile = 2

    private var submissions: [String: Int] = [:]
    private let submit: @MainActor (URL) async -> Void

    init(submit: @MainActor @escaping (URL) async -> Void) {
        self.submit = submit
    }

    static func live() -> LaunchRecoverySync {
        LaunchRecoverySync { url in
            let result = await WatchSyncCoordinator.shared.enqueueSealedPackage(at: url)
            WatchLog.recorder.info(
                "launchRecoverySync: \(url.lastPathComponent, privacy: .public) -> \(result.key != nil ? "enqueued" : "needs-attention", privacy: .public)"
            )
        }
    }

    func submitDiscoveredPackage(at url: URL) async {
        let filename = url.lastPathComponent
        let submittedCount = submissions[filename, default: 0]
        guard submittedCount < Self.maximumSubmissionsPerFile else {
            WatchLog.recorder.warning(
                "launchRecoverySync: \(filename, privacy: .public) exceeded \(Self.maximumSubmissionsPerFile) submissions; leaving it in Watch storage"
            )
            return
        }
        submissions[filename] = submittedCount + 1
        await submit(url)
    }

    /// A lingering `.partial` recovers into `<stem>.recovered.<uuid>.footysession`.
    /// If an earlier launch already recovered this stem, reuse that file so
    /// Watch storage never holds duplicate recovered copies of one session.
    nonisolated static func recoveredFilename(
        forPartialNamed filename: String,
        discovered: [StoredSessionPackageV1]
    ) -> String? {
        let stem = (filename as NSString).deletingPathExtension
        return discovered
            .filter { $0.kind == .sealed }
            .map(\.filename)
            .first {
                $0.hasPrefix("\(stem).recovered.")
                    && $0.hasSuffix(".\(FootySessionPackageV1.fileExtension)")
            }
    }
}

/// Coordinates only device-to-device file transport. It never treats
/// reachability, `transferFile` submission, or framework completion as proof
/// that the iPhone has imported the private package.
@MainActor
final class WatchSyncCoordinator: NSObject, ObservableObject {
    static let shared = WatchSyncCoordinator()

    @Published private(set) var stateGeneration = 0

    private let session: WCSession?
    private let outbox: WatchTransferOutbox?
    private let diagnosticJournal: WatchDiagnosticJournal?
    private var cachedRecords: [String: WatchTransferOutboxRecordV1] = [:]
    private var outboxFailure: String?
    private var diagnosticSubmissionInProgress = false
    private var receiptRetryTask: Task<Void, Never>?
    private var pendingStatus: WatchSyncStatusV1?
    private var publishedStatus: WatchSyncStatusV1?

    override init() {
        diagnosticJournal = WatchDiagnosticRuntime.shared.journal
        do {
            outbox = try WatchTransferOutbox()
        } catch {
            outbox = nil
            outboxFailure = error.localizedDescription
        }

        if WCSession.isSupported() {
            let session = WCSession.default
            self.session = session
            super.init()
            session.delegate = self
            // Activation starts at launch; it is intentionally unrelated to
            // whether the iPhone happens to be reachable right now.
            session.activate()
        } else {
            self.session = nil
            super.init()
        }

        refreshCachedState()
    }

    func enqueueSealedPackage(at packageURL: URL) async -> WatchSyncEnqueueResult {
        guard let outbox else {
            return WatchSyncEnqueueResult(key: nil, presentation: .needsAttention)
        }

        do {
            let record = try await outbox.enqueue(sealedPackageAt: packageURL)
            await refreshCachedStateNow()
            submitClaimedRecordsIfEligible()
            return WatchSyncEnqueueResult(
                key: record.key,
                presentation: presentation(for: record.key)
            )
        } catch {
            outboxFailure = error.localizedDescription
            stateGeneration &+= 1
            return WatchSyncEnqueueResult(key: nil, presentation: .needsAttention)
        }
    }

    func presentation(for key: WatchTransferOutboxKeyV1?) -> WatchSyncPresentation {
        guard outboxFailure == nil, let key,
              let record = cachedRecords[key.storageKey] else {
            return .needsAttention
        }

        switch record.status {
        case .pending, .queued, .waitingForReceipt:
            return .waitingForIPhone
        case .imported:
            return .importedOnIPhone
        case .retryableFailure:
            return .needsAttention
        }
    }

    /// True when the outbox already holds a record for this exact package
    /// digest, so a discovered file needs no re-inspection or re-enqueue.
    func hasRecord(withDigest digest: SessionDigestV1) async -> Bool {
        guard outboxFailure == nil else { return false }
        if cachedRecords.isEmpty {
            await refreshCachedStateNow()
        }
        return cachedRecords.values.contains { $0.key.packageDigest == digest }
    }

    /// The current outbox records for aggregation. The cache refreshes on
    /// every receipt, framework completion, and enqueue, so this read is
    /// synchronous and never fabricates transfer state.
    func outboxRecords() -> [WatchTransferOutboxRecordV1] {
        Array(cachedRecords.values)
    }

    func retryFailedTransfers() async throws {
        try await outbox?.retryFailedTransfers()
        await refreshCachedStateNow()
        submitClaimedRecordsIfEligible()
    }

    /// Filenames the outbox already tracks, read fresh so a launch-time sweep
    /// does not re-inspect packages the cache has not loaded yet.
    func trackedPackageFilenames() async -> Set<String> {
        await refreshCachedStateNow()
        return Set(cachedRecords.values.map(\.packageFilename))
    }

    func renewFailedTransfers() async throws {
        try await outbox?.renewFailedTransferBudget()
        await refreshCachedStateNow()
        submitClaimedRecordsIfEligible()
    }

    /// Tells the iPhone how many sessions are still on the Watch. Application
    /// context keeps only the latest value and is delivered when the iPhone
    /// app next runs, which suits a status that is replaced, never queued.
    func publish(_ status: WatchSyncStatusV1) {
        pendingStatus = status
        publishPendingStatusIfEligible()
    }

    private func publishPendingStatusIfEligible() {
        guard let status = pendingStatus,
              let session,
              session.activationState == .activated,
              session.isCompanionAppInstalled else { return }
        // Unchanged counts only refresh the "last checked in" time, and not
        // more than once a minute, so a busy outbox does not flood the link.
        if let publishedStatus, publishedStatus.hasSameCounts(as: status),
           status.updatedAt.timeIntervalSince(publishedStatus.updatedAt) < 60 {
            return
        }
        do {
            try session.updateApplicationContext([WatchSyncStatusV1.contextKey: try status.encoded()])
            publishedStatus = status
        } catch {
            WatchLog.recorder.logError("publishSyncStatus failed", error: error)
        }
    }

    private func applyPhoneLibrary(_ library: PhoneLibraryContextV1) async {
        guard let outbox else { return }
        do {
            guard try await outbox.reconcile(withPhoneLibrary: library) else { return }
            WatchLog.recorder.info("phoneLibrary: outbox changed to match \(library.knownSessionIDs.count, privacy: .public) iPhone sessions")
            await refreshCachedStateNow()
            submitClaimedRecordsIfEligible()
        } catch {
            outboxFailure = error.localizedDescription
            stateGeneration &+= 1
        }
    }

    private func activatedOrUpdated() {
        if let session {
            Self.storePlayerProfile(session.receivedApplicationContext)
            if let library = PhoneLibraryContextV1.decode(context: session.receivedApplicationContext) {
                Task { @MainActor [weak self] in
                    await self?.applyPhoneLibrary(library)
                }
            }
        }
        publishPendingStatusIfEligible()
        reconcileOutstandingTransfers()
        submitClaimedRecordsIfEligible()
        submitPendingDiagnosticsIfEligible()
    }

    private func submitPendingDiagnosticsIfEligible() {
        guard !diagnosticSubmissionInProgress,
              let session,
              session.activationState == .activated,
              session.isCompanionAppInstalled,
              let diagnosticJournal else { return }

        diagnosticSubmissionInProgress = true
        let outstandingReportIDs: Set<UUID> = Set(session.outstandingUserInfoTransfers.compactMap { transfer in
            guard let data = transfer.userInfo[WatchDiagnosticTransferCodecV1.reportKey] as? Data,
                  let report = try? WatchDiagnosticTransferCodecV1.decodeReport(data) else {
                return nil
            }
            return report.reportID
        })

        Task { [weak self] in
            let reports = await diagnosticJournal.pendingReports()
            await MainActor.run {
                guard let self else { return }
                for report in reports where !outstandingReportIDs.contains(report.reportID) {
                    guard let payload = try? WatchDiagnosticTransferCodecV1.encodeReport(report) else {
                        continue
                    }
                    session.transferUserInfo([WatchDiagnosticTransferCodecV1.reportKey: payload])
                }
                self.diagnosticSubmissionInProgress = false
            }
        }
    }

    private func reconcileOutstandingTransfers() {
        guard let session, let outbox else { return }
        let keys = Set(session.outstandingFileTransfers.compactMap { transfer in
            Self.transferKey(from: transfer.file.metadata)
        })

        Task { [weak self] in
            do {
                try await outbox.reconcileOutstandingTransfers(keys)
                await self?.refreshCachedStateNow()
                await MainActor.run {
                    self?.submitClaimedRecordsIfEligible()
                }
            } catch {
                await MainActor.run {
                    self?.outboxFailure = error.localizedDescription
                    self?.stateGeneration &+= 1
                }
            }
        }
    }

    /// Files are submitted whenever the framework is activated and a companion
    /// app is installed. `isReachable` is deliberately not consulted because it
    /// would turn a background transfer into an unnecessary online-only flow.
    private func submitClaimedRecordsIfEligible() {
        guard let session,
              session.activationState == .activated,
              session.isCompanionAppInstalled,
              let outbox else { return }

        Task { [weak self] in
            do {
                let records = try await outbox.claimRecordsForTransfer()
                await self?.refreshCachedStateNow()

                for record in records {
                    do {
                        let packageURL = try await outbox.compressedTransferURL(for: record)
                        let envelope = SessionTransferEnvelopeV1(
                            sessionID: record.key.sessionID,
                            packageDigest: record.key.packageDigest,
                            byteCount: record.byteCount,
                            createdAt: record.createdAt
                        )
                        let metadata = try SessionTransferCodecV1.encodeTransferEnvelope(envelope)
                        _ = await MainActor.run {
                            session.transferFile(
                                packageURL,
                                metadata: [SessionTransferCodecV1.metadataKey: metadata]
                            )
                        }
                    } catch {
                        try await outbox.recordFrameworkCompletion(
                            for: record.key,
                            errorDescription: error.localizedDescription
                        )
                    }
                }
                await self?.refreshCachedStateNow()
            } catch {
                await MainActor.run {
                    self?.outboxFailure = error.localizedDescription
                    self?.stateGeneration &+= 1
                }
            }
        }
    }

    private func refreshCachedState() {
        Task { [weak self] in
            await self?.refreshCachedStateNow()
        }
    }

    private func refreshCachedStateNow() async {
        guard let outbox else { return }
        let snapshot = await outbox.snapshot()
        cachedRecords = snapshot.records
        stateGeneration &+= 1
        receiptRetryTask?.cancel()
        receiptRetryTask = nil
        if let deadline = cachedRecords.values
            .filter({ $0.status == .waitingForReceipt })
            .map({ $0.lastUpdatedAt.addingTimeInterval(WatchTransferOutboxStateV1.receiptTimeout) })
            .min() {
            receiptRetryTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                } catch { return }
                self?.submitClaimedRecordsIfEligible()
            }
        }
    }

    nonisolated private static func transferKey(from metadata: [String: Any]?) -> WatchTransferOutboxKeyV1? {
        guard let data = metadata?[SessionTransferCodecV1.metadataKey] as? Data,
              let envelope = try? SessionTransferCodecV1.decodeTransferEnvelope(data) else {
            return nil
        }
        return WatchTransferOutboxKeyV1(
            sessionID: envelope.sessionID,
            packageDigest: envelope.packageDigest
        )
    }
}

extension WatchSyncCoordinator: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            if let error {
                self?.outboxFailure = error.localizedDescription
                self?.stateGeneration &+= 1
            } else if activationState == .activated {
                self?.outboxFailure = nil
                self?.activatedOrUpdated()
            }
        }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.activatedOrUpdated()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        let key = Self.transferKey(from: fileTransfer.file.metadata)
        let errorDescription = error?.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, let outbox, let key else { return }
            do {
                try await outbox.recordFrameworkCompletion(
                    for: key,
                    errorDescription: errorDescription
                )
                await self.refreshCachedStateNow()
            } catch {
                self.outboxFailure = error.localizedDescription
                self.stateGeneration &+= 1
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Self.storePlayerProfile(applicationContext)
        guard let library = PhoneLibraryContextV1.decode(context: applicationContext) else { return }
        Task { @MainActor [weak self] in
            await self?.applyPhoneLibrary(library)
        }
    }

    /// Zero clears the stored value, so removing the age on the iPhone
    /// returns the Watch to its fallback.
    nonisolated static func storePlayerProfile(_ context: [String: Any]) {
        let key = PlayerProfileContextV1.maximumHeartRateKey
        guard let value = context[key] as? Double else { return }
        if let maximum = PlayerProfileContextV1.maximumHeartRate(in: context) {
            UserDefaults.standard.set(maximum, forKey: key)
        } else if value == 0 {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let data = userInfo[SessionTransferCodecV1.receiptKey] as? Data,
           let receipt = try? SessionTransferCodecV1.decodeReceipt(data) {
            Task { @MainActor [weak self] in
                guard let self, let outbox else { return }
                do {
                    _ = try await outbox.recordReceipt(receipt)
                    await self.refreshCachedStateNow()
                } catch {
                    self.outboxFailure = error.localizedDescription
                    self.stateGeneration &+= 1
                }
            }
            return
        }

        if let data = userInfo[WatchDiagnosticTransferCodecV1.receiptKey] as? Data,
           let receipt = try? WatchDiagnosticTransferCodecV1.decodeReceipt(data) {
            Task { @MainActor [weak self] in
                guard let self, let diagnosticJournal else { return }
                do {
                    try await diagnosticJournal.acknowledge(receipt)
                    self.submitPendingDiagnosticsIfEligible()
                } catch {
                    self.outboxFailure = "Watch diagnostics could not record an iPhone receipt."
                    self.stateGeneration &+= 1
                }
            }
        }
    }
}
