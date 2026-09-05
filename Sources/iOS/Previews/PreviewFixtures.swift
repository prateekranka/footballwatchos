#if DEBUG
import Foundation

/// Synthetic sessions for SwiftUI previews and only previews. Never used by
/// production code paths, storage, HealthKit, sync, or analysis inputs.
///
/// The values are invented but shaped like real recordings: one strong
/// completed outing, one shorter completed outing, one interruption with the
/// reason the Watch reported, and one completed outing whose distance was
/// never recorded. All dates are fixed in the past so canvases stay stable.
///
/// Usage in a canvas (no previews live in this file):
///
///     #Preview("Sessions") {
///         NavigationStack {
///             // Hand PreviewFixtures.sessions() to the row/list view's
///             // preview entry point, e.g. through its records parameter.
///         }
///     }
enum PreviewFixtures {

    /// Four realistic sessions covering completed, interrupted, and
    /// partially recorded lifecycles.
    static func sessions() -> [FileSessionRepository.SessionRecord] {
        [
            record(
                sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                startedAt: date(2025, 4, 8, 19, 5),
                durationSeconds: 4_320, // 72 min
                distanceMeters: 8_400, // 8.4 km
                averageHeartRate: 142,
                lifecycle: .completed
            ),
            record(
                sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                startedAt: date(2025, 4, 12, 10, 30),
                durationSeconds: 3_840, // 64 min
                distanceMeters: 7_100, // 7.1 km
                averageHeartRate: 138,
                lifecycle: .completed
            ),
            record(
                sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
                startedAt: date(2025, 4, 15, 18, 15),
                durationSeconds: 2_280, // 38 min
                distanceMeters: 3_900, // 3.9 km
                averageHeartRate: nil,
                lifecycle: .interrupted(reason: .workoutEndedUnexpectedly)
            ),
            record(
                sessionID: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!,
                startedAt: date(2025, 4, 19, 9, 40),
                durationSeconds: 2_700, // 45 min
                distanceMeters: nil,
                averageHeartRate: 131,
                lifecycle: .completed
            )
        ]
    }

    // MARK: - Builders

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

    private static func record(
        sessionID: UUID,
        startedAt: Date,
        durationSeconds: Double,
        distanceMeters: Double?,
        averageHeartRate: Double?,
        lifecycle: SessionLifecycleV1
    ) -> FileSessionRepository.SessionRecord {
        let endedAt = startedAt.addingTimeInterval(durationSeconds)
        let summary = SessionSummaryMetricsV1(
            duration: SessionMetricV1(
                value: durationSeconds,
                unit: .seconds,
                provenance: .healthKitFinalWorkout
            ),
            distance: distanceMeters.map {
                SessionMetricV1(value: $0, unit: .meters, provenance: .healthKitFinalWorkout)
            },
            averageHeartRate: averageHeartRate.map {
                SessionMetricV1(value: $0, unit: .beatsPerMinute, provenance: .healthKitFinalWorkout)
            },
            activeEnergy: nil
        )
        let transferEnvelope = SessionTransferEnvelopeV1(
            sessionID: sessionID,
            packageDigest: SessionDigestV1(bytes: Data([0x50, 0x52, 0x45, 0x56])), // "PREV"
            byteCount: 52_000,
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
            healthKitSaveOutcome: lifecycle == .completed
                ? .saved(workoutUUID: nil)
                : .unavailable(reason: .notAttempted)
        )
        return FileSessionRepository.SessionRecord(
            transferEnvelope: transferEnvelope,
            sessionEnvelope: sessionEnvelope,
            completion: completion
        )
    }
}
#endif
