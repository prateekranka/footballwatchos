import XCTest
@testable import FootballPerformanceWatch

final class HoldToFinishModelTests: XCTestCase {
    func testProgressIsZeroBeforePress() {
        var model = HoldToFinishModel(holdDuration: 1.25)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(model.progress(at: t0), 0)
        XCTAssertEqual(model.progress(at: t0.addingTimeInterval(60)), 0)
        XCTAssertFalse(model.evaluate(at: t0.addingTimeInterval(60)))
    }

    func testProgressGrowsDuringPress() {
        var model = HoldToFinishModel(holdDuration: 1.25)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        model.pressBegan(at: t0)

        let quarter = model.progress(at: t0.addingTimeInterval(0.3125))
        let half = model.progress(at: t0.addingTimeInterval(0.625))

        XCTAssertEqual(quarter, 0.25, accuracy: 0.0001)
        XCTAssertEqual(half, 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(half, quarter)
        // Progress never exceeds the full hold.
        XCTAssertEqual(model.progress(at: t0.addingTimeInterval(10)), 1)
    }

    func testProgressResetsOnEarlyRelease() {
        var model = HoldToFinishModel(holdDuration: 1.25)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        model.pressBegan(at: t0)
        XCTAssertEqual(model.progress(at: t0.addingTimeInterval(0.5)), 0.4, accuracy: 0.0001)

        model.pressEnded(at: t0.addingTimeInterval(0.5))

        XCTAssertEqual(model.progress(at: t0.addingTimeInterval(0.6)), 0)
        XCTAssertEqual(model.progress(at: t0.addingTimeInterval(5)), 0)
        // A released hold never completes, even long after release.
        XCTAssertFalse(model.evaluate(at: t0.addingTimeInterval(5)))
    }

    func testEvaluateCompletesOnlyAfterFullDurationAndOnlyOnce() {
        var model = HoldToFinishModel(holdDuration: 1.25)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        model.pressBegan(at: t0)

        XCTAssertFalse(model.evaluate(at: t0.addingTimeInterval(1.249)))
        XCTAssertFalse(model.isComplete)
        XCTAssertTrue(model.evaluate(at: t0.addingTimeInterval(1.25)))
        XCTAssertTrue(model.isComplete)
        // Completion is reported exactly once; later polls return false.
        XCTAssertFalse(model.evaluate(at: t0.addingTimeInterval(1.5)))
        XCTAssertFalse(model.evaluate(at: t0.addingTimeInterval(10)))
        // A finished hold cannot be re-armed by another press.
        model.pressEnded(at: t0.addingTimeInterval(2))
        model.pressBegan(at: t0.addingTimeInterval(3))
        XCTAssertFalse(model.evaluate(at: t0.addingTimeInterval(10)))
    }
}
