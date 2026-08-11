import Foundation

public enum WatchDiagnosticReportKindV1: String, Codable, Sendable, Equatable {
    case unexpectedPriorInterruption
}

public struct WatchDiagnosticCheckpointV1: Codable, Sendable, Equatable, Identifiable {
    public let sequence: Int
    public let timestamp: Date
    public let code: String
    public let detail: String?

    public var id: Int { sequence }

    public init(sequence: Int, timestamp: Date, code: String, detail: String? = nil) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.code = code
        self.detail = detail
    }
}

public struct WatchDiagnosticReportV1: Codable, Sendable, Equatable, Identifiable {
    public static let formatVersion = 1

    public let formatVersion: Int
    public let reportID: UUID
    public let attemptID: UUID
    public let kind: WatchDiagnosticReportKindV1
    public let createdAt: Date
    public let detectedAt: Date
    public let appVersion: String
    public let buildNumber: String
    public let operatingSystemVersion: String
    public let checkpoints: [WatchDiagnosticCheckpointV1]
    /// Newest-first verbose breadcrumb tail captured on the Watch. Present in
    /// build 9+ reports; older reports decode as empty.
    public let logTail: [String]

    public var id: UUID { reportID }

    public init(
        reportID: UUID = UUID(),
        attemptID: UUID,
        kind: WatchDiagnosticReportKindV1,
        createdAt: Date,
        detectedAt: Date,
        appVersion: String,
        buildNumber: String,
        operatingSystemVersion: String,
        checkpoints: [WatchDiagnosticCheckpointV1],
        logTail: [String] = []
    ) {
        self.formatVersion = Self.formatVersion
        self.reportID = reportID
        self.attemptID = attemptID
        self.kind = kind
        self.createdAt = createdAt
        self.detectedAt = detectedAt
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.operatingSystemVersion = operatingSystemVersion
        self.checkpoints = checkpoints
        self.logTail = logTail
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case reportID
        case attemptID
        case kind
        case createdAt
        case detectedAt
        case appVersion
        case buildNumber
        case operatingSystemVersion
        case checkpoints
        case logTail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        reportID = try container.decode(UUID.self, forKey: .reportID)
        attemptID = try container.decode(UUID.self, forKey: .attemptID)
        kind = try container.decode(WatchDiagnosticReportKindV1.self, forKey: .kind)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        detectedAt = try container.decode(Date.self, forKey: .detectedAt)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        operatingSystemVersion = try container.decode(String.self, forKey: .operatingSystemVersion)
        checkpoints = try container.decode([WatchDiagnosticCheckpointV1].self, forKey: .checkpoints)
        logTail = try container.decodeIfPresent([String].self, forKey: .logTail) ?? []
    }

    public func validate() throws {
        guard formatVersion == Self.formatVersion else {
            throw WatchDiagnosticTransferErrorV1.unsupportedFormat(formatVersion)
        }
        guard !appVersion.isEmpty, appVersion.count <= 40,
              !buildNumber.isEmpty, buildNumber.count <= 40,
              !operatingSystemVersion.isEmpty, operatingSystemVersion.count <= 160,
              !checkpoints.isEmpty, checkpoints.count <= 64,
              logTail.count <= 200 else {
            throw WatchDiagnosticTransferErrorV1.invalidReport
        }
        for line in logTail {
            guard line.count <= 300 else {
                throw WatchDiagnosticTransferErrorV1.invalidReport
            }
        }

        var expectedSequence = checkpoints[0].sequence
        for checkpoint in checkpoints {
            guard checkpoint.sequence == expectedSequence,
                  !checkpoint.code.isEmpty,
                  checkpoint.code.count <= 80,
                  (checkpoint.detail?.count ?? 0) <= 240 else {
                throw WatchDiagnosticTransferErrorV1.invalidReport
            }
            expectedSequence += 1
        }
    }
}

public struct WatchDiagnosticReceiptV1: Codable, Sendable, Equatable {
    public static let formatVersion = 1

    public let formatVersion: Int
    public let receiptID: UUID
    public let reportID: UUID
    public let acknowledgedAt: Date

    public init(
        receiptID: UUID = UUID(),
        reportID: UUID,
        acknowledgedAt: Date = Date()
    ) {
        self.formatVersion = Self.formatVersion
        self.receiptID = receiptID
        self.reportID = reportID
        self.acknowledgedAt = acknowledgedAt
    }

    public func validate() throws {
        guard formatVersion == Self.formatVersion else {
            throw WatchDiagnosticTransferErrorV1.unsupportedFormat(formatVersion)
        }
    }
}

public enum WatchDiagnosticTransferErrorV1: Error, Sendable, Equatable {
    case unsupportedFormat(Int)
    case invalidReport
}

public enum WatchDiagnosticTransferCodecV1 {
    public static let reportKey = "com.prateekranka.footballperformance.watch-diagnostic-v1"
    public static let receiptKey = "com.prateekranka.footballperformance.watch-diagnostic-receipt-v1"

    public static func encodeReport(_ report: WatchDiagnosticReportV1) throws -> Data {
        try report.validate()
        return try makeEncoder().encode(report)
    }

    public static func decodeReport(_ data: Data) throws -> WatchDiagnosticReportV1 {
        let report = try PropertyListDecoder().decode(WatchDiagnosticReportV1.self, from: data)
        try report.validate()
        return report
    }

    public static func encodeReceipt(_ receipt: WatchDiagnosticReceiptV1) throws -> Data {
        try receipt.validate()
        return try makeEncoder().encode(receipt)
    }

    public static func decodeReceipt(_ data: Data) throws -> WatchDiagnosticReceiptV1 {
        let receipt = try PropertyListDecoder().decode(WatchDiagnosticReceiptV1.self, from: data)
        try receipt.validate()
        return receipt
    }

    private static func makeEncoder() -> PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
