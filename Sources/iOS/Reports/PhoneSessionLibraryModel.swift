import Foundation
import SwiftUI

/// Metrics the session detail screen can chart. `heartRate` and `distance`
/// render snapshot series; the motion cases render raw Core Motion samples.
enum RecordedMetric: String, CaseIterable, Identifiable, Sendable {
    case heartRate = "Heart rate"
    case distance = "Distance"
    case accelerationMagnitude = "Acceleration"
    case rotationRate = "Rotation"

    var id: String { rawValue }
}

/// One chart-ready motion reading.
///
/// CoreMotion reports timestamps as seconds since the device last booted, so
/// raw values are meaningless to a reader and not comparable across sessions.
/// Charts therefore rebase time to seconds from the FIRST motion sample of the
/// series (the earliest sample lands at t = 0) and label the x axis
/// "Seconds from first sample" accordingly. The choice keeps the mapping
/// deterministic and independent of the device's boot clock.
struct MotionChartPoint: Identifiable, Sendable, Equatable {
    let id: String
    /// Seconds relative to the first sample of the series.
    let timestamp: TimeInterval
    let value: Double

    init(id: String, timestamp: TimeInterval, value: Double) {
        self.id = id
        self.timestamp = timestamp
        self.value = value
    }
}

/// Maps raw motion samples into chart points for the motion metrics.
enum MotionChartBuilder {
    /// Charts never render more than this many points per metric. A 70-minute
    /// match at ~50 Hz yields ~210k accelerometer and ~210k device-motion
    /// samples, far beyond display resolution; dense series are decimated
    /// stride-based (every n-th sample, first sample always kept) to this cap.
    static let maximumChartPoints = 2000

    /// Magnitude of the acceleration vector, sqrt(x² + y² + z²), in g.
    static func accelerationMagnitudePoints(
        from samples: [FileSessionRepository.MotionSamplePoint],
        idPrefix: String
    ) -> [MotionChartPoint] {
        let chosen = decimated(samples)
        guard let firstTimestamp = chosen.first?.timestamp else { return [] }
        return chosen.enumerated().map { index, sample in
            MotionChartPoint(
                id: "\(idPrefix)-\(index)",
                timestamp: sample.timestamp - firstTimestamp,
                value: (sample.x * sample.x + sample.y * sample.y + sample.z * sample.z).squareRoot()
            )
        }
    }

    /// Magnitude of the rotation-rate vector, sqrt(x² + y² + z²), in rad/s.
    static func rotationRatePoints(
        from samples: [FileSessionRepository.DeviceMotionSamplePoint],
        idPrefix: String
    ) -> [MotionChartPoint] {
        let chosen = decimated(samples)
        guard let firstTimestamp = chosen.first?.timestamp else { return [] }
        return chosen.enumerated().map { index, sample in
            let rotation = sample.rotationRate
            return MotionChartPoint(
                id: "\(idPrefix)-\(index)",
                timestamp: sample.timestamp - firstTimestamp,
                value: (rotation.x * rotation.x + rotation.y * rotation.y + rotation.z * rotation.z).squareRoot()
            )
        }
    }

    /// Stride-based decimation: keeps every n-th sample (n chosen so the
    /// result fits `maximumChartPoints`), always keeping the first sample so
    /// the rebased time origin stays stable. Series at or under the cap pass
    /// through unchanged.
    private static func decimated<Sample>(_ samples: [Sample]) -> [Sample] {
        guard samples.count > maximumChartPoints else { return samples }
        let stride = (samples.count + maximumChartPoints - 1) / maximumChartPoints
        guard stride > 1 else { return samples }
        return samples.enumerated().compactMap { index, sample in
            index.isMultiple(of: stride) ? sample : nil
        }
    }
}

@MainActor
final class PhoneSessionLibraryModel: ObservableObject {
    @Published private(set) var sessions: [FileSessionRepository.SessionRecord] = []
    @Published private(set) var watchDiagnostics: [WatchDiagnosticReportV1] = []
    @Published private(set) var selectedDetail: FileSessionRepository.SessionDetail?
    @Published private(set) var exportURL: URL?
    @Published private(set) var message: String?
    @Published private(set) var isLoading = false
    /// True while a Watch package is arriving or being imported.
    @Published private(set) var isReceivingFromWatch = false
    /// How many imported sessions have been pushed to the health pipeline.
    @Published private(set) var pipelinePushedCount = 0
    /// Last successful pipeline push time, if any.
    @Published private(set) var pipelineLastPushedUTC: Date?
    /// Last pipeline push failure, if any.
    @Published private(set) var pipelineLastError: String?
    /// Number of vault sessions waiting to upload to the R2 session store.
    @Published private(set) var outboxPendingCount = 0
    /// Number of vault sessions uploaded to the R2 session store.
    @Published private(set) var outboxPushedCount = 0
    /// Last R2 session-store upload failure, if any.
    @Published private(set) var outboxLastError: String?
    /// In-flight chunked-upload progress (e.g. "part 12 of 69"), if any.
    @Published private(set) var outboxProgressDetail: String?

    private let repository: FileSessionRepository?
    private let diagnosticRepository: PhoneDiagnosticRepository?
    private let pipelinePushService: PipelinePushService?
    private let sessionPushOutbox: SessionPushOutbox?
    private let previewStore: SessionPreviewStore
    private var notificationObservers: [NSObjectProtocol] = []

