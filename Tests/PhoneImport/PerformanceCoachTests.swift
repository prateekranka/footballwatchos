import Foundation
import Testing
@testable import FootballPerformance

@Suite("PerformanceCoach")
struct PerformanceCoachTests {

    // MARK: - Helpers

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    /// Wednesday 15 October 2025, 12:00 UTC.
    private static let now: Date = {
        var components = DateComponents()
        components.year = 2025
        components.month = 10
        components.day = 15
        components.hour = 12
        return calendar.date(from: components)!
    }()

    private static func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    private static func makeRecord(
        startedAt: Date,
        minutes: Double,
        distance: Double? = nil,
        averageHeartRate: Double? = nil
    ) -> FileSessionRepository.SessionRecord {
        let summary = SessionSummaryMetricsV1(
            duration: SessionMetricV1(value: minutes * 60, unit: .seconds, provenance: .healthKitFinalWorkout),
            distance: distance.map { SessionMetricV1(value: $0, unit: .meters, provenance: .healthKitFinalWorkout) },
            averageHeartRate: averageHeartRate.map {
                SessionMetricV1(value: $0, unit: .beatsPerMinute, provenance: .healthKitFinalWorkout)
            },
            activeEnergy: nil
        )
        let endedAt = startedAt.addingTimeInterval(minutes * 60)
        let sessionID = UUID()
        let transferEnvelope = SessionTransferEnvelopeV1(
            sessionID: sessionID,
            packageDigest: SessionDigestV1(bytes: Data([0x01, 0x02, 0x03, 0x04])),
            byteCount: 48_000,
            createdAt: endedAt
        )
        let sessionEnvelope = SessionEnvelopeV1(
            sessionID: sessionID,
            createdAt: endedAt,
            startedAt: startedAt,
            captureSource: .batchedCoreMotion,
            initialAccelerometerAvailability: .available,
            initialDeviceMotionAvailability: .available
        )
        let completion = SessionCompletionV1(
            endedAt: endedAt,
            lifecycle: .completed,
            summary: summary,
            healthKitSaveOutcome: .saved(workoutUUID: nil)
        )
        return FileSessionRepository.SessionRecord(
            transferEnvelope: transferEnvelope,
            sessionEnvelope: sessionEnvelope,
            completion: completion
        )
    }

    private static func detail(
        record: FileSessionRepository.SessionRecord,
        heartRate: [(seconds: Double, bpm: Double)] = [],
        distance: [(seconds: Double, meters: Double)] = []
    ) -> FileSessionRepository.SessionDetail {
        FileSessionRepository.SessionDetail(
            record: record,
            heartRateSnapshots: heartRate.enumerated().map { index, sample in
                FileSessionRepository.ChartPoint(id: "hr-\(index)", timestamp: record.startedAt.addingTimeInterval(sample.seconds), value: sample.bpm)
            },
            distanceSnapshots: distance.enumerated().map { index, sample in
                FileSessionRepository.ChartPoint(id: "d-\(index)", timestamp: record.startedAt.addingTimeInterval(sample.seconds), value: sample.meters)
            },
            diagnostics: []
        )
    }

    // MARK: - Snapshot

    @Test("weekly buckets sum minutes and count sessions, newest week last")
    func weeklyBuckets() {
        let records = [
            Self.makeRecord(startedAt: Self.daysAgo(1), minutes: 60, distance: 7_000),
            Self.makeRecord(startedAt: Self.daysAgo(0.5), minutes: 30),
            Self.makeRecord(startedAt: Self.daysAgo(8), minutes: 90, distance: 9_000),
        ]
        let snapshot = PerformanceCoachV1.snapshot(records: records, now: Self.now, calendar: Self.calendar)

        #expect(snapshot.weeks.count == 8)
        #expect(snapshot.thisWeek?.sessionCount == 2)
        #expect(snapshot.thisWeek?.minutes == 90)
        #expect(snapshot.thisWeek?.distanceMeters == 7_000)
        #expect(snapshot.weeks[6].sessionCount == 1)
        #expect(snapshot.weeks[5].distanceMeters == nil)
        #expect(snapshot.sessionsLast28Days == 3)
    }

    @Test("a streak survives an empty current week and stops at the first empty week")
    func streak() {
        let records = [
            Self.makeRecord(startedAt: Self.daysAgo(7), minutes: 60),
            Self.makeRecord(startedAt: Self.daysAgo(14), minutes: 60),
            Self.makeRecord(startedAt: Self.daysAgo(28), minutes: 60),
        ]
        let snapshot = PerformanceCoachV1.snapshot(records: records, now: Self.now, calendar: Self.calendar)
        #expect(snapshot.thisWeek?.sessionCount == 0)
        #expect(snapshot.streakWeeks == 2)
    }

