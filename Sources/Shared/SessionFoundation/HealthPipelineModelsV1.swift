import Foundation

/// JSON contract for the health pipeline API
/// (http://100.77.127.123:8788, private tailnet only).
///
/// The server is the pipeline host (Linux box). API docs and the server-side
/// implementation live in `/home/bobbyranka/health-data/README.md` and
/// `api.py` on that host. All timestamps on the wire are UTC ISO-8601
/// (`2026-08-28T05:15:02+00:00`), decoded here to `Date`.

public enum HealthPipelineErrorV1: Error, Sendable, Equatable {
    case invalidResponse
    case httpStatus(Int)
    case undecodablePayload(String)
}

/// Shared ISO-8601 codec for the pipeline contract (no fractional seconds,
/// accepts both `Z` and `+00:00` offsets). Sendable-safe: no shared mutable
/// formatter state (ISO8601DateFormatter is not Sendable under Swift 6).
public enum HealthPipelineDateCodingV1 {
    public static func decode(_ decoder: Decoder) throws -> Date {
        let s = try decoder.singleValueContainer().decode(String.self)
        return try parse(s)
    }

    public static func parse(_ string: String) throws -> Date {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: false)) {
            return date
        }
        if let date = try? Date(string, strategy: .iso8601) {
            return date
        }
        throw HealthPipelineErrorV1.undecodablePayload("date \(string)")
    }

    public static func encode(_ date: Date, to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string(from: date))
    }

    public static func string(from date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: false))
    }
}

// MARK: - Server responses

public struct HealthPipelineStatusV1: Codable, Sendable, Equatable {
    public let ok: Bool
    public let workouts: Int
    public let workoutLatestUTC: Date?
    public let hrSamples: Int
    public let hrLatestUTC: Date?
    public let samples: Int
    public let sampleTypes: Int
    public let sampleLatestUTC: Date?
    public let packages: Int
    public let service: String
    public let version: Int

    public init(ok: Bool, workouts: Int, workoutLatestUTC: Date?, hrSamples: Int,
                hrLatestUTC: Date?, samples: Int, sampleTypes: Int, sampleLatestUTC: Date?,
                packages: Int, service: String, version: Int) {
        self.ok = ok
        self.workouts = workouts
        self.workoutLatestUTC = workoutLatestUTC
        self.hrSamples = hrSamples
        self.hrLatestUTC = hrLatestUTC
        self.samples = samples
        self.sampleTypes = sampleTypes
        self.sampleLatestUTC = sampleLatestUTC
        self.packages = packages
        self.service = service
        self.version = version
    }
}

public struct HealthPipelineRecoveryV1: Codable, Sendable, Equatable {
    /// Recovery definition (server): seconds from the last heart rate above
    /// `high` to the first point where HR stays at/below `low` for `sustainS`.
    public let high: Double
    public let low: Double
    public let sustainS: Double
    public let peakBPM: Double?
    public let lastAboveUTC: Date?
    public let firstSustainedUTC: Date?
    public let seconds: Double?

    public init(high: Double, low: Double, sustainS: Double, peakBPM: Double?,
                lastAboveUTC: Date?, firstSustainedUTC: Date?, seconds: Double?) {
        self.high = high
        self.low = low
        self.sustainS = sustainS
        self.peakBPM = peakBPM
        self.lastAboveUTC = lastAboveUTC
        self.firstSustainedUTC = firstSustainedUTC
        self.seconds = seconds
    }

    /// "4m 35s" style display string; nil when no recovery was measured.
    public var formattedRecovery: String? {
        guard let seconds else { return nil }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(String(format: "%02d", s))s"
    }
}

public struct HealthPipelineSessionV1: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let activityType: String
    public let startUTC: Date
    public let endUTC: Date
    public let durationS: Double?
    public let sourceName: String?
    public let localDate: String?
    public let recovery: HealthPipelineRecoveryV1?

    public init(id: Int, activityType: String, startUTC: Date, endUTC: Date,
                durationS: Double?, sourceName: String?, localDate: String?,
                recovery: HealthPipelineRecoveryV1?) {
        self.id = id
        self.activityType = activityType
        self.startUTC = startUTC
        self.endUTC = endUTC
        self.durationS = durationS
        self.sourceName = sourceName
        self.localDate = localDate
        self.recovery = recovery
    }
}

