import Foundation
import Testing
@testable import FootballPerformance

@Suite("SessionFingerprint")
struct SessionFingerprintTests {

    private static let startedAt = Date(timeIntervalSinceReferenceDate: 745_000_000)

    /// One sample every 60 s at a fixed 30 s offset into each minute, so no
    /// sample ever lands exactly on a bin boundary (each 72-minute bin spans
    /// 180 s). `skipped` lists sample indices to omit, simulating a gap.
    private static func samples(
        everySeconds interval: Double = 60,
        offset: Double = 30,
        count: Int,
        beatsPerMinute: Double = 140,
        skipping skipped: ClosedRange<Int>? = nil
    ) -> [(timestamp: Date, beatsPerMinute: Double)] {
        (0..<count).compactMap { index in
            if let skipped, skipped.contains(index) { return nil }
            return (
                startedAt.addingTimeInterval(offset + Double(index) * interval),
                beatsPerMinute
            )
        }
    }

    // MARK: - Rejection rules

    @Test("no snapshots produce no fingerprint")
    func emptySnapshots() {
        let fingerprint = SessionFingerprintV1.build(
            from: [],
            startedAt: Self.startedAt,
            endedAt: Self.startedAt.addingTimeInterval(4_320)
        )
        #expect(fingerprint == nil)
    }

    @Test("snapshots outside the session range produce no fingerprint")
    func outOfRangeSnapshots() {
        let samples: [(timestamp: Date, beatsPerMinute: Double)] = [
            (Self.startedAt.addingTimeInterval(-600), 140)
        ]
        let fingerprint = SessionFingerprintV1.build(
            from: samples,
            startedAt: Self.startedAt,
            endedAt: Self.startedAt.addingTimeInterval(4_320)
        )
        #expect(fingerprint == nil)
    }

    @Test("a span under ten minutes produces no fingerprint")
    func shortSpan() {
        let samples = Self.samples(count: 8)
        let fingerprint = SessionFingerprintV1.build(
            from: samples,
            startedAt: Self.startedAt,
            endedAt: Self.startedAt.addingTimeInterval(9 * 60)
        )
        #expect(fingerprint == nil)
    }

    // MARK: - Full-coverage session

    @Test("a 72-minute session with one sample per minute fills all 24 bins")
    func completeSession() throws {
        let samples = Self.samples(count: 72)
        let fingerprint = try #require(
            SessionFingerprintV1.build(
                from: samples,
                startedAt: Self.startedAt,
                endedAt: Self.startedAt.addingTimeInterval(4_320)
            )
        )
        #expect(fingerprint.bins.count == SessionFingerprintV1.binCount)
        #expect(fingerprint.bins.allSatisfy { $0 != nil })
        #expect(fingerprint.coverage == 1.0)
        #expect(abs((fingerprint.peakBeatsPerMinute ?? 0) - 140) < 0.001)
        #expect(fingerprint.durationMinutes == 72)
    }

    // MARK: - Gaps

    @Test("a 30-minute hole leaves exactly its bins empty and lowers coverage")
    func gapInMiddle() throws {
        // Skip samples for minutes 21.5 to 50.5; bins 7...16 cover that hole.
        let samples = Self.samples(count: 72, skipping: 21...50)
        let fingerprint = try #require(
            SessionFingerprintV1.build(
                from: samples,
                startedAt: Self.startedAt,
                endedAt: Self.startedAt.addingTimeInterval(4_320)
            )
        )
        for index in 7...16 {
            #expect(fingerprint.bins[index] == nil)
        }
        #expect(fingerprint.bins[6] != nil)
        #expect(fingerprint.bins[17] != nil)
        #expect(fingerprint.coverage < 1.0)
        #expect(fingerprint.coverage == 14.0 / 24.0)
    }

    // MARK: - Observations

    @Test("a perfectly flat session has no distinguishable busiest stretch")
    func busiestStretchFlatSession() throws {
        let samples = Self.samples(count: 72)
        let fingerprint = try #require(
            SessionFingerprintV1.build(
                from: samples,
                startedAt: Self.startedAt,
                endedAt: Self.startedAt.addingTimeInterval(4_320)
            )
        )
        // Nothing sits above the session's own trend, so no claim is made.
        #expect(SessionObservationEngineV1.busiestStretch(from: fingerprint) == nil)
    }

    @Test("a burst above a rising trend wins over the trend itself")
    func busiestStretchPrefersBurstOverDrift() throws {
        // A session that rises linearly from 130 to 150 bpm with a 10-bpm,
        // four-minute spike at minutes 34-37. The busiest stretch must land
        // on the spike, not the naturally high session end.
        let samples: [(timestamp: Date, beatsPerMinute: Double)] = (0...72).map { minute in
            let drift = 130.0 + 20.0 * Double(minute) / 72.0
            let spike = (34...37).contains(minute) ? 10.0 : 0.0
            return (
                Self.startedAt.addingTimeInterval(30 + Double(minute) * 60),
                drift + spike
            )
        }
        let fingerprint = try #require(
            SessionFingerprintV1.build(
                from: samples,
                startedAt: Self.startedAt,
                endedAt: Self.startedAt.addingTimeInterval(4_320)
            )
        )
        let observation = try #require(SessionObservationEngineV1.busiestStretch(from: fingerprint))
        #expect(observation.minuteRange.lowerBound >= 27)
        #expect(observation.minuteRange.upperBound <= 42)
    }

    @Test("coverage below the minimum yields no observation")
    func busiestStretchLowCoverage() {
        // Samples only in the first five of 24 bins (about 20 percent).
        let samples = Self.samples(count: 15)
        let fingerprint = SessionFingerprintV1.build(
            from: samples,
            startedAt: Self.startedAt,
            endedAt: Self.startedAt.addingTimeInterval(4_320)
        )
        #expect(fingerprint != nil)
        #expect(SessionObservationEngineV1.busiestStretch(from: fingerprint!) == nil)
    }

    @Test("scattered bins with no full window yield no observation")
    func busiestStretchNoFullWindow() {
        // One sample in every other bin: coverage reaches 0.5 but no three
        // consecutive bins are filled, so no claim rests on a partial window.
        let indices = stride(from: 1, through: 67, by: 6)
        let samples: [(timestamp: Date, beatsPerMinute: Double)] = indices.map { index in
            (Self.startedAt.addingTimeInterval(30 + Double(index) * 60), 140)
        }
        let fingerprint = SessionFingerprintV1.build(
            from: samples,
            startedAt: Self.startedAt,
            endedAt: Self.startedAt.addingTimeInterval(4_320)
        )
        #expect(fingerprint != nil)
        #expect(fingerprint?.coverage == 0.5)
        #expect(SessionObservationEngineV1.busiestStretch(from: fingerprint!) == nil)
    }

    // MARK: - Range statement

    @Test("fewer than two values produce no range statement")
    func rangeStatementNeedsTwoValues() {
        #expect(
            SessionObservationEngineV1.rangeStatement(values: [], measureName: "Heart rate", unitName: "bpm") == nil
        )
        #expect(
            SessionObservationEngineV1.rangeStatement(values: [100], measureName: "Heart rate", unitName: "bpm") == nil
        )
    }

    @Test("two values produce a range statement naming both ends")
    func rangeStatementCoversBothEnds() {
        let statement = SessionObservationEngineV1.rangeStatement(
            values: [100, 140],
            measureName: "Heart rate",
            unitName: "bpm"
        )
        #expect(statement?.contains("100") == true)
        #expect(statement?.contains("140") == true)
    }
}