    @Test("load ratio compares the last 7 days with the average week before")
    func loadRatio() {
        let records = [
            Self.makeRecord(startedAt: Self.daysAgo(2), minutes: 240),
            Self.makeRecord(startedAt: Self.daysAgo(10), minutes: 60),
            Self.makeRecord(startedAt: Self.daysAgo(17), minutes: 60),
            Self.makeRecord(startedAt: Self.daysAgo(24), minutes: 60),
            Self.makeRecord(startedAt: Self.daysAgo(31), minutes: 60),
        ]
        let snapshot = PerformanceCoachV1.snapshot(records: records, now: Self.now, calendar: Self.calendar)
        #expect(snapshot.acuteMinutes == 240)
        #expect(snapshot.chronicWeeklyMinutes == 60)
        #expect(snapshot.loadRatio == 4)

        let tips = PerformanceCoachV1.tips(records: records, snapshot: snapshot, includeGeneral: false)
        #expect(tips.first?.id == "load-spike")
    }

    @Test("no history means no load ratio and no tips")
    func emptyHistory() {
        let snapshot = PerformanceCoachV1.snapshot(records: [], now: Self.now, calendar: Self.calendar)
        #expect(snapshot.loadRatio == nil)
        #expect(snapshot.streakWeeks == 0)
        #expect(PerformanceCoachV1.tips(records: [], snapshot: snapshot).isEmpty)
    }

    // MARK: - Tips

    @Test("a work rate well below the baseline asks for tempo work")
    func workRateBelowBaseline() {
        // Newest first: latest at 80 m/min against a 100 m/min baseline.
        let records = [
            Self.makeRecord(startedAt: Self.daysAgo(1), minutes: 60, distance: 4_800),
            Self.makeRecord(startedAt: Self.daysAgo(3), minutes: 60, distance: 6_000),
            Self.makeRecord(startedAt: Self.daysAgo(5), minutes: 60, distance: 6_000),
            Self.makeRecord(startedAt: Self.daysAgo(8), minutes: 60, distance: 6_000),
        ]
        let snapshot = PerformanceCoachV1.snapshot(records: records, now: Self.now, calendar: Self.calendar)
        let tips = PerformanceCoachV1.tips(records: records, snapshot: snapshot, includeGeneral: false)
        let tip = tips.first { $0.id == "work-rate-down" }
        #expect(tip != nil)
        #expect(tip?.evidence.contains("20% below") == true)
        #expect(tip?.drill != nil)
    }

    @Test("general guidance is appended after personal tips and labelled")
    func generalTipsLast() {
        let records = [Self.makeRecord(startedAt: Self.daysAgo(1), minutes: 60)]
        let snapshot = PerformanceCoachV1.snapshot(records: records, now: Self.now, calendar: Self.calendar)
        let tips = PerformanceCoachV1.tips(records: records, snapshot: snapshot)
        #expect(tips.first?.id == "consistency-build")
        #expect(tips.last?.isGeneral == true)
        #expect(tips.filter(\.isGeneral).count == PerformanceCoachV1.generalTips.count)
    }

    // MARK: - One session

    @Test("max heart rate uses age when known, otherwise a conservative estimate")
    func heartRateMax() {
        #expect(abs(PerformanceCoachV1.heartRateMax(age: 30, observedPeak: nil) - 187) < 0.001)
        #expect(PerformanceCoachV1.heartRateMax(age: nil, observedPeak: 201) == 201)
        #expect(PerformanceCoachV1.heartRateMax(age: nil, observedPeak: 170) == 190)
        #expect(PerformanceCoachV1.heartRateMax(age: 0, observedPeak: nil) == 190)
    }

    @Test("zone time is time-weighted and skips gaps over two minutes")
    func zoneShares() {
        let start = Self.now
        let heartRate: [(timestamp: Date, bpm: Double)] = [
            (start, 100),                          // zone 1 for 60 s
            (start.addingTimeInterval(60), 175),   // zone 4 (175/200) for 60 s
            (start.addingTimeInterval(120), 185),  // zone 5, then a 10 min gap
            (start.addingTimeInterval(720), 130),
        ]
        let zones = PerformanceCoachV1.zoneShares(heartRate: heartRate, heartRateMax: 200)
        #expect(zones.map(\.seconds) == [60, 0, 0, 60, 0])
    }

    @Test("a second-half drop in distance per minute produces a fade takeaway")
    func secondHalfFade() {
        let record = Self.makeRecord(startedAt: Self.now, minutes: 40, distance: 3_000)
        // 100 m/min for 20 min, then 50 m/min for 20 min.
        let distance: [(seconds: Double, meters: Double)] = [
            (0, 0), (600, 1_000), (1_200, 2_000), (1_800, 2_500), (2_400, 3_000),
        ]
        let insights = PerformanceCoachV1.insights(
            for: Self.detail(record: record, distance: distance),
            age: 30
        )
        #expect(insights.firstHalfDistancePerMinute == 100)
        #expect(insights.secondHalfDistancePerMinute == 50)
        #expect(insights.takeaways.first?.id == "session-fade")
        #expect(insights.zoneSeconds == 0)
    }

    @Test("a session without sensor evidence has no takeaways")
    func noEvidence() {
        let record = Self.makeRecord(startedAt: Self.now, minutes: 40)
        let insights = PerformanceCoachV1.insights(for: Self.detail(record: record), age: nil)
        #expect(insights.takeaways.isEmpty)
        #expect(insights.highIntensityShare == nil)
        #expect(insights.workRateFade == nil)
    }
}
