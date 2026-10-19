import Foundation

/// Sprint detection on the Watch, v1 draft.
///
/// Inputs (all already available to the Watch during a session):
///  - distance snapshots (HealthKit workout distance) -> derived speed
///  - GPS speed when the workout provides location
///  - accelerometer magnitude bursts (CMBatchedSensorManager) -> confirmation
///  - heart-rate snapshots -> per-sprint HR join
///
/// DRAFT STATUS: the state machine and event model are compile-ready, but the
/// threshold defaults are starting points. Per the product gate on sensor
/// capability, validate against labeled Calibration Sessions and store the
/// personal threshold as `SprintThresholdV1(confidence: .calibrated)` before
/// treating sprint counts as product metrics.

public protocol SprintDetectingV1: Sendable {
    /// Distance snapshots from the HealthKit workout (cumulative meters).
    func consumeDistance(cumulativeMeters: Double, at timestamp: Date)
    /// GPS speed when available (m/s).
    func consumeLocationSpeed(metersPerSecond: Double, at timestamp: Date)
    /// Accelerometer magnitude bursts for confirmation (m/s^2).
    func consumeAccelerationMagnitude(_ magnitude: Double, at timestamp: Date)
    /// Heart-rate snapshots for the HR join.
    func consumeHeartRate(beatsPerMinute: Double, at timestamp: Date)

    /// Completed sprints since the last flush.
    func flush() -> SprintBatchV1
    /// Called at session seal; returns the final batch.
    func finalBatch() -> SprintBatchV1
}

/// Draft detector: threshold state machine over derived/GPS speed.
public final class SprintDetectorV1: SprintDetectingV1, @unchecked Sendable {
    private let threshold: SprintThresholdV1
    private let estimatedHRMaxBPM: Double

    private var lastDistance: (meters: Double, timestamp: Date)?
    private var lastSpeedSample: (mps: Double, timestamp: Date)?
    private var recentAccelMagnitudes: [(magnitude: Double, timestamp: Date)] = []
    private var recentHeartRate: [(bpm: Double, timestamp: Date)] = []

    // Sprint state
    private var inSprint = false
    private var sprintStart: Date?
    private var sprintStartSpeed: Double?
    private var sprintPeakSpeed: Double = 0
    private var sprintDistance: Double = 0
    private var sprintSamples: [(mps: Double, timestamp: Date)] = []
    private var belowThresholdSince: Date?
    private var completed: [SprintEventV1] = []

    // Burst-fallback state (used only when the speed stream is unavailable)
    private var lastSpeedInputAt: Date?
    private var inBurst = false
    private var burstStart: Date?
    private var burstPeakMagnitude: Double = 0
    private var burstBelowSince: Date?

    /// Fallback activates when no speed input has ever arrived, or none for
    /// this long (covers GPS dying mid-session).
    private static let burstFallbackGraceS: TimeInterval = 20

    public init(threshold: SprintThresholdV1 = .draft, estimatedHRMaxBPM: Double = 190) {
        self.threshold = threshold
        self.estimatedHRMaxBPM = estimatedHRMaxBPM
    }

    /// Clear all state at the start of a new session.
    public func reset() {
        lastDistance = nil
        lastSpeedSample = nil
        recentAccelMagnitudes = []
        recentHeartRate = []
        inSprint = false
        sprintStart = nil
        sprintStartSpeed = nil
        sprintPeakSpeed = 0
        sprintDistance = 0
        sprintSamples = []
        belowThresholdSince = nil
        completed = []
        lastSpeedInputAt = nil
        inBurst = false
        burstStart = nil
        burstPeakMagnitude = 0
        burstBelowSince = nil
    }

    // MARK: - Inputs

    public func consumeDistance(cumulativeMeters: Double, at timestamp: Date) {
        if let last = lastDistance {
            let dt = timestamp.timeIntervalSince(last.timestamp)
            guard dt > 0.2 else { return }  // ignore jitter
            let delta = max(0, cumulativeMeters - last.meters)
            let mps = delta / dt
            consumeSpeed(mps, at: timestamp)
        }
        lastDistance = (cumulativeMeters, timestamp)
    }

