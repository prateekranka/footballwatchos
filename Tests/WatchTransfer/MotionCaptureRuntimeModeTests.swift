import XCTest
@testable import FootballPerformanceWatch

@MainActor
final class MotionCaptureRuntimeModeTests: XCTestCase {
    func testHealthKitOnlyModeDoesNotSelectCoreMotion() {
        let controller = MotionCaptureController(runtimeMode: .healthKitOnly)

        let plan = controller.makeCapturePlan()

        XCTAssertEqual(plan.source, .unavailable(reason: .serviceUnavailable))
        XCTAssertEqual(plan.accelerometerAvailability, .unavailable(reason: .serviceUnavailable))
        XCTAssertEqual(plan.deviceMotionAvailability, .unavailable(reason: .serviceUnavailable))
        XCTAssertEqual(plan.sourceLabel, "HealthKit-only safe mode")
    }
}
