import Foundation

/// Pulls football sessions from the health pipeline into a durable local
/// index, and matches pipeline sessions to vault packages by start time.
///
/// The pipeline is the HealthKit source of truth (the Watch app writes soccer
/// workouts into HealthKit; the pipeline captures them via the iPhone health
/// export bridge). `startedAt` in `SessionEnvelopeV1` equals the HealthKit
/// workout start time, which is the join key.
public actor PipelineSessionSyncService {
    public struct Configuration: Sendable {
        public let client: HealthPipelineClient
        public let storageDirectory: URL

        public init(client: HealthPipelineClient, storageDirectory: URL) {
            self.client = client
            self.storageDirectory = storageDirectory
        }

        public static func applicationSupport(fileManager: FileManager = .default) throws -> Configuration {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            return Configuration(
                client: HealthPipelineClient(),
                storageDirectory: applicationSupport
                    .appendingPathComponent("FootballPerformance", isDirectory: true)
                    .appendingPathComponent("PipelineSync", isDirectory: true)
            )
        }
    }

    public struct SyncSummaryV1: Sendable, Equatable {
        public let newlySynced: Int
        public let totalSynced: Int
        public let cursorUTC: Date?

        public init(newlySynced: Int, totalSynced: Int, cursorUTC: Date?) {
            self.newlySynced = newlySynced
            self.totalSynced = totalSynced
            self.cursorUTC = cursorUTC
        }
    }

    private struct PersistedState: Codable, Sendable {
        var cursorUTC: Date?
        var sessions: [HealthPipelineSessionV1]

        static let empty = PersistedState(cursorUTC: nil, sessions: [])
    }

    public static let soccerActivityType = "HKWorkoutActivityTypeSoccer"

    private let configuration: Configuration
    private let stateURL: URL
    private var state: PersistedState

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.stateURL = configuration.storageDirectory.appendingPathComponent("pipeline-sync-state.json")
        self.state = (try? Self.load(from: stateURL)) ?? .empty
    }

    /// Fetch soccer sessions recorded since the last sync and append them to
    /// the local index. Idempotent: already-known pipeline IDs are skipped.
    public func syncSoccerSessions() async throws -> SyncSummaryV1 {
        let fetched = try await configuration.client.sessions(
            activityType: Self.soccerActivityType,
            since: state.cursorUTC,
            limit: 500
        )
        guard !fetched.isEmpty else {
            return SyncSummaryV1(newlySynced: 0, totalSynced: state.sessions.count,
                                 cursorUTC: state.cursorUTC)
        }
        let knownIDs = Set(state.sessions.map(\.id))
        let fresh = fetched.filter { !knownIDs.contains($0.id) }
        state.sessions.append(contentsOf: fresh)
        state.sessions.sort { $0.startUTC > $1.startUTC }
        if let latest = fetched.map(\.startUTC).max() {
            state.cursorUTC = latest
        }
        try Self.save(state, to: stateURL)
        return SyncSummaryV1(newlySynced: fresh.count, totalSynced: state.sessions.count,
                             cursorUTC: state.cursorUTC)
    }

    /// All pipeline sessions currently in the local index, newest first.
    public func pipelineSessions() -> [HealthPipelineSessionV1] {
        state.sessions
    }

    /// Recovery metric (160 -> 140, sustained 30 s) for a pipeline session.
    public func recovery(forPipelineSessionID id: Int) -> HealthPipelineRecoveryV1? {
        state.sessions.first { $0.id == id }?.recovery
    }

    /// Match a pipeline session to a vault package by start time (±60 s).
    /// The Watch's `SessionEnvelopeV1.startedAt` equals the HealthKit workout
    /// start, so this is the join between the two stores.
    public func matchingVaultSessionID(
        for pipelineSession: HealthPipelineSessionV1,
        vaultRecords: [FileSessionRepository.SessionRecord]
    ) -> UUID? {
        let tolerance: TimeInterval = 60
        return vaultRecords.first { record in
            abs(record.sessionEnvelope.startedAt.timeIntervalSince(pipelineSession.startUTC)) <= tolerance
        }?.sessionID
    }

    /// Relay a sealed `.footysession` package to the pipeline so the server
    /// keeps a durable copy alongside the HealthKit data.
    @discardableResult
    public func pushPackageToPipeline(sessionID: UUID, packageDigest: Data, packageData: Data) async throws -> HealthPipelinePackageReceiptV1 {
        try await configuration.client.uploadPackage(sessionID: sessionID, digest: packageDigest, package: packageData)
    }

    // MARK: - Persistence

    private static func load(from url: URL) throws -> PersistedState {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { try HealthPipelineDateCodingV1.decode($0) }
        return try decoder.decode(PersistedState.self, from: data)
    }

    private static func save(_ state: PersistedState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { try HealthPipelineDateCodingV1.encode($0, to: $1) }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
