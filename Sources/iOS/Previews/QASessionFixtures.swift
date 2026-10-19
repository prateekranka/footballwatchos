#if DEBUG && targetEnvironment(simulator)
import Foundation

enum QASessionScenario: String, CaseIterable, Identifiable {
    case demo, worst, empty, one, many
    var id: String { rawValue }
    var title: String {
        switch self {
        case .demo: "Demo data"
        case .worst: "Worst case"
        case .empty: "Empty"
        case .one: "One"
        case .many: "1,000 rows"
        }
    }
}

/// Synthetic packages for a simulator-only data toggle. The regular vault
/// codec, repository, analysis, and views consume them without special markup.
enum QASessionFixtures {
    static func packages(for scenario: QASessionScenario, now: Date = .now) -> [[FootySessionFrameV1]] {
        let count: Int
        switch scenario {
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
}
#endif