/// One HR sample as the server sends it: `[timestampString, bpm]`.
public struct HealthPipelineHeartRatePointV1: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let bpm: Double

    public init(timestamp: Date, bpm: Double) {
        self.timestamp = timestamp
        self.bpm = bpm
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        let ts = try c.decode(String.self)
        self.timestamp = try HealthPipelineDateCodingV1.parse(ts)
        self.bpm = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(HealthPipelineDateCodingV1.string(from: timestamp))
        try c.encode(bpm)
    }
}

public struct HealthPipelineHeartRateResponseV1: Codable, Sendable, Equatable {
    public let sessionID: Int
    public let samples: [HealthPipelineHeartRatePointV1]

    public init(sessionID: Int, samples: [HealthPipelineHeartRatePointV1]) {
        self.sessionID = sessionID
        self.samples = samples
    }
}

public struct HealthPipelineSampleV1: Codable, Sendable, Equatable {
    public let type: String
    public let startUTC: Date
    public let endUTC: Date
    public let value: String
    public let unit: String?
    public let sourceName: String?

    public init(type: String, startUTC: Date, endUTC: Date, value: String,
                unit: String?, sourceName: String?) {
        self.type = type
        self.startUTC = startUTC
        self.endUTC = endUTC
        self.value = value
        self.unit = unit
        self.sourceName = sourceName
    }
}

public struct HealthPipelineSessionsResponseV1: Codable, Sendable, Equatable {
    public let sessions: [HealthPipelineSessionV1]
    public init(sessions: [HealthPipelineSessionV1]) { self.sessions = sessions }
}

// MARK: - Request payloads

/// One record accepted by `POST /ingest`. Field names match the server's
/// accepted keys (`startDate`, `endDate`, `value`, `unit`, `sourceName`,
/// optional `duration` for workouts).
public struct HealthPipelineIngestRecordV1: Encodable, Sendable, Equatable {
    public let type: String
    public let startDate: Date
    public let endDate: Date
    public let value: Double?
    public let unit: String?
    public let sourceName: String?
    public let duration: Double?

    public init(type: String, startDate: Date, endDate: Date, value: Double? = nil,
                unit: String? = nil, sourceName: String? = nil, duration: Double? = nil) {
        self.type = type
        self.startDate = startDate
        self.endDate = endDate
        self.value = value
        self.unit = unit
        self.sourceName = sourceName
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey {
        // snake_case raw values: the encoder's .convertToSnakeCase strategy is
        // applied to CodingKey raw values too, so camelCase here would emit
        // start_date/end_date anyway; make it explicit and stable.
        case type
        case startDate = "start_date"
        case endDate = "end_date"
        case value
        case unit
        case sourceName = "source_name"
        case duration
    }
}

public struct HealthPipelineIngestResultV1: Codable, Sendable, Equatable {
    public let ok: Bool
    public let ingested: Int
    public let workouts: Int
    public let hr: Int
    public let samples: Int
    public let metricsUpdated: Int

    public init(ok: Bool, ingested: Int, workouts: Int, hr: Int,
                samples: Int, metricsUpdated: Int) {
        self.ok = ok
        self.ingested = ingested
        self.workouts = workouts
        self.hr = hr
        self.samples = samples
        self.metricsUpdated = metricsUpdated
    }
}

public struct HealthPipelinePackageReceiptV1: Codable, Sendable, Equatable {
    public let ok: Bool
    public let sessionID: String
    public let bytes: Int

    public init(ok: Bool, sessionID: String, bytes: Int) {
        self.ok = ok
        self.sessionID = sessionID
        self.bytes = bytes
    }
}

public struct HealthPipelineAnalyticsReceiptV1: Codable, Sendable, Equatable {
    public let ok: Bool
    public let sessionID: String
    public let bytes: Int

    public init(ok: Bool, sessionID: String, bytes: Int) {
        self.ok = ok
        self.sessionID = sessionID
        self.bytes = bytes
    }
}

public struct HealthPipelineAnalyticsListResponseV1: Codable, Sendable, Equatable {
    public let analytics: [SessionAnalyticsV1]

    public init(analytics: [SessionAnalyticsV1]) {
        self.analytics = analytics
    }
}
