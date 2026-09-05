import Foundation

/// Press-and-hold finish logic, separated from the gesture so it can be
/// unit-tested. The view drives `pressBegan`, progress polling, and
/// `pressEnded`; completion fires exactly once after the hold duration.
struct HoldToFinishModel: Equatable, Sendable {
    let holdDuration: TimeInterval
    private(set) var pressStart: Date?
    private(set) var isComplete = false

    init(holdDuration: TimeInterval = 1.25) {
        self.holdDuration = holdDuration
    }

    /// Records the start of a press. Presses after completion are ignored so
    /// a later touch can never re-arm a finished hold.
    mutating func pressBegan(at date: Date) {
        guard !isComplete else { return }
        pressStart = date
    }

    /// Ends a press. Cancels the hold by clearing the start time unless the
    /// hold already completed.
    mutating func pressEnded(at date: Date) {
        guard !isComplete else { return }
        pressStart = nil
    }

    /// Fraction 0...1 filled right now, 0 when not pressing.
    func progress(at date: Date) -> Double {
        guard let pressStart else { return 0 }
        guard !isComplete else { return 1 }
        let elapsed = date.timeIntervalSince(pressStart)
        return min(1, max(0, elapsed / holdDuration))
    }

    /// True the first time the hold passes the duration.
    mutating func evaluate(at date: Date) -> Bool {
        guard !isComplete, let pressStart else { return false }
        guard date.timeIntervalSince(pressStart) >= holdDuration else { return false }
        isComplete = true
        return true
    }
}
