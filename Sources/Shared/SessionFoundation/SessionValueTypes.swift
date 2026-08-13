import Foundation

/// The durable on-device format version. New versions must use a new package
/// reader rather than attempting to reinterpret a package written by v1.
public enum SessionPackageVersionV1 {
    public static let value: UInt32 = 1
}

public enum SessionLifecycleV1: Codable, Sendable, Equatable {
    case completed
    case interrupted(reason: SessionInterruptionReasonV1)
}

public enum SessionInterruptionReasonV1: String, Codable, Sendable, Equatable {
    case appTerminated
    case workoutEndedUnexpectedly
    case storageFailure
    case partialFileRecovery
    case userAbandoned
    case unknown
}

public enum StreamUnavailabilityReasonV1: String, Codable, Sendable, Equatable {
    case hardwareUnsupported
    case permissionDenied
    case authorizationUnavailable
    case serviceUnavailable
    case disabledByUser
    case captureNotStarted
    case sourceError
}

public enum StreamInsufficiencyReasonV1: String, Codable, Sendable, Equatable {
    case noSamples
    case insufficientSamples
    case insufficientCoverage
    case excessiveGaps
    case captureEndedEarly
}

/// A stream may be explicitly unavailable or insufficient. A missing stream is
/// never represented by a numeric value such as zero.
public enum StreamAvailabilityV1: Codable, Sendable, Equatable {
    case available
    case unavailable(reason: StreamUnavailabilityReasonV1)
    case insufficient(reason: StreamInsufficiencyReasonV1)
}

public enum MotionCaptureSourceV1: Codable, Sendable, Equatable {
    case batchedCoreMotion
    case foregroundFallback
    case unavailable(reason: StreamUnavailabilityReasonV1)
}

public enum HealthKitUnavailabilityReasonV1: String, Codable, Sendable, Equatable {
    case healthDataUnavailable
    case notAttempted
    case serviceUnavailable
}

public enum HealthKitAuthorizationIssueV1: String, Codable, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case requestFailed
}

/// This records the outcome only. It deliberately contains no HealthKit object
/// or delete capability, so a package can be shared by targets without gaining
/// HealthKit authority.
public enum HealthKitSaveOutcomeV1: Codable, Sendable, Equatable {
    case saved(workoutUUID: UUID?)
    case failed(message: String)
    case unavailable(reason: HealthKitUnavailabilityReasonV1)
    case authorizationIssue(reason: HealthKitAuthorizationIssueV1)
}

public enum MetricProvenanceV1: String, Codable, Sendable, Equatable {
    case healthKitLive
    case healthKitFinalWorkout
    case coreMotionBatched
    case coreMotionFallback
    case capturedDeviceEstimate
}

public enum MetricUnitV1: String, Codable, Sendable, Equatable {
    case seconds
    case meters
    case beatsPerMinute
    case kilocalories
    case count
}

/// A measured quantity is paired with the source that produced it. This type
/// does not imply that the app derived an action, sprint, or spatial result.
public struct SessionMetricV1: Codable, Sendable, Equatable {
    public let value: Double
    public let unit: MetricUnitV1
    public let provenance: MetricProvenanceV1
    public let measuredAt: Date?

    public init(
        value: Double,
        unit: MetricUnitV1,
        provenance: MetricProvenanceV1,
        measuredAt: Date? = nil
    ) {
        self.value = value
        self.unit = unit
        self.provenance = provenance
        self.measuredAt = measuredAt
    }
}

/// These are summary values as reported by their sources. They are optional so
/// a caller cannot accidentally convert an unavailable stream into a zero.
public struct SessionSummaryMetricsV1: Codable, Sendable, Equatable {
    public let duration: SessionMetricV1?
    public let distance: SessionMetricV1?
    public let averageHeartRate: SessionMetricV1?
    public let activeEnergy: SessionMetricV1?

    public init(
        duration: SessionMetricV1? = nil,
        distance: SessionMetricV1? = nil,
        averageHeartRate: SessionMetricV1? = nil,
        activeEnergy: SessionMetricV1? = nil
    ) {
        self.duration = duration
        self.distance = distance
        self.averageHeartRate = averageHeartRate
        self.activeEnergy = activeEnergy
    }
}

