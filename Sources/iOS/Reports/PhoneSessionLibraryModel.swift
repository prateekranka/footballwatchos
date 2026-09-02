import Foundation
import SwiftUI

/// Metrics the session detail screen can chart. `heartRate` and `distance`
/// render snapshot series; the motion cases render bounded Core Motion samples.
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

enum PhoneSessionLibraryLoadingPhase: Equatable, Sendable {
    case starting
    case reconciling
    case listing
    case detail
    case package
    case deleting

    var message: String {
        switch self {
        case .starting, .listing:
            return "Loading sessions…"
        case .reconciling:
            return "Reconciling sessions…"
        case .detail:
            return "Loading session…"
        case .package:
            return "Preparing verified package…"
        case .deleting:
            return "Deleting iPhone copy…"
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .starting: 0
        case .reconciling: 1
        case .listing: 2
        case .detail: 3
        case .package: 4
        case .deleting: 4
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
    @Published private(set) var isLoading = true
    @Published private(set) var loadingPhase: PhoneSessionLibraryLoadingPhase = .starting

    private struct LoadingOperation: Sendable {
        let phase: PhoneSessionLibraryLoadingPhase
        let sessionID: UUID?
    }

    private let repository: FileSessionRepository?
    private let diagnosticRepository: PhoneDiagnosticRepository?
    private let startupErrorDescription: String?

    private var activeLoadingOperations: [UInt64: LoadingOperation] = [:]
    private var nextOperationID: UInt64 = 0
    private var nextRequestID: UInt64 = 0
    private var latestRefreshRequestID: UInt64 = 0
    private var latestDetailRequestIDs: [UUID: UInt64] = [:]
    private var latestPackageRequestIDs: [UUID: UInt64] = [:]
    private var hasLoadedInitialState = false

    init(runtime: PhoneTransferRuntime = .shared) {
        self.repository = runtime.repository
        self.diagnosticRepository = runtime.diagnosticRepository
        self.startupErrorDescription = runtime.startupErrorDescription
    }

    var loadingMessage: String {
        loadingPhase.message
    }

    func isLoadingDetail(for sessionID: UUID) -> Bool {
        activeLoadingOperations.values.contains {
            $0.phase == .detail && $0.sessionID == sessionID
        }
    }

    func isPreparingPackage(for sessionID: UUID) -> Bool {
        activeLoadingOperations.values.contains {
            $0.phase == .package && $0.sessionID == sessionID
        }
    }

    func isDeletingIPhoneCopy(for sessionID: UUID) -> Bool {
        activeLoadingOperations.values.contains {
            $0.phase == .deleting && $0.sessionID == sessionID
        }
    }

    func refresh() async {
        let requestID = nextRequest()
        latestRefreshRequestID = requestID
        message = nil

        let reconcileOperation = beginLoading(.reconciling)
        var reconciliationError: String?
        defer { finishLoading(reconcileOperation) }

        guard let repository else {
            guard isCurrentRefresh(requestID) else { return }
            hasLoadedInitialState = true
            message = startupErrorDescription.map { _ in
                "Local iPhone storage is unavailable. No session status can be shown."
            } ?? "Local iPhone storage is unavailable. No session status can be shown."
            return
        }

        do {
            try Task.checkCancellation()
            do {
                try await repository.reconcileOnStartup()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep this error until all current list work has completed. A
                // failure must never briefly replace the loading surface.
                reconciliationError = "Local iPhone storage could not be reconciled, so this library may be incomplete."
            }
            try Task.checkCancellation()
            guard isCurrentRefresh(requestID) else { return }
        } catch is CancellationError {
            return
        } catch {
            return
        }

        let listingOperation = beginLoading(.listing)
        defer { finishLoading(listingOperation) }

        do {
            let listedSessions = await repository.sessions()
            try Task.checkCancellation()
            guard isCurrentRefresh(requestID) else { return }
            sessions = listedSessions
            if let diagnosticRepository {
                watchDiagnostics = await diagnosticRepository.reports()
                try Task.checkCancellation()
            } else {
                watchDiagnostics = []
            }
            hasLoadedInitialState = true
            message = reconciliationError

            if let selectedID = selectedDetail?.record.sessionID {
                await loadDetail(for: selectedID, clearMessage: false)
            }
        } catch is CancellationError {
            return
        } catch {
            // `sessions()` and diagnostics are currently non-throwing, but
            // retain the same truthfulness rule if either becomes throwing.
            guard isCurrentRefresh(requestID) else { return }
            hasLoadedInitialState = true
            message = "The session list could not be loaded."
        }
    }

    func loadDetail(for sessionID: UUID, clearMessage: Bool = true) async {
        let requestID = nextRequest()
        latestDetailRequestIDs[sessionID] = requestID
        if clearMessage { message = nil }

        let operation = beginLoading(.detail, sessionID: sessionID)
        defer { finishLoading(operation) }

        guard let repository else {
            guard isCurrentDetail(sessionID, requestID: requestID) else { return }
            selectedDetail = nil
            exportURL = nil
            message = startupErrorDescription.map { _ in
                "This iPhone copy could not be read. It has not been exported."
            } ?? "This iPhone copy could not be read. It has not been exported."
            return
        }

        do {
            try Task.checkCancellation()
            let detail = try await repository.detail(for: sessionID)
            try Task.checkCancellation()
            guard isCurrentDetail(sessionID, requestID: requestID) else { return }
            selectedDetail = detail
            exportURL = nil
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentDetail(sessionID, requestID: requestID) else { return }
            if selectedDetail?.record.sessionID == sessionID {
                selectedDetail = nil
                exportURL = nil
            }
            message = "This iPhone copy could not be read. It has not been exported."
        }
    }

    func prepareExactExport() async {
        guard let sessionID = selectedDetail?.record.sessionID else { return }
        let requestID = nextRequest()
        latestPackageRequestIDs[sessionID] = requestID
        message = nil

        let operation = beginLoading(.package, sessionID: sessionID)
        defer { finishLoading(operation) }

        guard let repository else {
            guard isCurrentPackage(sessionID, requestID: requestID) else { return }
            exportURL = nil
            message = "The verified package is unavailable because local iPhone storage could not be opened."
            return
        }

        do {
            try Task.checkCancellation()
            let url = try await repository.verifiedExportURL(for: sessionID)
            try Task.checkCancellation()
            guard isCurrentPackage(sessionID, requestID: requestID),
                  selectedDetail?.record.sessionID == sessionID else { return }
            exportURL = url
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentPackage(sessionID, requestID: requestID) else { return }
            exportURL = nil
            message = "The stored package no longer matches its recorded digest, so export is unavailable."
        }
    }

    func deleteIPhoneCopy() async {
        guard let sessionID = selectedDetail?.record.sessionID else { return }
        let requestID = nextRequest()
        latestPackageRequestIDs[sessionID] = requestID

        let operation = beginLoading(.deleting, sessionID: sessionID)
        defer { finishLoading(operation) }

        guard let repository else {
            guard isCurrentPackage(sessionID, requestID: requestID) else { return }
            message = "The iPhone copy could not be deleted. It remains on this device."
            return
        }

        do {
            try Task.checkCancellation()
            _ = try await repository.deleteIPhoneCopy(for: sessionID)
            try Task.checkCancellation()
            guard isCurrentPackage(sessionID, requestID: requestID) else { return }
            selectedDetail = nil
            exportURL = nil
            await refresh()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentPackage(sessionID, requestID: requestID) else { return }
            message = "The iPhone copy could not be deleted. It remains on this device."
        }
    }

    private func nextRequest() -> UInt64 {
        nextRequestID += 1
        return nextRequestID
    }

    private func beginLoading(
        _ phase: PhoneSessionLibraryLoadingPhase,
        sessionID: UUID? = nil
    ) -> UInt64 {
        nextOperationID += 1
        let operationID = nextOperationID
        activeLoadingOperations[operationID] = LoadingOperation(phase: phase, sessionID: sessionID)
        publishLoadingState()
        return operationID
    }

    private func finishLoading(_ operationID: UInt64) {
        guard activeLoadingOperations.removeValue(forKey: operationID) != nil else { return }
        publishLoadingState()
    }

    private func publishLoadingState() {
        if let operation = activeLoadingOperations.values.max(by: {
            if $0.phase.priority != $1.phase.priority {
                return $0.phase.priority < $1.phase.priority
            }
            return ($0.sessionID?.uuidString ?? "") < ($1.sessionID?.uuidString ?? "")
        }) {
            isLoading = true
            loadingPhase = operation.phase
        } else if hasLoadedInitialState {
            isLoading = false
            loadingPhase = .starting
        } else {
            isLoading = true
            loadingPhase = .starting
        }
    }

    private func isCurrentRefresh(_ requestID: UInt64) -> Bool {
        latestRefreshRequestID == requestID
    }

    private func isCurrentDetail(_ sessionID: UUID, requestID: UInt64) -> Bool {
        latestDetailRequestIDs[sessionID] == requestID
    }

    private func isCurrentPackage(_ sessionID: UUID, requestID: UInt64) -> Bool {
        latestPackageRequestIDs[sessionID] == requestID
    }
}
