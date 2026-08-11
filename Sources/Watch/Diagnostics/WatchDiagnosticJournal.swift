import Foundation

private struct WatchDiagnosticActiveAttemptV1: Codable, Sendable, Equatable {
    let attemptID: UUID
    let createdAt: Date
    let appVersion: String
    let buildNumber: String
    let operatingSystemVersion: String
    var isArmed: Bool
    var checkpoints: [WatchDiagnosticCheckpointV1]
}

private struct WatchDiagnosticJournalStateV1: Codable, Sendable, Equatable {
    static let schemaVersion = 1

    let schemaVersion: Int
    var activeAttempt: WatchDiagnosticActiveAttemptV1?
    var pendingReports: [WatchDiagnosticReportV1]
    /// Newest-first verbose lines, persisted so a hard kill still leaves the
    /// tail that preceded it. Capped in appendLog.
    var logTail: [String]

    init(
        activeAttempt: WatchDiagnosticActiveAttemptV1? = nil,
        pendingReports: [WatchDiagnosticReportV1] = [],
        logTail: [String] = []
    ) {
        self.schemaVersion = Self.schemaVersion
        self.activeAttempt = activeAttempt
        self.pendingReports = pendingReports
        self.logTail = logTail
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case activeAttempt
        case pendingReports
        case logTail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        activeAttempt = try container.decodeIfPresent(
            WatchDiagnosticActiveAttemptV1.self,
            forKey: .activeAttempt
        )
        pendingReports = try container.decodeIfPresent(
            [WatchDiagnosticReportV1].self,
            forKey: .pendingReports
        ) ?? []
        logTail = try container.decodeIfPresent([String].self, forKey: .logTail) ?? []
    }

    mutating func appendLog(_ line: String) {
        let trimmed = String(line.prefix(300))
        logTail.insert(trimmed, at: 0)
        logTail = Array(logTail.prefix(200))
    }

    mutating func beginLaunch(
        at now: Date,
        appVersion: String,
        buildNumber: String,
        operatingSystemVersion: String
    ) {
        if let previous = activeAttempt, previous.isArmed, !previous.checkpoints.isEmpty {
            let report = WatchDiagnosticReportV1(
                attemptID: previous.attemptID,
                kind: .unexpectedPriorInterruption,
                createdAt: previous.createdAt,
                detectedAt: now,
                appVersion: previous.appVersion,
                buildNumber: previous.buildNumber,
                operatingSystemVersion: previous.operatingSystemVersion,
                checkpoints: previous.checkpoints,
                logTail: logTail
            )
            if !pendingReports.contains(where: { $0.attemptID == report.attemptID }) {
                pendingReports.append(report)
                pendingReports = Array(pendingReports.sorted { $0.detectedAt < $1.detectedAt }.suffix(20))
            }
        }

        activeAttempt = WatchDiagnosticActiveAttemptV1(
            attemptID: UUID(),
            createdAt: now,
            appVersion: appVersion,
            buildNumber: buildNumber,
            operatingSystemVersion: operatingSystemVersion,
            isArmed: false,
            checkpoints: [
                WatchDiagnosticCheckpointV1(
                    sequence: 0,
                    timestamp: now,
                    code: "app_launched"
                )
            ]
        )
    }

    mutating func checkpoint(
        code: String,
        detail: String?,
        armed: Bool?,
        at timestamp: Date
    ) {
        guard var activeAttempt else { return }
        let nextSequence = (activeAttempt.checkpoints.last?.sequence ?? -1) + 1
        activeAttempt.checkpoints.append(
            WatchDiagnosticCheckpointV1(
                sequence: nextSequence,
                timestamp: timestamp,
                code: String(code.prefix(80)),
                detail: detail.map { String($0.prefix(240)) }
            )
        )
        activeAttempt.checkpoints = Array(activeAttempt.checkpoints.suffix(64))
        if let armed {
            activeAttempt.isArmed = armed
        }
        self.activeAttempt = activeAttempt
    }

    mutating func acknowledge(_ receipt: WatchDiagnosticReceiptV1) {
        pendingReports.removeAll { $0.reportID == receipt.reportID }
    }
}

