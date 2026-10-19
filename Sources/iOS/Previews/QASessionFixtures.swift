#if DEBUG && targetEnvironment(simulator)
import Foundation

enum QASessionScenario: String, CaseIterable, Identifiable {
    case demo, worst, empty, one, many, coach
    var id: String { rawValue }
    var title: String {
        switch self {
        case .demo: "Demo data"
        case .worst: "Worst case"
        case .empty: "Empty"
        case .one: "One"
        case .many: "1,000 rows"
        case .coach: "Coach scenario"
        }
    }
}

/// Synthetic packages for a simulator-only data toggle. The regular vault
/// codec, repository, analysis, and views consume them without special markup.
enum QASessionFixtures {
    static func packages(for scenario: QASessionScenario, now: Date = .now) -> [[FootySessionFrameV1]] {
        if scenario == .coach { return coachPackages(now: now) }
        let count: Int
        switch scenario {
        case .coach: count = 0
        case .empty: count = 0
        case .one: count = 1
        case .many: count = 1_000
        case .demo: count = 4
        case .worst: count = 6
        }
        return (0..<count).map { index in
            let worst = scenario == .worst
            let hasMotion = scenario == .demo || scenario == .one
            let duration: Double = worst ? [15, 14_400, 60, 5_400, 2_700, 3_600][index] : Double(45 + index % 4 * 15) * 60
            let start = now.addingTimeInterval(-Double(index + 1) * 86_400)
            let end = start.addingTimeInterval(duration)
            let distance: Double? = worst && index == 0 ? 0 : (worst && index == 2 ? nil : Double(4_200 + index % 4 * 1_400))
            let heart: Double? = worst && index.isMultiple(of: 2) ? nil : Double(128 + index % 6 * 8)
            let type = FootballSessionTypeV1.allCases[index % FootballSessionTypeV1.allCases.count]
            let envelope = SessionEnvelopeV1(
                sessionID: UUID(), createdAt: start, startedAt: start,
                captureSource: hasMotion ? .foregroundFallback : .unavailable(reason: .hardwareUnsupported),
                initialAccelerometerAvailability: hasMotion ? .available : .unavailable(reason: .hardwareUnsupported),
                initialDeviceMotionAvailability: hasMotion ? .available : .unavailable(reason: .hardwareUnsupported),
                sessionType: type
            )
            var frames = [FootySessionFrameV1(payload: .envelope(envelope))]
            for minute in 0...Int(duration / 60) {
                let timestamp = start.addingTimeInterval(Double(minute) * 60)
                if let heart {
                    frames.append(FootySessionFrameV1(payload: .heartRateSnapshot(
                        HeartRateSnapshotV1(timestamp: timestamp, beatsPerMinute: SessionMetricV1(value: heart + Double(minute % 7), unit: .beatsPerMinute, provenance: .healthKitLive))
                    )))
                }
                if let distance {
                    frames.append(FootySessionFrameV1(payload: .distanceSnapshot(
                        DistanceSnapshotV1(timestamp: timestamp, meters: SessionMetricV1(value: distance * min(1, Double(minute) * 60 / duration), unit: .meters, provenance: .healthKitLive))
                    )))
                }
            }
            if hasMotion {
                let accelerometer = (0..<200).map { sample in
                    AccelerometerSampleV1(
                        timestamp: 1_000 + Double(sample) / 50,
                        acceleration: Vector3V1(x: sin(Double(sample) / 9) * 0.6, y: cos(Double(sample) / 11) * 0.4, z: 1)
                    )
                }
                let motion = accelerometer.enumerated().map { sample, reading in
                    DeviceMotionSampleV1(
                        timestamp: reading.timestamp,
                        userAcceleration: Vector3V1(x: reading.acceleration.x, y: reading.acceleration.y, z: 0),
                        gravity: Vector3V1(x: 0, y: 0, z: 1),
                        rotationRate: Vector3V1(x: sin(Double(sample) / 13), y: 0, z: 0.2)
                    )
                }
                frames.append(FootySessionFrameV1(payload: .accelerometerBatch(AccelerometerBatchV1(source: .foregroundFallback, samples: accelerometer))))
                frames.append(FootySessionFrameV1(payload: .deviceMotionBatch(DeviceMotionBatchV1(source: .foregroundFallback, samples: motion))))
                frames.append(FootySessionFrameV1(payload: .captureDiagnostics(CaptureDiagnosticsV1(
                    recordedAt: end, source: .foregroundFallback,
                    accelerometerAvailability: .available, deviceMotionAvailability: .available,
                    accelerometerSampleCount: accelerometer.count, deviceMotionSampleCount: motion.count,
                    accelerometerReportedHz: 50, deviceMotionReportedHz: 50,
                    accelerometerBatchCount: 1, deviceMotionBatchCount: 1, maximumObservedGap: 0.02
                ))))
            }
            let completion = SessionCompletionV1(
                endedAt: end,
                lifecycle: worst && index >= 3 ? .interrupted(reason: [.storageFailure, .partialFileRecovery, .workoutEndedUnexpectedly][index - 3]) : .completed,
                summary: SessionSummaryMetricsV1(
                    duration: SessionMetricV1(value: duration, unit: .seconds, provenance: .healthKitFinalWorkout),
                    distance: distance.map { SessionMetricV1(value: $0, unit: .meters, provenance: .healthKitFinalWorkout) },
                    averageHeartRate: heart.map { SessionMetricV1(value: $0, unit: .beatsPerMinute, provenance: .healthKitFinalWorkout) },
                    activeEnergy: hasMotion ? SessionMetricV1(value: Double(420 + index * 40), unit: .kilocalories, provenance: .healthKitFinalWorkout) : nil
                ),
                healthKitSaveOutcome: hasMotion ? .saved(workoutUUID: nil) : .unavailable(reason: .notAttempted)
            )
            frames.append(FootySessionFrameV1(payload: .completion(completion)))
            return frames
        }
    }

