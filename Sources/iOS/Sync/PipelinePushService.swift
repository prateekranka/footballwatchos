import Foundation

/// Point-in-time snapshot of pipeline push progress for the Phone sync UI.
public struct PipelinePushProgressV1: Sendable, Equatable {
    public let pushedCount: Int
    public let lastPushedUTC: Date?
    public let lastError: String?

    public init(pushedCount: Int, lastPushedUTC: Date?, lastError: String?) {
        self.pushedCount = pushedCount
        self.lastPushedUTC = lastPushedUTC
        self.lastError = lastError
    }

    public static let empty = PipelinePushProgressV1(pushedCount: 0, lastPushedUTC: nil, lastError: nil)
}

/// Pushes an imported session to the health pipeline: the sealed package blob
/// (`POST /packages`) plus the computed analytics document
/// (`POST /analytics`). Fire-and-forget by design: pipeline availability must
/// never block the WatchConnectivity import receipt. Failures are logged; the
/// raw package stays in the vault and can be re-pushed later.
///
/// Every completed push is recorded in a durable progress file so the Session
/// Library can show a truthful "uploaded X of Y to the server" progress bar.
public actor PipelinePushService {
    /// Draft estimate until a personal baseline exists (Calibration Session).
    public static let defaultEstimatedHRMaxBPM = 190.0

    /// Posted (main queue) whenever a push finishes, success or failure. The
    /// Session Library model observes it to refresh progress.
    public static let progressDidChange = Notification.Name(
        "com.prateekranka.footballperformance.pipelinePushProgress.didChange"
    )

    private struct PersistedState: Codable, Sendable {
        var pushed: [String] = []
        var lastPushedUTC: Date?
        var lastError: String?
    }

    private let client: HealthPipelineClient
    private let stateURL: URL
    private var state: PersistedState

    public init(
        client: HealthPipelineClient = HealthPipelineClient(),
        stateURL: URL? = nil
    ) {
        self.client = client
        self.stateURL = stateURL ?? Self.defaultStateURL()
        self.state = (try? Self.load(from: self.stateURL)) ?? PersistedState()
    }

    public func progress() -> PipelinePushProgressV1 {
        PipelinePushProgressV1(
            pushedCount: state.pushed.count,
            lastPushedUTC: state.lastPushedUTC,
            lastError: state.lastError
        )
    }

    public func pushImportedSession(
        sessionID: UUID,
        repository: FileSessionRepository
    ) async {
        do {
            let detail = try await repository.detail(for: sessionID)
            let exportURL = try await repository.verifiedExportURL(for: sessionID)
            let packageData = try Data(contentsOf: exportURL)

            try await client.uploadPackage(
                sessionID: sessionID,
                digest: detail.record.packageDigest.bytes,
                package: packageData
            )

            let document = SessionAnalystV1.analyticsDocument(
                sessionID: sessionID,
                startedAt: detail.record.sessionEnvelope.startedAt,
                endedAt: detail.record.completion.endedAt,
                heartRate: detail.heartRateSnapshots.map { (timestamp: $0.timestamp, bpm: $0.value) },
                distanceSnapshots: detail.distanceSnapshots.map { (timestamp: $0.timestamp, meters: $0.value) },
                sprints: detail.sprintEvents,
                estimatedHRMaxBPM: Self.defaultEstimatedHRMaxBPM,
                readiness: nil,
                subjective: nil,
                pipelineRecoverySeconds: nil
            )
            try await client.postAnalytics(sessionID: sessionID, document: document)

            recordPushSuccess(sessionID: sessionID)
            NSLog("FootballPerformance pushed session %@ to the pipeline", sessionID.uuidString)
        } catch {
            state.lastError = String(describing: error)
            try? Self.save(state, to: stateURL)
            Self.postProgressChange()
            NSLog("FootballPerformance could not push session %@ to the pipeline: %@",
                  sessionID.uuidString, String(describing: error))
        }
    }

    private func recordPushSuccess(sessionID: UUID) {
        var pushed = Set(state.pushed)
        pushed.insert(sessionID.uuidString)
        state.pushed = Array(pushed).sorted()
        state.lastPushedUTC = Date()
        state.lastError = nil
        try? Self.save(state, to: stateURL)
        Self.postProgressChange()
    }

    private static func postProgressChange() {
        NotificationCenter.default.post(name: progressDidChange, object: nil)
    }

    private static func defaultStateURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("FootballPerformance", isDirectory: true)
            .appendingPathComponent("pipeline-push-state.json", isDirectory: false)
    }

    private static func load(from url: URL) throws -> PersistedState {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(PersistedState.self, from: data)
    }

    private static func save(_ state: PersistedState, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