    public func consumeLocationSpeed(metersPerSecond: Double, at timestamp: Date) {
        consumeSpeed(metersPerSecond, at: timestamp)
    }

    public func consumeAccelerationMagnitude(_ magnitude: Double, at timestamp: Date) {
        recentAccelMagnitudes.append((magnitude, timestamp))
        if recentAccelMagnitudes.count > 60 {
            recentAccelMagnitudes.removeFirst(recentAccelMagnitudes.count - 60)
        }
        guard burstFallbackActive(at: timestamp) else { return }
        if inBurst {
            burstPeakMagnitude = max(burstPeakMagnitude, magnitude)
            if magnitude >= threshold.burstMinMagnitudeMPS2 {
                burstBelowSince = nil
            } else {
                if burstBelowSince == nil {
                    burstBelowSince = timestamp
                }
                if timestamp.timeIntervalSince(burstBelowSince!) >= threshold.burstExitGraceS {
                    endBurst(at: timestamp)
                }
            }
        } else {
            if magnitude >= threshold.burstMinMagnitudeMPS2 {
                if burstStart == nil {
                    burstStart = timestamp
                    burstPeakMagnitude = magnitude
                } else if timestamp.timeIntervalSince(burstStart!) >= threshold.burstMinDurationS {
                    inBurst = true
                    burstBelowSince = nil
                }
            } else {
                burstStart = nil
            }
        }
    }

    public func consumeHeartRate(beatsPerMinute: Double, at timestamp: Date) {
        recentHeartRate.append((beatsPerMinute, timestamp))
        if recentHeartRate.count > 300 {
            recentHeartRate.removeFirst(recentHeartRate.count - 300)
        }
    }

    // MARK: - State machine

    private func consumeSpeed(_ mps: Double, at timestamp: Date) {
        guard mps.isFinite else { return }
        lastSpeedInputAt = timestamp
        lastSpeedSample = (mps, timestamp)

        if inSprint {
            sprintPeakSpeed = max(sprintPeakSpeed, mps)
            sprintSamples.append((mps, timestamp))
            if mps >= threshold.minSpeedMPS {
                belowThresholdSince = nil
            } else {
                if belowThresholdSince == nil {
                    belowThresholdSince = timestamp
                }
                let belowFor = timestamp.timeIntervalSince(belowThresholdSince!)
                if belowFor >= threshold.exitGraceS {
                    endSprint(at: timestamp)
                }
            }
        } else {
            if mps >= threshold.minSpeedMPS {
                // Candidate start: hold above threshold for minDurationS.
                if sprintStart == nil {
                    sprintStart = timestamp
                    sprintStartSpeed = mps
                    sprintPeakSpeed = mps
                    sprintDistance = 0
                    sprintSamples = [(mps, timestamp)]
                } else if timestamp.timeIntervalSince(sprintStart!) >= threshold.minDurationS {
                    beginSprint(at: sprintStart!)
                }
            } else {
                sprintStart = nil
            }
        }
    }

    private func beginSprint(at timestamp: Date) {
        inSprint = true
        belowThresholdSince = nil
    }

