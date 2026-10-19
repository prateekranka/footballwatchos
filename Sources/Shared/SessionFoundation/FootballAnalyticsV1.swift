import Foundation

/// Football-specific analytics model, v1.
///
/// Ownership split:
///  - The Watch captures raw evidence: `SprintBatchV1` frames in the sealed
///    package (plus the existing heart-rate/distance/motion frames).
///  - The companion computes the derived analytics (`FatigueCurveV1`,
///    `SprintQualityV1`, `WorkRestSummaryV1`, `LoadSummaryV1`) from the
///    decoded package and pushes a `SessionAnalyticsV1` document to the
///    health pipeline (`POST /analytics`).
///  - Readiness data (HRV, resting heart rate, sleep) comes from HealthKit
///    via the pipeline and is attached to the same document.
///
/// Draft status: types are compile-ready; detection thresholds and load
/// bands require validation against labeled Calibration Sessions before
/// they are used as product metrics (see product gate: sensor capability).

// MARK: - Sprint capture (Watch frame payload)

public enum SprintDetectionSourceV1: String, Codable, Sendable, Equatable {
    /// GPS-reported instantaneous speed crossed the threshold.
    case gpsSpeed
    /// Speed derived from distance-snapshot deltas crossed the threshold.
    case distanceDerived
    /// Threshold crossing confirmed by an accelerometer-magnitude burst.
    case accelerometerConfirmed
}

public enum CalibrationConfidenceV1: String, Codable, Sendable, Equatable {
    case uncalibrated
    case provisional
    case calibrated
}

/// One detected sprint. `startTimestamp` is the moment the effort crossed the
/// threshold; `durationS` ends at the moment speed fell back below it.
public struct SprintEventV1: Codable, Sendable, Equatable {
    public let startTimestamp: Date
    public let durationS: SessionMetricV1
    public let distanceM: SessionMetricV1?
    public let maxSpeedMPS: SessionMetricV1?
    public let averageSpeedMPS: SessionMetricV1?
    public let peakHeartRate: SessionMetricV1?
    public let averageHeartRate: SessionMetricV1?
    /// HR just before the effort started: a rising onset baseline across the
    /// game is a fatigue signal.
    public let heartRateAtOnset: SessionMetricV1?
    public let detectionSource: SprintDetectionSourceV1
    public let calibrationConfidence: CalibrationConfidenceV1

    public init(
        startTimestamp: Date,
        durationS: SessionMetricV1,
        distanceM: SessionMetricV1? = nil,
        maxSpeedMPS: SessionMetricV1? = nil,
        averageSpeedMPS: SessionMetricV1? = nil,
        peakHeartRate: SessionMetricV1? = nil,
        averageHeartRate: SessionMetricV1? = nil,
        heartRateAtOnset: SessionMetricV1? = nil,
        detectionSource: SprintDetectionSourceV1,
        calibrationConfidence: CalibrationConfidenceV1
    ) {
        self.startTimestamp = startTimestamp
        self.durationS = durationS
        self.distanceM = distanceM
        self.maxSpeedMPS = maxSpeedMPS
        self.averageSpeedMPS = averageSpeedMPS
        self.peakHeartRate = peakHeartRate
        self.averageHeartRate = averageHeartRate
        self.heartRateAtOnset = heartRateAtOnset
        self.detectionSource = detectionSource
        self.calibrationConfidence = calibrationConfidence
    }
}

/// Frame payload the Watch writes when the detector flushes a batch.
public struct SprintBatchV1: Codable, Sendable, Equatable {
    public let recordedAt: Date
    public let events: [SprintEventV1]

    public init(recordedAt: Date, events: [SprintEventV1]) {
        self.recordedAt = recordedAt
        self.events = events
    }
}

/// Detector thresholds. The draft estimate (2026-08-28) targets an active
/// 34-year-old recreational male footballer:
///   estimated max sprinting speed (MSS) ~ 7.6 m/s (27.5 km/h)
///     = 8.0 m/s baseline at 25, −0.8%/yr decline, +3% activity adjustment
///   sprint threshold = 80% MSS ≈ 6.0 m/s (21.6 km/h)
///   high-speed running boundary = 5.0 m/s (18 km/h)
/// A Calibration Session should produce the personal `SprintThresholdV1`
/// stored as `calibrated` (see SessionAnalystV1.recommendCalibration and
/// SprintCalibrationStore).
public struct SprintThresholdV1: Codable, Sendable, Equatable {
    /// Minimum sustained speed, metres per second (draft 6.0 ~ 21.6 km/h).
    public var minSpeedMPS: Double
    /// Boundary between running and high-speed running (draft 5.0 ~ 18 km/h).
    public var highSpeedRunningMinMPS: Double
    /// How long speed must hold above the threshold (seconds).
    public var minDurationS: Double
    /// Require an accelerometer-magnitude burst to confirm the effort.
    public var requiresAccelerometerConfirmation: Bool
    /// How long speed must stay below threshold before the sprint ends.
    public var exitGraceS: Double
    /// Burst fallback: gravity-subtracted acceleration magnitude (m/s²) that
    /// counts as an effort when the speed stream is unavailable (draft 3.0).
    public var burstMinMagnitudeMPS2: Double
    /// Burst fallback: how long the magnitude must hold above the burst
    /// threshold (seconds).
    public var burstMinDurationS: Double
    /// Burst fallback: how long the magnitude must stay below threshold before
    /// the effort ends (seconds).
    public var burstExitGraceS: Double
    public var confidence: CalibrationConfidenceV1

