import Foundation

public struct SessionPushProgressV1: Sendable, Equatable {
    public let pendingCount: Int
    public let pushedCount: Int
    public let lastError: String?
}

public actor SessionPushOutbox {
    public static let didChange = Notification.Name(
        "com.prateekranka.footballperformance.sessionPushDidChange"
    )

    private struct State: Codable, Sendable {
        var pending: [UUID] = []
        var pushed: [UUID] = []
        var lastPushedUTC: Date?
        var lastError: String?
    }

    private let client: SessionStoreClient
    private let stateURL: URL
    private var state: State
    private var repository: FileSessionRepository?

    public init(
        repository: FileSessionRepository? = nil,
        client: SessionStoreClient = SessionStoreClient(),
        stateURL: URL? = nil
    ) {
        self.repository = repository
        self.client = client
        self.stateURL = stateURL ?? Self.defaultStateURL()
        self.state = (try? Self.load(from: self.stateURL)) ?? State()
    }

    public func enqueue(sessionID: UUID, repository: FileSessionRepository) {
        self.repository = repository
        guard !state.pushed.contains(sessionID), !state.pending.contains(sessionID) else { return }
        state.pending.append(sessionID)
        saveState()
        Self.postChange()
    }

    public func pushOne() async {
        guard let sessionID = state.pending.first, let repository else { return }
        do {
            let detail = try await repository.detail(for: sessionID)
            let exportURL = try await repository.verifiedExportURL(for: sessionID)
            let package = try Data(contentsOf: exportURL)
            try await client.uploadPackage(
                sessionID: sessionID,
                digest: detail.record.packageDigest,
                package: package
            )
            state.pending.removeFirst()
            if !state.pushed.contains(sessionID) { state.pushed.append(sessionID) }
            state.lastPushedUTC = Date()
            state.lastError = nil
        } catch {
            state.lastError = String(describing: error)
        }
        saveState()
        Self.postChange()
    }

    public func progress() -> SessionPushProgressV1 {
        SessionPushProgressV1(
            pendingCount: state.pending.count,
            pushedCount: state.pushed.count,
            lastError: state.lastError
        )
    }

    public func retryAll() async {
        while !state.pending.isEmpty {
            let before = state.pending.count
            await pushOne()
            if state.pending.count == before { break }
        }
    }

    private func saveState() {
        try? Self.save(state, to: stateURL)
    }

    private static func postChange() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    private static func defaultStateURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FootballPerformance", isDirectory: true)
            .appendingPathComponent("session-push-outbox.json", isDirectory: false)
    }

    private static func load(from url: URL) throws -> State {
        try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
    }

    private static func save(_ state: State, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
