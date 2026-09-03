import Foundation

/// Formats a session identity for display: start time + recorded duration.
/// Never the opaque package filename. Used by the recorder's recovery
/// messages and the Session Recovery screen.
enum SessionDisplayFormatting {
    /// e.g. "Mon 31 Aug · 9:00 PM" (locale-driven).
    static func sessionTime(_ date: Date) -> String {
        date.formatted(
            .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        )
    }

    /// e.g. "1h 31m", "45 min", "32 s".
    static func shortDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes) min"
        }
        return "\(totalSeconds) s"
    }

    /// "Mon 31 Aug · 9:00 PM · 1h 31m" or just what is known. Returns a plain
    /// label when neither time nor duration is known.
    static func sessionLabel(startedAt: Date?, duration: TimeInterval?) -> String {
        var parts: [String] = []
        if let startedAt {
            parts.append(sessionTime(startedAt))
        }
        if let duration {
            parts.append(shortDuration(duration))
        }
        return parts.isEmpty ? "Session" : parts.joined(separator: " · ")
    }
}
