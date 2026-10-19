import Foundation

/// A player's log, with no claim that a sensor recorded it.
struct ManualSessionDraft: Sendable {
    let startedAt: Date
    let durationMinutes: Int
    let sessionType: FootballSessionTypeV1

    static let allowedMinutes = 1...240

    enum ValidationError: LocalizedError {
        case duration
        case futureEnd

        var errorDescription: String? {
            switch self {
            case .duration: "Enter a whole number from 1 to 240 minutes."
            case .futureEnd: "Choose a start time that puts the end of the session in the past."
            }
        }
    }

    func validate(now: Date = .now) throws {
        guard Self.allowedMinutes.contains(durationMinutes) else {
            throw ValidationError.duration
        }
        guard startedAt.addingTimeInterval(Double(durationMinutes) * 60) <= now else {
            throw ValidationError.futureEnd
        }
    }
}