    public static let draft = SprintThresholdV1(
        minSpeedMPS: 6.0,
        highSpeedRunningMinMPS: 5.0,
        minDurationS: 1.0,
        requiresAccelerometerConfirmation: false,
        exitGraceS: 0.5,
        burstMinMagnitudeMPS2: 3.0,
        burstMinDurationS: 1.0,
        burstExitGraceS: 0.5,
        confidence: .uncalibrated
    )

    public init(
        minSpeedMPS: Double,
        highSpeedRunningMinMPS: Double = 5.0,
        minDurationS: Double,
        requiresAccelerometerConfirmation: Bool,
        exitGraceS: Double,
        burstMinMagnitudeMPS2: Double = 3.0,
        burstMinDurationS: Double = 1.0,
        burstExitGraceS: Double = 0.5,
        confidence: CalibrationConfidenceV1
    ) {
        self.minSpeedMPS = minSpeedMPS
        self.highSpeedRunningMinMPS = highSpeedRunningMinMPS
        self.minDurationS = minDurationS
        self.requiresAccelerometerConfirmation = requiresAccelerometerConfirmation
        self.exitGraceS = exitGraceS
        self.burstMinMagnitudeMPS2 = burstMinMagnitudeMPS2
        self.burstMinDurationS = burstMinDurationS
        self.burstExitGraceS = burstExitGraceS
        self.confidence = confidence
    }
}

// MARK: - Zone summary (companion-computed)

public struct HRZoneV1: Codable, Sendable, Equatable {
    /// 1 (recovery) ... 5 (maximal); bounds derived from estimated HR max.
    public let zone: Int
    public let lowerBPM: Double
    public let upperBPM: Double
    public let seconds: Double

    public init(zone: Int, lowerBPM: Double, upperBPM: Double, seconds: Double) {
        self.zone = zone
        self.lowerBPM = lowerBPM
        self.upperBPM = upperBPM
        self.seconds = seconds
    }
}

public struct SessionZoneSummaryV1: Codable, Sendable, Equatable {
    public let zones: [HRZoneV1]
    /// Training impulse (arbitrary units): sum of seconds × zone weight.
    public let trimp: SessionMetricV1?
    /// Seconds with HR above the high-effort threshold (default 160).
    public let timeAboveHighThresholdS: Double?
    public let estimatedHRMaxBPM: Double

    public init(
        zones: [HRZoneV1],
        trimp: SessionMetricV1?,
        timeAboveHighThresholdS: Double?,
        estimatedHRMaxBPM: Double
    ) {
        self.zones = zones
        self.trimp = trimp
        self.timeAboveHighThresholdS = timeAboveHighThresholdS
        self.estimatedHRMaxBPM = estimatedHRMaxBPM
    }
}

// MARK: - Fatigue curve

/// One bucket of the match (e.g. every 5 minutes of play). `recoverySeconds`
/// is the 160 -> 140 recovery time measured inside this bucket; nil when no
/// high-effort ending fell in it.
public struct FatiguePointV1: Codable, Sendable, Equatable {
    public let bucketStartMinute: Int
    /// Filled by the analyst; nil when no high-effort ending fell in this bucket.
    public var recoverySeconds: Double?
    public var peakBPM: Double?
    public var sprintCount: Int

    public init(bucketStartMinute: Int, recoverySeconds: Double?, peakBPM: Double?, sprintCount: Int) {
        self.bucketStartMinute = bucketStartMinute
        self.recoverySeconds = recoverySeconds
        self.peakBPM = peakBPM
        self.sprintCount = sprintCount
    }
}

public struct FatigueCurveV1: Codable, Sendable, Equatable {
    public let points: [FatiguePointV1]
    public let firstHalfAverageRecoveryS: Double?
    public let secondHalfAverageRecoveryS: Double?
    /// second half − first half average recovery; positive = slowing down.
    public let driftSeconds: Double?