    // MARK: - Coach scenario

    /// A six-week history shaped to exercise the coaching layer end to end:
    /// a steady base of 45-minute sessions, a manual log, an interrupted
    /// recording, a week gap, and a load spike this week whose latest match
    /// fades in the second half at a high heart rate. Dates are relative to
    /// `now`, so the expected coaching output is the same on every run.
    private struct PlannedSession {
        let hoursAgo: Double
        let minutes: Int
        let type: FootballSessionTypeV1
        /// Metres per minute in the first and second half; `nil` for no GPS.
        let pace: (first: Double, second: Double)?
        /// Mean heart rate for each half; `nil` for no heart rate.
        let heartRate: (first: Double, second: Double)?
        var manual = false
        var interrupted = false
    }

    private static let coachPlan: [PlannedSession] = [
        PlannedSession(hoursAgo: 3, minutes: 90, type: .elevenASide, pace: (110, 70), heartRate: (165, 173)),
        PlannedSession(hoursAgo: 48, minutes: 90, type: .sevenASide, pace: (100, 100), heartRate: (145, 145)),
        PlannedSession(hoursAgo: 96, minutes: 90, type: .fiveASide, pace: (100, 98), heartRate: (143, 143)),
        PlannedSession(hoursAgo: 144, minutes: 60, type: .training, pace: nil, heartRate: nil, manual: true),
        PlannedSession(hoursAgo: 216, minutes: 45, type: .football, pace: (100, 100), heartRate: (140, 140)),
        PlannedSession(hoursAgo: 288, minutes: 40, type: .fiveASide, pace: (95, 90), heartRate: (141, 141), interrupted: true),
        PlannedSession(hoursAgo: 384, minutes: 45, type: .sevenASide, pace: (100, 100), heartRate: (142, 142)),
        PlannedSession(hoursAgo: 552, minutes: 45, type: .football, pace: (100, 100), heartRate: (140, 140)),
        PlannedSession(hoursAgo: 720, minutes: 45, type: .fiveASide, pace: (100, 100), heartRate: (139, 139)),
        PlannedSession(hoursAgo: 1_056, minutes: 60, type: .football, pace: (98, 96), heartRate: (141, 141)),
    ]

    private static func coachPackages(now: Date) -> [[FootySessionFrameV1]] {
        coachPlan.map { plan in
            let start = now.addingTimeInterval(-plan.hoursAgo * 3_600)
            let duration = Double(plan.minutes) * 60
            let end = start.addingTimeInterval(duration)
            let half = plan.minutes / 2
            let noSensors: MotionCaptureSourceV1 = .unavailable(reason: .captureNotStarted)
            let envelope = SessionEnvelopeV1(
                sessionID: UUID(), createdAt: start, startedAt: start,
                captureSource: plan.manual ? noSensors : .unavailable(reason: .hardwareUnsupported),
                initialAccelerometerAvailability: .unavailable(reason: .hardwareUnsupported),
                initialDeviceMotionAvailability: .unavailable(reason: .hardwareUnsupported),
                sessionType: plan.type
            )
            var frames = [FootySessionFrameV1(payload: .envelope(envelope))]
            var heartRates: [Double] = []
            var meters = 0.0
            if !plan.manual {
                for minute in 0...plan.minutes {
                    let timestamp = start.addingTimeInterval(Double(minute) * 60)
                    if let heartRate = plan.heartRate {
                        let base = minute < half ? heartRate.first : heartRate.second
                        let bpm = base + Double(minute % 5) * 2 - 4
                        heartRates.append(bpm)
                        frames.append(FootySessionFrameV1(payload: .heartRateSnapshot(HeartRateSnapshotV1(
                            timestamp: timestamp,
                            beatsPerMinute: SessionMetricV1(value: bpm, unit: .beatsPerMinute, provenance: .healthKitLive)
                        ))))
                    }
                    if let pace = plan.pace {
                        if minute > 0 { meters += minute <= half ? pace.first : pace.second }
                        frames.append(FootySessionFrameV1(payload: .distanceSnapshot(DistanceSnapshotV1(
                            timestamp: timestamp,
                            meters: SessionMetricV1(value: meters, unit: .meters, provenance: .healthKitLive)
                        ))))
                    }
                }
            }
            let provenance: MetricProvenanceV1 = plan.manual ? .userEntered : .healthKitFinalWorkout
            let completion = SessionCompletionV1(
                endedAt: end,
                lifecycle: plan.interrupted ? .interrupted(reason: .workoutEndedUnexpectedly) : .completed,
                summary: SessionSummaryMetricsV1(
                    duration: SessionMetricV1(value: duration, unit: .seconds, provenance: provenance),
                    distance: plan.pace == nil ? nil : SessionMetricV1(value: meters, unit: .meters, provenance: provenance),
                    averageHeartRate: heartRates.isEmpty ? nil : SessionMetricV1(
                        value: heartRates.reduce(0, +) / Double(heartRates.count),
                        unit: .beatsPerMinute,
                        provenance: provenance
                    )
                ),
                healthKitSaveOutcome: .unavailable(reason: .notAttempted)
            )
            frames.append(FootySessionFrameV1(payload: .completion(completion)))
            return frames
        }
    }
}
#endif