public struct HeartRateSnapshotV1: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let beatsPerMinute: SessionMetricV1

    public init(timestamp: Date, beatsPerMinute: SessionMetricV1) {
        self.timestamp = timestamp
        self.beatsPerMinute = beatsPerMinute
    }
}

public struct DistanceSnapshotV1: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let meters: SessionMetricV1

    public init(timestamp: Date, meters: SessionMetricV1) {
        self.timestamp = timestamp
        self.meters = meters
    }
}

public struct Vector3V1: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct AccelerometerSampleV1: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let acceleration: Vector3V1

    public init(timestamp: TimeInterval, acceleration: Vector3V1) {
        self.timestamp = timestamp
        self.acceleration = acceleration
    }
}

public struct DeviceMotionSampleV1: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval
    public let userAcceleration: Vector3V1
    public let gravity: Vector3V1
    public let rotationRate: Vector3V1

    public init(
        timestamp: TimeInterval,
        userAcceleration: Vector3V1,
        gravity: Vector3V1,
        rotationRate: Vector3V1
    ) {
        self.timestamp = timestamp
        self.userAcceleration = userAcceleration
        self.gravity = gravity
        self.rotationRate = rotationRate
    }
}

public struct AccelerometerBatchV1: Codable, Sendable, Equatable {
    public let source: MotionCaptureSourceV1
    public let samples: [AccelerometerSampleV1]

    public init(source: MotionCaptureSourceV1, samples: [AccelerometerSampleV1]) {
        self.source = source
        self.samples = samples
    }
}

public struct DeviceMotionBatchV1: Codable, Sendable, Equatable {
    public let source: MotionCaptureSourceV1
    public let samples: [DeviceMotionSampleV1]

    public init(source: MotionCaptureSourceV1, samples: [DeviceMotionSampleV1]) {
        self.source = source
        self.samples = samples
    }
}

public struct CaptureDiagnosticsV1: Codable, Sendable, Equatable {
    public let recordedAt: Date
    public let source: MotionCaptureSourceV1
    public let accelerometerAvailability: StreamAvailabilityV1
    public let deviceMotionAvailability: StreamAvailabilityV1
    public let accelerometerSampleCount: Int
    public let deviceMotionSampleCount: Int
    public let accelerometerReportedHz: Double?
    public let deviceMotionReportedHz: Double?
    public let accelerometerBatchCount: Int
    public let deviceMotionBatchCount: Int
    public let accelerometerLastError: String?
    public let deviceMotionLastError: String?
    public let maximumObservedGap: TimeInterval?

    public init(
        recordedAt: Date,
        source: MotionCaptureSourceV1,
        accelerometerAvailability: StreamAvailabilityV1,
        deviceMotionAvailability: StreamAvailabilityV1,
        accelerometerSampleCount: Int,
        deviceMotionSampleCount: Int,
        accelerometerReportedHz: Double? = nil,
        deviceMotionReportedHz: Double? = nil,
        accelerometerBatchCount: Int = 0,
        deviceMotionBatchCount: Int = 0,
        accelerometerLastError: String? = nil,
        deviceMotionLastError: String? = nil,
        maximumObservedGap: TimeInterval? = nil
    ) {
        self.recordedAt = recordedAt
        self.source = source
        self.accelerometerAvailability = accelerometerAvailability
        self.deviceMotionAvailability = deviceMotionAvailability
        self.accelerometerSampleCount = accelerometerSampleCount
        self.deviceMotionSampleCount = deviceMotionSampleCount
        self.accelerometerReportedHz = accelerometerReportedHz
        self.deviceMotionReportedHz = deviceMotionReportedHz
        self.accelerometerBatchCount = accelerometerBatchCount
        self.deviceMotionBatchCount = deviceMotionBatchCount
        self.accelerometerLastError = accelerometerLastError
        self.deviceMotionLastError = deviceMotionLastError
        self.maximumObservedGap = maximumObservedGap
    }

    private enum CodingKeys: String, CodingKey {
        case recordedAt
        case source
        case accelerometerAvailability
        case deviceMotionAvailability
        case accelerometerSampleCount
        case deviceMotionSampleCount
        case accelerometerReportedHz
        case deviceMotionReportedHz
        case accelerometerBatchCount
        case deviceMotionBatchCount
        case accelerometerLastError
        case deviceMotionLastError
        case maximumObservedGap
    }