    /// Derived per-session visuals keyed by session ID. Computed off the
    /// main actor from bounded package scans and cached by digest.
    @Published private(set) var visualSummaries: [UUID: SessionVisualSummary] = [:]

    /// True when local storage could not be opened at all.
    var repositoryUnavailable: Bool { repository == nil }

    var outboxAvailable: Bool { sessionPushOutbox != nil }

    init(runtime: PhoneTransferRuntime = .shared) {
        self.repository = runtime.repository
        self.diagnosticRepository = runtime.diagnosticRepository
        self.pipelinePushService = runtime.pipelinePushService
        self.sessionPushOutbox = runtime.sessionPushOutbox
        self.previewStore = SessionPreviewStore()
        self.message = runtime.startupErrorDescription.map { _ in
            "Local iPhone storage is unavailable. No session status can be shown."
        }

        let receivedName = PhoneWatchConnectivityCoordinator.sessionReceivedNotification
        let importedName = PhoneWatchConnectivityCoordinator.sessionImportedNotification
        let progressName = PipelinePushService.progressDidChange
        let outboxProgressName = SessionPushOutbox.didChange
        for name in [receivedName, importedName, progressName, outboxProgressName] {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleSyncNotification(name: name)
                }
            }
            notificationObservers.append(token)
        }
    }

    private func handleSyncNotification(name: Notification.Name) async {
        switch name {
        case PhoneWatchConnectivityCoordinator.sessionReceivedNotification:
            isReceivingFromWatch = true
        case PhoneWatchConnectivityCoordinator.sessionImportedNotification:
            isReceivingFromWatch = false
            await refresh()
        case PipelinePushService.progressDidChange:
            await refreshPipelineProgress()
        case SessionPushOutbox.didChange:
            await refreshOutboxProgress()
        default:
            break
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        if let repository {
            do {
                try await repository.reconcileOnStartup()
                sessions = await repository.sessions()
            } catch {
                message = "Local iPhone storage could not be reconciled, so this library may be incomplete."
                sessions = await repository.sessions()
            }
        }
        if let diagnosticRepository {
            watchDiagnostics = await diagnosticRepository.reports()
        }
        await refreshPipelineProgress()
        await refreshOutboxProgress()
        if let selectedID = selectedDetail?.record.sessionID {
            await loadDetail(for: selectedID, clearMessage: false)
        }
    }

    /// Reads the durable pipeline push progress into the published state that
    /// drives the Session Library sync bar.
    func refreshPipelineProgress() async {
        guard let pipelinePushService else { return }
        let progress = await pipelinePushService.progress()
        pipelinePushedCount = progress.pushedCount
        pipelineLastPushedUTC = progress.lastPushedUTC
        pipelineLastError = progress.lastError
    }

    /// Reads durable R2 session-store progress into the published banner state.
    func refreshOutboxProgress() async {
        guard let sessionPushOutbox else { return }
        let progress = await sessionPushOutbox.progress()
        outboxPendingCount = progress.pendingCount
        outboxPushedCount = progress.pushedCount
        outboxLastError = progress.lastError
        outboxProgressDetail = progress.uploadDetail
    }

    /// Re-enqueues every waiting backup upload.
    func retryPendingUploads() async {
        guard let sessionPushOutbox else { return }
        await sessionPushOutbox.retryAll()
        await refreshOutboxProgress()
    }

    /// Prepares derived visuals for the newest sessions. The featured card
    /// gets the first budget; older rows compute on demand when shown.
    func prepareVisualSummaries(budget: Int = 1) async {
        guard let repository, !sessions.isEmpty else { return }
        await previewStore.prepare(
            records: sessions,
            repository: repository,
            budget: budget
        )
        visualSummaries = await previewStore.snapshot()
    }

    /// Requests the visual summary for one visible row, computed at utility
    /// priority so scrolling never waits on package scans.
    func requestVisualSummary(for sessionID: UUID) {
        guard let repository,
              let record = sessions.first(where: { $0.sessionID == sessionID }),
              visualSummaries[sessionID] == nil else {
            return
        }
        Task(priority: .utility) {
            await previewStore.prepare(records: [record], repository: repository, budget: 1)
            let snapshot = await previewStore.snapshot()
            if !snapshot.isEmpty {
                visualSummaries = snapshot
            }
        }
    }

    func loadDetail(for sessionID: UUID, clearMessage: Bool = true) async {
        guard let repository else { return }
        if clearMessage { message = nil }
        do {
            selectedDetail = try await repository.detail(for: sessionID)
            exportURL = nil
        } catch {
            let shortID = sessionID.uuidString.lowercased().prefix(8)
            message = "Session \(shortID) could not be read: \(String(describing: error))."
        }
    }

    func prepareExactExport() async {
        guard let repository, let sessionID = selectedDetail?.record.sessionID else { return }
        message = nil
        do {
            exportURL = try await repository.verifiedExportURL(for: sessionID)
        } catch {
            exportURL = nil
            let shortID = sessionID.uuidString.lowercased().prefix(8)
            message = "Session \(shortID) could not be read: \(String(describing: error))."
        }
    }

    func deleteIPhoneCopy() async {
        guard let repository, let sessionID = selectedDetail?.record.sessionID else { return }
        do {
            _ = try await repository.deleteIPhoneCopy(for: sessionID)
            selectedDetail = nil
            exportURL = nil
            await refresh()
        } catch {
            message = "The iPhone copy could not be deleted. It remains on this device."
        }
    }
}