/// Stores small app-owned checkpoints separately from session packages. A
/// report means a previously armed attempt did not reach a terminal checkpoint;
/// it does not claim that Apple recorded a crash.
actor WatchDiagnosticJournal {
    let directory: URL

    private let fileManager: FileManager
    private let stateURL: URL
    private var state: WatchDiagnosticJournalStateV1

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        now: Date = Date(),
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        buildNumber: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) throws {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            self.directory = applicationSupport
                .appendingPathComponent("FootballCapture", isDirectory: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
        }
        self.stateURL = self.directory.appendingPathComponent("watch-diagnostic-state.json", isDirectory: false)

        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try? (self.directory as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)

        if fileManager.fileExists(atPath: stateURL.path) {
            let decoded = try JSONDecoder().decode(
                WatchDiagnosticJournalStateV1.self,
                from: Data(contentsOf: stateURL)
            )
            guard decoded.schemaVersion == WatchDiagnosticJournalStateV1.schemaVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.state = decoded
        } else {
            self.state = WatchDiagnosticJournalStateV1()
        }

        self.state.beginLaunch(
            at: now,
            appVersion: appVersion,
            buildNumber: buildNumber,
            operatingSystemVersion: operatingSystemVersion
        )
        try Self.persist(self.state, to: stateURL)
    }

    func checkpoint(
        _ code: String,
        detail: String? = nil,
        armed: Bool? = nil,
        at timestamp: Date = Date()
    ) throws {
        let previous = state
        state.checkpoint(code: code, detail: detail, armed: armed, at: timestamp)
        let formatted = Self.lineFormatter.string(from: timestamp)
        state.appendLog("\(formatted) checkpoint \(code)" + (detail.map { " \($0)" } ?? ""))
        do {
            try Self.persist(state, to: stateURL)
        } catch {
            WatchLog.journal.error(
                "checkpoint \(code, privacy: .public) could not be persisted; state rolled back — \(error.localizedDescription, privacy: .public)"
            )
            state = previous
            throw error
        }
    }

    /// Appends a verbose line to the persisted tail. Used by WatchLog so the
    /// unified-log messages that precede a hard kill survive inside the next
    /// diagnostic report.
    func appendLog(_ line: String, at timestamp: Date = Date()) {
        let previous = state
        state.appendLog(line)
        guard state != previous else { return }
        do {
            try Self.persist(state, to: stateURL)
        } catch {
            state = previous
            WatchLog.journal.logError("appendLog could not be persisted", error: error)
        }
    }

    /// Reads the crash sidecar written by the signal handler at app death and
    /// prepends it to the tail so the next report carries the last words.
    func ingestCrashSidecar() {
        let sidecarURL = directory.appendingPathComponent("crash-sidecar.txt", isDirectory: false)
        guard fileManager.fileExists(atPath: sidecarURL.path),
              let text = try? String(contentsOf: sidecarURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init)
        for line in lines.reversed() {
            state.appendLog(line)
        }
        try? fileManager.removeItem(at: sidecarURL)
        try? Self.persist(state, to: stateURL)
    }

    private static let lineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    func pendingReports() -> [WatchDiagnosticReportV1] {
        state.pendingReports.sorted { $0.detectedAt < $1.detectedAt }
    }

    func acknowledge(_ receipt: WatchDiagnosticReceiptV1) throws {
        try receipt.validate()
        let previous = state
        state.acknowledge(receipt)
        guard state != previous else { return }
        do {
            try Self.persist(state, to: stateURL)
        } catch {
            state = previous
            throw error
        }
    }

    private static func persist(_ state: WatchDiagnosticJournalStateV1, to stateURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        // Atomic replace is crash-safe for breadcrumb diagnostics. A
        // per-checkpoint fsync is deliberately avoided: the workout startup
        // path records many checkpoints within one second, and forcing a full
        // flash synchronization for each one stalls the exact window in which
        // watchOS may suspend or terminate the app.
        try data.write(to: stateURL, options: .atomic)
    }
}

final class WatchDiagnosticRuntime: @unchecked Sendable {
    static let shared = WatchDiagnosticRuntime()

    let journal: WatchDiagnosticJournal?
    let startupErrorDescription: String?

    private init() {
        do {
            let journal = try WatchDiagnosticJournal()
            self.journal = journal
            self.startupErrorDescription = nil
            WatchLog.tailSink = { [journal] line in
                Task { await journal.appendLog(line) }
            }
            Task { await journal.ingestCrashSidecar() }
            WatchLog.capture(WatchLog.journal, "journal ready; tail capture enabled")
        } catch {
            WatchLog.journal.logError("journal init failed; diagnostics disabled", error: error)
            self.journal = nil
            self.startupErrorDescription = String(describing: error)
        }
    }
}

/// Kept as a minimal hook point so the app can record that crash capture is
/// active. Actual crash evidence comes from the persisted journal tail plus
/// Apple's own .ips crash reports (which sync to the paired iPhone).
enum WatchCrashSidecarWriter {
    static func install() {
        // Installing sigaction handlers here crashed the app at launch on
        // watchOS 26.6 (abort in libsystem_c on the main thread), so signal
        // handlers are deliberately NOT installed.
        WatchLog.capture(WatchLog.journal, "crash capture active (journal tail + .ips)")
    }
}
