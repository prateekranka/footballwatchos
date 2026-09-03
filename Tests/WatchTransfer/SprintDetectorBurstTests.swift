import XCTest
@testable import FootballPerformanceWatch

final class SprintDetectorBurstTests: XCTestCase {
    /// With no speed input ever arriving (GPS dead), sustained high
    /// acceleration magnitudes emit an accelerometer-confirmed effort.
    func testBurstFallbackEmitsAccelerometerConfirmedSprint() {
        var threshold = SprintThresholdV1.draft
        threshold.burstMinMagnitudeMPS2 = 3.0
        threshold.burstMinDurationS = 0.5
        threshold.burstExitGraceS = 0.3

        let detector = SprintDetectorV1(threshold: threshold)
        let t0 = Date()

        // 3 seconds of hard effort: magnitudes well above the burst threshold.
        for i in 0..<30 {
            detector.consumeAccelerationMagnitude(5.0, at: t0.addingTimeInterval(Double(i) * 0.1))
        }
        // Recovery: magnitudes drop below the threshold.
        for i in 0..<10 {
            detector.consumeAccelerationMagnitude(0.5, at: t0.addingTimeInterval(3.0 + Double(i) * 0.1))
        }

        let batch = detector.flush()
        XCTAssertEqual(batch.events.count, 1, "one burst effort expected")
        guard let event = batch.events.first else { return }
        XCTAssertEqual(event.detectionSource, .accelerometerConfirmed)
        XCTAssertNil(event.maxSpeedMPS, "no speed stream, so no speed metrics")
        XCTAssertGreaterThan(event.durationS.value, 1.5, "effort should span the sustained burst")
        XCTAssertLessThan(event.durationS.value, 3.5)
    }

    /// When the speed stream is alive, bursts must NOT emit efforts (speed
    /// detection owns the session).
    func testBurstFallbackIsSilentWhenSpeedIsLive() {
        var threshold = SprintThresholdV1.draft
        threshold.burstMinMagnitudeMPS2 = 3.0
        threshold.burstMinDurationS = 0.5

        let detector = SprintDetectorV1(threshold: threshold)
        let t0 = Date()

        // A speed sample keeps the fallback asleep (two distance samples so a
        // speed delta is derived and lastSpeedInputAt is set).
        detector.consumeDistance(cumulativeMeters: 10, at: t0)
        detector.consumeDistance(cumulativeMeters: 11.2, at: t0.addingTimeInterval(1.0))
        for i in 0..<30 {
            detector.consumeAccelerationMagnitude(5.0, at: t0.addingTimeInterval(Double(i) * 0.1))
        }

        let batch = detector.flush()
        XCTAssertTrue(batch.events.isEmpty, "no burst events while speed stream is live")
    }

    /// HR join: a burst with HR samples carries peak and onset heart rate.
    func testBurstFallbackJoinsHeartRate() {
        var threshold = SprintThresholdV1.draft
        threshold.burstMinMagnitudeMPS2 = 3.0
        threshold.burstMinDurationS = 0.5
        threshold.burstExitGraceS = 0.3

        let detector = SprintDetectorV1(threshold: threshold)
        let t0 = Date()

        detector.consumeHeartRate(beatsPerMinute: 145, at: t0)
        for i in 0..<30 {
            detector.consumeAccelerationMagnitude(5.0, at: t0.addingTimeInterval(Double(i) * 0.1))
            detector.consumeHeartRate(beatsPerMinute: 160 + Double(i), at: t0.addingTimeInterval(Double(i) * 0.1))
        }
        for i in 0..<10 {
            detector.consumeAccelerationMagnitude(0.5, at: t0.addingTimeInterval(3.0 + Double(i) * 0.1))
        }

        let batch = detector.flush()
        guard let event = batch.events.first else {
            XCTFail("expected a burst event")
            return
        }
        XCTAssertNotNil(event.peakHeartRate)
        XCTAssertGreaterThan(event.peakHeartRate?.value ?? 0, 160)
        XCTAssertNotNil(event.heartRateAtOnset)
        XCTAssertEqual(event.heartRateAtOnset?.value ?? 0, 145)
    }
}
