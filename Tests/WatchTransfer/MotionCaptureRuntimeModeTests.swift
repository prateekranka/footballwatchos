import CoreMotion
import XCTest
@testable import FootballPerformanceWatch

@MainActor
final class MotionCapturePlanTests: XCTestCase {
    /// The compile-time capability check the controller itself uses. Reading
    /// these constants never starts sensor updates.
    private var hardwareSupportsBatchedMotion: Bool {
        CMBatchedSensorManager.isAccelerometerSupported
            && CMBatchedSensorManager.isDeviceMotionSupported
    }

    func testBatchedCoreMotionIsSelectedWhenHardwareSupportsIt() throws {
        guard hardwareSupportsBatchedMotion else {
            throw XCTSkip("This simulator does not advertise batched Core Motion hardware support.")
        }

        let plan = MotionCaptureController().makeCapturePlan()

        XCTAssertEqual(plan.source, .batchedCoreMotion)
        XCTAssertEqual(plan.accelerometerAvailability, .available)
        XCTAssertEqual(plan.deviceMotionAvailability, .available)
        XCTAssertEqual(plan.sourceLabel, "Batched Core Motion")
    }

    /// The safe-mode `serviceUnavailable` envelope must never be produced by
    /// any capture-plan branch. Hardware-degradation reasons such as
    /// `.hardwareUnsupported` remain legitimate; `.serviceUnavailable` was the
    /// fingerprint of the removed healthKitOnly policy.
    func testPlanNeverReportsServiceUnavailable() {
        let plan = MotionCaptureController().makeCapturePlan()

        XCTAssertNotEqual(plan.source, .unavailable(reason: .serviceUnavailable))
        XCTAssertNotEqual(
            plan.accelerometerAvailability,
            .unavailable(reason: .serviceUnavailable)
        )
        XCTAssertNotEqual(
            plan.deviceMotionAvailability,
            .unavailable(reason: .serviceUnavailable)
        )
    }

    /// When batched capture is unsupported, the plan may degrade to the
    /// foreground fallback. Assert that branch only through hardware
    /// availability flags (a fresh CMMotionManager reading `is*Available`
    /// does not start sensor updates) — never by starting real updates.
    func testForegroundFallbackReflectsHardwareAvailabilityFlags() throws {
        guard !hardwareSupportsBatchedMotion else {
            throw XCTSkip("Batched motion is supported; the fallback branch is not selected.")
        }

        let fallbackHardware = CMMotionManager()
        guard fallbackHardware.isAccelerometerAvailable || fallbackHardware.isDeviceMotionAvailable
        else {
            throw XCTSkip("This simulator advertises no fallback motion hardware.")
        }

        let plan = MotionCaptureController().makeCapturePlan()

        XCTAssertEqual(plan.source, .foregroundFallback)
        XCTAssertEqual(
            plan.accelerometerAvailability,
            fallbackHardware.isAccelerometerAvailable
                ? .available
                : .unavailable(reason: .hardwareUnsupported)
        )
        XCTAssertEqual(
            plan.deviceMotionAvailability,
            fallbackHardware.isDeviceMotionAvailable
                ? .available
                : .unavailable(reason: .hardwareUnsupported)
        )
    }
}
