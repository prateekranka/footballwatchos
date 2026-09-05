import Foundation

/// User-facing text for session rows and cards.
///
/// Every formatter expresses missing evidence as an explicit dash or
/// sentence. Nothing here can render a missing metric as zero.
enum SessionRowFormatting {

    /// "Tue, 8 Apr" from the recorded start time.
    static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "19:14" from the recorded start time.
    static func timeLabel(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// "72 min" or "—" when duration was not recorded.
    static func durationLabel(_ duration: Double?) -> String {
        guard let duration, duration > 0 else { return "—" }
        let minutes = Int((duration / 60).rounded())
        return "\(minutes) min"
    }

    /// "8.4 km" or "—" when distance was not recorded.
    static func distanceLabel(meters: Double?) -> String {
        guard let meters, meters > 0 else { return "—" }
        return String(format: "%.1f km", meters / 1_000)
    }

    /// "142 bpm" or "—" when no heart rate was recorded.
    static func heartRateLabel(_ beatsPerMinute: Double?) -> String {
        guard let beatsPerMinute, beatsPerMinute > 0 else { return "—" }
        return "\(Int(beatsPerMinute.rounded())) bpm"
    }

    static func summaryDistance(_ record: FileSessionRepository.SessionRecord) -> Double? {
        record.completion.summary?.distance?.value
    }

    static func summaryDuration(_ record: FileSessionRepository.SessionRecord) -> Double? {
        record.completion.summary?.duration?.value
    }

    static func summaryAverageHeartRate(_ record: FileSessionRepository.SessionRecord) -> Double? {
        record.completion.summary?.averageHeartRate?.value
    }

    enum SessionState: Equatable {
        case completed
        case interrupted(reason: SessionInterruptionReasonV1)
        case incompletePackage

        var label: String {
            switch self {
            case .completed:
                return "Completed"
            case .interrupted:
                return "Interrupted"
            case .incompletePackage:
                return "Incomplete"
            }
        }
    }

    /// Recorded lifecycle, mapped without spin. A package without a
    /// completion frame is shown as incomplete rather than completed.
    static func state(_ record: FileSessionRepository.SessionRecord) -> SessionState {
        switch record.completion.lifecycle {
        case .completed:
            return .completed
        case let .interrupted(reason):
            return .interrupted(reason: reason)
        }
    }

    /// Plain-language interruption reason for the quality report.
    static func interruptionDetail(_ reason: SessionInterruptionReasonV1) -> String {
        switch reason {
        case .appTerminated:
            return "The app stopped unexpectedly during recording."
        case .workoutEndedUnexpectedly:
            return "The workout ended unexpectedly."
        case .storageFailure:
            return "Watch storage failed during recording."
        case .partialFileRecovery:
            return "Recovered from a partially written recording."
        case .userAbandoned:
            return "Recording was abandoned before finishing."
        case .unknown:
            return "Recording ended before it was finished."
        }
    }
}
