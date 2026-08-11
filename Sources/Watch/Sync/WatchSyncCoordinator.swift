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

    private func activatedOrUpdated() {
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
                    let packageURL = await outbox.packageURL(for: record)
                    do {
                        let envelope = SessionTransferEnvelopeV1(
                            sessionID: record.key.sessionID,
                            packageDigest: record.key.packageDigest,
                            byteCount: record.byteCount,
                            createdAt: record.createdAt
                        )
                        let metadata = try SessionTransferCodecV1.encodeTransferEnvelope(envelope)
                        _ = await MainActor.run {
                            // The package is immutable and retained by the
                            // repository. WC owns only this transfer request.
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
