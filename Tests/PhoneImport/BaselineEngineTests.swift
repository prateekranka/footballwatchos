import Foundation
import Testing
@testable import FootballPerformance

@Suite("BaselineEngine")
struct BaselineEngineTests {

    // MARK: - Record helper

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }

    private static func summary(
        duration: Double? = nil,
        distance: Double? = nil,
        averageHeartRate: Double? = nil
    ) -> SessionSummaryMetricsV1 {
        SessionSummaryMetricsV1(
            duration: duration.map {
                SessionMetricV1(value: $0, unit: .seconds, provenance: .healthKitFinalWorkout)
            },
            distance: distance.map {
                SessionMetricV1(value: $0, unit: .meters, provenance: .healthKitFinalWorkout)
            },
            averageHeartRate: averageHeartRate.map {
                SessionMetricV1(value: $0, unit: .beatsPerMinute, provenance: .healthKitFinalWorkout)
            },
            activeEnergy: nil
        )
    }

    private static func makeRecord(
        startedAt: Date,
        summary: SessionSummaryMetricsV1?,
        lifecycle: SessionLifecycleV1 = .completed
    ) -> FileSessionRepository.SessionRecord {
        let endedAt = startedAt.addingTimeInterval(summary?.duration?.value ?? 600)
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
            lifecycle: lifecycle,
            summary: summary,
            healthKitSaveOutcome: .saved(workoutUUID: nil)
        )
        return FileSessionRepository.SessionRecord(
            transferEnvelope: transferEnvelope,
            sessionEnvelope: sessionEnvelope,
            completion: completion
        )
    }

    /// A completed session whose distance-per-minute is `meters / 3600 * 60`.
    private static func validSession(
        day: Int,
        durationSeconds: Double = 3_600,
        distanceMeters: Double
    ) -> FileSessionRepository.SessionRecord {
        makeRecord(
            startedAt: date(2025, 4, day, 19, 0),
            summary: summary(duration: durationSeconds, distance: distanceMeters),
            lifecycle: .completed
        )
    }

    // MARK: - Validity gate

    @Test("only a completed session with recorded duration and distance of at least ten minutes is valid")
    func validityGate() {
        let startedAt = Self.date(2025, 4, 8, 19, 0)

        let interrupted = Self.makeRecord(
            startedAt: startedAt,
            summary: Self.summary(duration: 4_320, distance: 8_400),
            lifecycle: .interrupted(reason: .appTerminated)
        )
        #expect(!BaselineEngineV1.isValidSession(interrupted))

        let withoutSummary = Self.makeRecord(startedAt: startedAt, summary: nil)
        #expect(!BaselineEngineV1.isValidSession(withoutSummary))

        let withoutDuration = Self.makeRecord(
            startedAt: startedAt,
            summary: Self.summary(distance: 8_400)
        )
        #expect(!BaselineEngineV1.isValidSession(withoutDuration))

        let tooShort = Self.makeRecord(
            startedAt: startedAt,
            summary: Self.summary(duration: 300, distance: 8_400)
        )
        #expect(!BaselineEngineV1.isValidSession(tooShort))

        let withoutDistance = Self.makeRecord(
            startedAt: startedAt,
            summary: Self.summary(duration: 4_320)
        )
        #expect(!BaselineEngineV1.isValidSession(withoutDistance))

        let valid = Self.makeRecord(
            startedAt: startedAt,
            summary: Self.summary(duration: 4_320, distance: 8_400)
        )
        #expect(BaselineEngineV1.isValidSession(valid))
    }

    // MARK: - Distance per minute

    @Test("distance per minute is meters divided by minutes and nil when either value is missing")
    func distancePerMinute() {
        let complete = Self.makeRecord(
            startedAt: Self.date(2025, 4, 8, 19, 0),
            summary: Self.summary(duration: 4_320, distance: 8_400)
        )
        let value = BaselineEngineV1.distancePerMinute(complete)
        #expect(abs((value ?? 0) - 116.667) < 0.1)

        let withoutDuration = Self.makeRecord(
            startedAt: Self.date(2025, 4, 8, 19, 0),
            summary: Self.summary(distance: 8_400)
        )
        #expect(BaselineEngineV1.distancePerMinute(withoutDuration) == nil)

        let withoutDistance = Self.makeRecord(
            startedAt: Self.date(2025, 4, 8, 19, 0),
            summary: Self.summary(duration: 4_320)
        )
        #expect(BaselineEngineV1.distancePerMinute(withoutDistance) == nil)

        let zeroDuration = Self.makeRecord(
            startedAt: Self.date(2025, 4, 8, 19, 0),
            summary: Self.summary(duration: 0, distance: 8_400)
        )
        #expect(BaselineEngineV1.distancePerMinute(zeroDuration) == nil)
    }

    // MARK: - Baseline status

    @Test("three valid prior sessions establish the baseline at their mean")
    func establishedFromThreePriors() {
        let priors = [
            Self.validSession(day: 1, distanceMeters: 6_000), // 100 m/min
            Self.validSession(day: 2, distanceMeters: 6_600), // 110 m/min
            Self.validSession(day: 3, distanceMeters: 7_200) // 120 m/min
        ]
        let status = BaselineEngineV1.baseline(
            for: .distancePerMinute,
            priorSessions: priors,
            currentStartedAt: Self.date(2025, 4, 8, 19, 0)
        )
        guard case let .established(mean, contributingCount) = status else {
            Issue.record("Expected an established baseline, got \(status)")
            return
        }
        #expect(contributingCount == 3)
        #expect(abs(mean - 110) < 0.5)
    }

    @Test("two valid prior sessions are still building the baseline")
    func buildingFromTwoPriors() {
        let priors = [
            Self.validSession(day: 1, distanceMeters: 6_000),
            Self.validSession(day: 2, distanceMeters: 6_600)
        ]
        let status = BaselineEngineV1.baseline(
            for: .distancePerMinute,
            priorSessions: priors,
            currentStartedAt: Self.date(2025, 4, 8, 19, 0)
        )
        #expect(status == .building(validCount: 2, required: 3))
    }

    @Test("no prior sessions means no baseline")
    func unavailableWithoutPriors() {
        let status = BaselineEngineV1.baseline(
            for: .distancePerMinute,
            priorSessions: [],
            currentStartedAt: Self.date(2025, 4, 8, 19, 0)
        )
        #expect(status == .unavailable)
    }

    @Test("a prior session that starts after the current one is excluded")
    func futurePriorExcluded() {
        let priors = [
            Self.validSession(day: 1, distanceMeters: 6_000),
            Self.validSession(day: 2, distanceMeters: 6_600),
            Self.validSession(day: 10, distanceMeters: 7_200) // after the current session
        ]
        let status = BaselineEngineV1.baseline(
            for: .distancePerMinute,
            priorSessions: priors,
            currentStartedAt: Self.date(2025, 4, 8, 19, 0)
        )
        #expect(status == .building(validCount: 2, required: 3))
    }

    @Test("at most four prior sessions contribute once the baseline exists")
    func establishedCapsContributingSessions() {
        let priors = [
            Self.validSession(day: 1, distanceMeters: 6_000), // 100 m/min
            Self.validSession(day: 2, distanceMeters: 6_600), // 110 m/min
            Self.validSession(day: 3, distanceMeters: 7_200), // 120 m/min
            Self.validSession(day: 4, distanceMeters: 7_800), // 130 m/min
            Self.validSession(day: 5, distanceMeters: 8_400) // 140 m/min
        ]
        let status = BaselineEngineV1.baseline(
            for: .distancePerMinute,
            priorSessions: priors,
            currentStartedAt: Self.date(2025, 4, 8, 19, 0)
        )
        guard case let .established(mean, contributingCount) = status else {
            Issue.record("Expected an established baseline, got \(status)")
            return
        }
        #expect(contributingCount == BaselineEngineV1.maximumContributingSessions)
        #expect(contributingCount == 4)
        // The four most recent sessions (110 to 140 m/min) average 125.
        #expect(abs(mean - 125) < 0.5)
    }

    @Test("an invalid prior session never counts toward the baseline")
    func invalidPriorNeverCounts() {
        let priors = [
            Self.validSession(day: 1, distanceMeters: 6_000),
            Self.validSession(day: 2, distanceMeters: 6_600),
            Self.validSession(day: 3, distanceMeters: 7_200),
            Self.makeRecord(
                startedAt: Self.date(2025, 4, 4, 19, 0),
                summary: Self.summary(duration: 4_320, distance: 8_400),
                lifecycle: .interrupted(reason: .appTerminated)
            )
        ]
        let status = BaselineEngineV1.baseline(
            for: .distancePerMinute,
            priorSessions: priors,
            currentStartedAt: Self.date(2025, 4, 8, 19, 0)
        )
        guard case let .established(mean, contributingCount) = status else {
            Issue.record("Expected an established baseline, got \(status)")
            return
        }
        #expect(contributingCount == 3)
        #expect(abs(mean - 110) < 0.5)
    }

    @Test("the current session is never part of its own comparison pool")
    func currentSessionExcludedFromOwnPool() {
        let priors = [
            Self.validSession(day: 1, distanceMeters: 6_000), // 100 m/min
            Self.validSession(day: 2, distanceMeters: 6_600), // 110 m/min
            Self.validSession(day: 3, distanceMeters: 7_200), // 120 m/min
            Self.validSession(day: 8, distanceMeters: 7_800) // the current session itself
        ]
        let currentStartedAt = Self.date(2025, 4, 8, 19, 0)
        #expect(priors[3].startedAt == currentStartedAt)

        let status = BaselineEngineV1.baseline(
            for: .distancePerMinute,
            priorSessions: priors,
            currentStartedAt: currentStartedAt
        )
        guard case let .established(mean, contributingCount) = status else {
            Issue.record("Expected an established baseline, got \(status)")
            return
        }
        #expect(contributingCount == 3)
        #expect(abs(mean - 110) < 0.5)
    }

    // MARK: - Copy

    @Test("the building sentence states the counts without judgment")
    func buildingSentenceCopy() {
        #expect(
            BaselineEngineV1.buildingSentence(validCount: 2, required: 3)
                == "Building your baseline — 2 of 3 valid sessions"
        )
    }
}
