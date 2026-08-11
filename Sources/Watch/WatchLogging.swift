import OSLog

/// Shared unified-log channels for the Watch app. Every startup step and every
/// caught error is logged here so a physical-watch failure can be read back
/// from the paired iPhone (Settings → Privacy → Analytics → Analytics Data, or
/// Console.app while the Watch is connected).
enum WatchLog {
    static let recorder = Logger(
        subsystem: "com.prateekranka.footballperformance.watch",
        category: "recorder"
    )
    static let writer = Logger(
        subsystem: "com.prateekranka.footballperformance.watch",
        category: "package-writer"
    )
    static let journal = Logger(
        subsystem: "com.prateekranka.footballperformance.watch",
        category: "diagnostic-journal"
    )
    static let repository = Logger(
        subsystem: "com.prateekranka.footballperformance.watch",
        category: "repository"
    )
    static let motion = Logger(
        subsystem: "com.prateekranka.footballperformance.watch",
        category: "motion"
    )
    static let lifecycle = Logger(
        subsystem: "com.prateekranka.footballperformance.watch",
        category: "lifecycle"
    )

    /// Set by WatchDiagnosticRuntime to forward every captured line into the
    /// persisted journal tail, so the lines that precede a hard kill are
    /// embedded in the next diagnostic report.
    nonisolated(unsafe) static var tailSink: (@Sendable (String) -> Void)?

    /// Logs to the given channel and mirrors the line into the persisted tail.
    static func capture(_ channel: Logger, _ message: String) {
        channel.info("\(message, privacy: .public)")
        tailSink?(message)
    }

    /// Mirrors an already-logged line into the persisted tail.
    static func mirror(_ message: String) {
        tailSink?(message)
    }
}

extension Logger {
    /// Logs an error with its full description plus domain and code, never
    /// silently discarding it, and mirrors it into the persisted journal tail.
    func logError(_ message: String, error underlyingError: Error?) {
        if let underlyingError {
            let nsError = underlyingError as NSError
            let line =
                "\(message) — \(underlyingError.localizedDescription) [\(nsError.domain)#\(nsError.code)]"
            self.error("\(line, privacy: .public)")
            WatchLog.mirror(line)
        } else {
            self.error("\(message, privacy: .public)")
            WatchLog.mirror(message)
        }
    }
}
