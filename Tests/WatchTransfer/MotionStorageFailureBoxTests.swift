import Foundation
import XCTest
@testable import FootballPerformanceWatch

final class MotionStorageFailureBoxTests: XCTestCase {
    func testBackgroundFinishCanBeObservedThroughLockedStatus() async {
        let box = MotionStorageFailureBox()

        let initial = box.status
        XCTAssertFalse(initial.isFinished)
        XCTAssertNil(initial.failure)

        let finished = expectation(description: "background finish returned")
        DispatchQueue.global(qos: .utility).async {
            box.record("disk write failed")
            box.finish()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)

        let final = box.status
        XCTAssertTrue(final.isFinished)
        XCTAssertEqual(final.failure, "disk write failed")
    }
}