    /// Packages sealed before the per-stream delivery fields existed must still
    /// decode: the added keys are read optionally and default to nil/zero.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        source = try container.decode(MotionCaptureSourceV1.self, forKey: .source)
        accelerometerAvailability = try container.decode(
            StreamAvailabilityV1.self,
            forKey: .accelerometerAvailability
        )
        deviceMotionAvailability = try container.decode(
            StreamAvailabilityV1.self,
            forKey: .deviceMotionAvailability
        )
        accelerometerSampleCount = try container.decode(Int.self, forKey: .accelerometerSampleCount)
        deviceMotionSampleCount = try container.decode(Int.self, forKey: .deviceMotionSampleCount)
        accelerometerReportedHz = try container.decodeIfPresent(Double.self, forKey: .accelerometerReportedHz)
        deviceMotionReportedHz = try container.decodeIfPresent(Double.self, forKey: .deviceMotionReportedHz)
        accelerometerBatchCount = try container.decodeIfPresent(Int.self, forKey: .accelerometerBatchCount) ?? 0
        deviceMotionBatchCount = try container.decodeIfPresent(Int.self, forKey: .deviceMotionBatchCount) ?? 0
        accelerometerLastError = try container.decodeIfPresent(String.self, forKey: .accelerometerLastError)
        deviceMotionLastError = try container.decodeIfPresent(String.self, forKey: .deviceMotionLastError)
        maximumObservedGap = try container.decodeIfPresent(TimeInterval.self, forKey: .maximumObservedGap)
    }
}

public enum CaptureQualityLevelV1: String, Codable, Sendable, Equatable {
    case info
    case warning
    case error
}

public struct CaptureQualityEventV1: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let level: CaptureQualityLevelV1
    public let code: String
    public let detail: String

    public init(timestamp: Date, level: CaptureQualityLevelV1, code: String, detail: String) {
        self.timestamp = timestamp
        self.level = level
        self.code = code
        self.detail = detail
    }
}

public struct SessionEnvelopeV1: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let createdAt: Date
    public let startedAt: Date
    public let captureSource: MotionCaptureSourceV1
    public let initialAccelerometerAvailability: StreamAvailabilityV1
    public let initialDeviceMotionAvailability: StreamAvailabilityV1

    public init(
        sessionID: UUID,
        createdAt: Date,
        startedAt: Date,
        captureSource: MotionCaptureSourceV1,
        initialAccelerometerAvailability: StreamAvailabilityV1,
        initialDeviceMotionAvailability: StreamAvailabilityV1
    ) {
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.captureSource = captureSource
        self.initialAccelerometerAvailability = initialAccelerometerAvailability
        self.initialDeviceMotionAvailability = initialDeviceMotionAvailability
    }
}

public struct SessionCompletionV1: Codable, Sendable, Equatable {
    public let endedAt: Date
    public let lifecycle: SessionLifecycleV1
    public let summary: SessionSummaryMetricsV1?
    public let healthKitSaveOutcome: HealthKitSaveOutcomeV1

    public init(
        endedAt: Date,
        lifecycle: SessionLifecycleV1,
        summary: SessionSummaryMetricsV1?,
        healthKitSaveOutcome: HealthKitSaveOutcomeV1
    ) {
        self.endedAt = endedAt
        self.lifecycle = lifecycle
        self.summary = summary
        self.healthKitSaveOutcome = healthKitSaveOutcome
    }
}

public struct SessionDigestV1: Codable, Sendable, Equatable, Hashable {
    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// A receipt is intentionally transport-neutral. Sync implementations may use
/// it, but this foundation performs no networking or account work.
public struct SyncReceiptV1: Codable, Sendable, Equatable {
    public let receiptID: UUID
    public let sessionID: UUID
    public let packageDigest: SessionDigestV1
    public let acknowledgedAt: Date
    public let destination: String

    public init(
        receiptID: UUID,
        sessionID: UUID,
        packageDigest: SessionDigestV1,
        acknowledgedAt: Date,
        destination: String
    ) {
        self.receiptID = receiptID
        self.sessionID = sessionID
        self.packageDigest = packageDigest
        self.acknowledgedAt = acknowledgedAt
        self.destination = destination
    }
}