    public init(
        points: [FatiguePointV1],
        firstHalfAverageRecoveryS: Double?,
        secondHalfAverageRecoveryS: Double?,
        driftSeconds: Double?
    ) {
        self.points = points
        self.firstHalfAverageRecoveryS = firstHalfAverageRecoveryS
        self.secondHalfAverageRecoveryS = secondHalfAverageRecoveryS
        self.driftSeconds = driftSeconds
    }
}

// MARK: - Sprint quality

public struct SprintQualityV1: Codable, Sendable, Equatable {
    public let sprintCount: Int
    public let averageDurationS: SessionMetricV1?
    public let averageMaxSpeedMPS: SessionMetricV1?
    public let averagePeakHR: SessionMetricV1?
    /// Average HR at effort onset — rises as recovery between efforts worsens.
    public let averageOnsetHR: SessionMetricV1?
    /// Sprints per minute of play.
    public let frequencyPerMinute: SessionMetricV1?
    /// Fractional speed decrement: (first 15 min avg max speed − last 15 min
    /// avg max speed) / first 15 min avg max speed. Positive = slowing.
    public let lateGameSpeedDecrementFraction: SessionMetricV1?

    public init(
        sprintCount: Int,
        averageDurationS: SessionMetricV1?,
        averageMaxSpeedMPS: SessionMetricV1?,
        averagePeakHR: SessionMetricV1?,
        averageOnsetHR: SessionMetricV1?,
        frequencyPerMinute: SessionMetricV1?,
        lateGameSpeedDecrementFraction: SessionMetricV1?
    ) {
        self.sprintCount = sprintCount
        self.averageDurationS = averageDurationS
        self.averageMaxSpeedMPS = averageMaxSpeedMPS
        self.averagePeakHR = averagePeakHR
        self.averageOnsetHR = averageOnsetHR
        self.frequencyPerMinute = frequencyPerMinute
        self.lateGameSpeedDecrementFraction = lateGameSpeedDecrementFraction
    }
}

// MARK: - Work : rest

public struct WorkRestSummaryV1: Codable, Sendable, Equatable {
    public let highIntensityEffortCount: Int
    public let workSeconds: Double
    public let restSeconds: Double
    /// rest : work (e.g. 3.0 = three seconds of recovery per second of work).
    public let ratio: Double?
    public let longestHighIntensityRunS: Double?
    public let medianRecoveryBetweenEffortsS: Double?

    public init(
        highIntensityEffortCount: Int,
        workSeconds: Double,
        restSeconds: Double,
        ratio: Double?,
        longestHighIntensityRunS: Double?,
        medianRecoveryBetweenEffortsS: Double?
    ) {
        self.highIntensityEffortCount = highIntensityEffortCount
        self.workSeconds = workSeconds
        self.restSeconds = restSeconds
        self.ratio = ratio
        self.longestHighIntensityRunS = longestHighIntensityRunS
        self.medianRecoveryBetweenEffortsS = medianRecoveryBetweenEffortsS
    }
}

// MARK: - Load

public struct SpeedBandDistanceV1: Codable, Sendable, Equatable {
    public let label: String
    public let lowMPS: Double
    public let highMPS: Double
    public let meters: Double

    public init(label: String, lowMPS: Double, highMPS: Double, meters: Double) {
        self.label = label
        self.lowMPS = lowMPS
        self.highMPS = highMPS
        self.meters = meters
    }
}

public struct LoadSummaryV1: Codable, Sendable, Equatable {
    public let totalDistanceM: SessionMetricV1?
    public let distanceByBand: [SpeedBandDistanceV1]
    public let highSpeedRunningM: SessionMetricV1?
    public let sprintingM: SessionMetricV1?
    /// Counts of rapid positive/negative speed changes (injury-risk proxy).
    public let highIntensityAccelerations: Int?
    public let highIntensityDecelerations: Int?

    public init(
        totalDistanceM: SessionMetricV1?,
        distanceByBand: [SpeedBandDistanceV1],
        highSpeedRunningM: SessionMetricV1?,
        sprintingM: SessionMetricV1?,
        highIntensityAccelerations: Int?,
        highIntensityDecelerations: Int?
    ) {
        self.totalDistanceM = totalDistanceM
        self.distanceByBand = distanceByBand
        self.highSpeedRunningM = highSpeedRunningM
        self.sprintingM = sprintingM
        self.highIntensityAccelerations = highIntensityAccelerations
        self.highIntensityDecelerations = highIntensityDecelerations
    }
}

// MARK: - Readiness (pipeline-sourced)

public struct SleepStageSummaryV1: Codable, Sendable, Equatable {
    public let stage: String
    public let hours: Double

    public init(stage: String, hours: Double) {
        self.stage = stage
        self.hours = hours
    }
}