    private func endSprint(at timestamp: Date) {
        defer {
            inSprint = false
            sprintStart = nil
            sprintStartSpeed = nil
            belowThresholdSince = nil
        }
        guard let start = sprintStart, let startSpeed = sprintStartSpeed else { return }

        let duration = timestamp.timeIntervalSince(start)
        let avgSpeed = sprintSamples.map(\.0).reduce(0, +) / Double(max(sprintSamples.count, 1))
        let hr = heartRate(in: start...timestamp)
        let onsetHR = heartRateNear(start, tolerance: 5)

        completed.append(SprintEventV1(
            startTimestamp: start,
            durationS: metric(duration, .seconds, .capturedDeviceEstimate, start),
            distanceM: sprintDistance > 0 ? metric(sprintDistance, .meters, .capturedDeviceEstimate, start) : nil,
            maxSpeedMPS: metric(sprintPeakSpeed, .metersPerSecond, .capturedDeviceEstimate, start),
            averageSpeedMPS: metric(avgSpeed, .metersPerSecond, .capturedDeviceEstimate, start),
            peakHeartRate: hr.isEmpty ? nil : metric(hr.map { $0.bpm }.max() ?? 0, .beatsPerMinute, .healthKitLive, start),
            averageHeartRate: hr.isEmpty ? nil : metric(hr.map { $0.bpm }.reduce(0, +) / Double(hr.count), .beatsPerMinute, .healthKitLive, start),
            heartRateAtOnset: onsetHR.map { metric($0, .beatsPerMinute, .healthKitLive, start) },
            detectionSource: sourceUsed(start...timestamp),
            calibrationConfidence: threshold.confidence
        ))
    }

    // MARK: - Burst fallback

    /// True when the speed stream is dead (never arrived, or silent for the
    /// grace period) and burst detection should emit efforts.
    private func burstFallbackActive(at timestamp: Date) -> Bool {
        guard let last = lastSpeedInputAt else { return true }
        return timestamp.timeIntervalSince(last) > Self.burstFallbackGraceS
    }

    private func endBurst(at timestamp: Date) {
        defer {
            inBurst = false
            burstStart = nil
            burstBelowSince = nil
        }
        guard let start = burstStart else { return }
        let duration = timestamp.timeIntervalSince(start)
        let hr = heartRate(in: start...timestamp)
        let onsetHR = heartRateNear(start, tolerance: 5)
        completed.append(SprintEventV1(
            startTimestamp: start,
            durationS: metric(duration, .seconds, .capturedDeviceEstimate, start),
            distanceM: nil,
            maxSpeedMPS: nil,
            averageSpeedMPS: nil,
            peakHeartRate: hr.isEmpty ? nil : metric(hr.map { $0.bpm }.max() ?? 0, .beatsPerMinute, .healthKitLive, start),
            averageHeartRate: hr.isEmpty ? nil : metric(hr.map { $0.bpm }.reduce(0, +) / Double(hr.count), .beatsPerMinute, .healthKitLive, start),
            heartRateAtOnset: onsetHR.map { metric($0, .beatsPerMinute, .healthKitLive, start) },
            detectionSource: .accelerometerConfirmed,
            calibrationConfidence: threshold.confidence
        ))
    }

    // MARK: - Flush

    public func flush() -> SprintBatchV1 {
        let batch = SprintBatchV1(recordedAt: Date(), events: completed)
        completed = []
        return batch
    }

    public func finalBatch() -> SprintBatchV1 {
        if inSprint {
            endSprint(at: Date())
        }
        if inBurst {
            endBurst(at: Date())
        }
        return flush()
    }

    // MARK: - Helpers

    private func sourceUsed(_ range: ClosedRange<Date>) -> SprintDetectionSourceV1 {
        if threshold.requiresAccelerometerConfirmation {
            let burst = recentAccelMagnitudes.contains { range.contains($0.timestamp) && $0.magnitude > 12 }
            return burst ? .accelerometerConfirmed : .distanceDerived
        }
        return .distanceDerived
    }

    private func heartRate(in range: ClosedRange<Date>) -> [(bpm: Double, timestamp: Date)] {
        recentHeartRate.filter { range.contains($0.timestamp) }
    }

    private func heartRateNear(_ timestamp: Date, tolerance: TimeInterval) -> Double? {
        recentHeartRate
            .filter { abs($0.timestamp.timeIntervalSince(timestamp)) <= tolerance }
            .map { $0.bpm }
            .min()
    }

    private func metric(_ value: Double, _ unit: MetricUnitV1, _ provenance: MetricProvenanceV1, _ at: Date) -> SessionMetricV1 {
        SessionMetricV1(value: value, unit: unit, provenance: provenance, measuredAt: at)
    }
}