/// Readiness measured from HealthKit via the pipeline (HRV, resting HR,
/// last night's sleep). The companion never reads HealthKit directly.
public struct ReadinessSnapshotV1: Codable, Sendable, Equatable {
    public let sampledAt: Date?
    public let hrvSDNNMilliseconds: SessionMetricV1?
    public let restingHeartRateBPM: SessionMetricV1?
    public let sleepHours: SessionMetricV1?
    public let sleepStages: [SleepStageSummaryV1]?

    public init(
        sampledAt: Date?,
        hrvSDNNMilliseconds: SessionMetricV1?,
        restingHeartRateBPM: SessionMetricV1?,
        sleepHours: SessionMetricV1?,
        sleepStages: [SleepStageSummaryV1]?
    ) {
        self.sampledAt = sampledAt
        self.hrvSDNNMilliseconds = hrvSDNNMilliseconds
        self.restingHeartRateBPM = restingHeartRateBPM
        self.sleepHours = sleepHours
        self.sleepStages = sleepStages
    }
}

// MARK: - Subjective

/// Post-session self report. sRPE load = rpe × session minutes (computed by
/// the analyst, not stored here).
public struct SubjectiveSessionInputV1: Codable, Sendable, Equatable {
    /// Borg CR-10 style rating of the whole session, 1...10.
    public let rpe: Int
    /// Felt fatigue after the session, 1...10.
    public let feltFatigue: Int
    public let notes: String?
    public let submittedAt: Date?

    public init(rpe: Int, feltFatigue: Int, notes: String?, submittedAt: Date?) {
        self.rpe = rpe
        self.feltFatigue = feltFatigue
        self.notes = notes
        self.submittedAt = submittedAt
    }
}

// MARK: - Calibration

/// Result of deriving a personal sprint threshold from measured efforts.
public struct SprintCalibrationV1: Codable, Sendable, Equatable {
    /// Estimated max sprinting speed from the best observed effort.
    public let estimatedMSSMPS: Double
    /// Recommended detection threshold (80% of estimated MSS).
    public let recommendedThresholdMPS: Double
    /// Speed smoothing correction applied (distance-derived streams
    /// underestimate instantaneous peak speed).
    public let correctionFactor: Double
    /// How many qualifying efforts the estimate is based on.
    public let sampleCount: Int
    public let confidence: CalibrationConfidenceV1

    public init(estimatedMSSMPS: Double, recommendedThresholdMPS: Double,
                correctionFactor: Double, sampleCount: Int, confidence: CalibrationConfidenceV1) {
        self.estimatedMSSMPS = estimatedMSSMPS
        self.recommendedThresholdMPS = recommendedThresholdMPS
        self.correctionFactor = correctionFactor
        self.sampleCount = sampleCount
        self.confidence = confidence
    }
}

// MARK: - Analytics document (companion -> pipeline)

/// The complete analytics document for one football session. The companion
/// computes it from the decoded package and pushes it to the pipeline
/// (`POST /analytics`); the pipeline stores it keyed by the app session UUID
/// and serves it back alongside HealthKit data.
public struct SessionAnalyticsV1: Codable, Sendable, Equatable {
    /// The app's own session identity (`SessionEnvelopeV1.sessionID`).
    public let sessionID: UUID
    public let startedAt: Date
    public let sprints: [SprintEventV1]
    public let zones: SessionZoneSummaryV1?
    public let fatigueCurve: FatigueCurveV1?
    public let sprintQuality: SprintQualityV1?
    public let workRest: WorkRestSummaryV1?
    public let load: LoadSummaryV1?
    public let readiness: ReadinessSnapshotV1?
    public let subjective: SubjectiveSessionInputV1?
    /// Attached by the sync service after matching to the HealthKit workout:
    /// the pipeline's 160 -> 140 recovery in seconds.
    public let pipelineRecoverySeconds: Double?
    public let computedAt: Date

    public init(
        sessionID: UUID,
        startedAt: Date,
        sprints: [SprintEventV1],
        zones: SessionZoneSummaryV1?,
        fatigueCurve: FatigueCurveV1?,
        sprintQuality: SprintQualityV1?,
        workRest: WorkRestSummaryV1?,
        load: LoadSummaryV1?,
        readiness: ReadinessSnapshotV1?,
        subjective: SubjectiveSessionInputV1?,
        pipelineRecoverySeconds: Double?,
        computedAt: Date
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.sprints = sprints
        self.zones = zones
        self.fatigueCurve = fatigueCurve
        self.sprintQuality = sprintQuality
        self.workRest = workRest
        self.load = load
        self.readiness = readiness
        self.subjective = subjective
        self.pipelineRecoverySeconds = pipelineRecoverySeconds
        self.computedAt = computedAt
    }
}
