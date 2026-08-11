import Foundation

public struct SessionTransferEnvelopeV1: Codable, Sendable, Equatable {
    public static let schema = "com.prateekranka.footballperformance.session-transfer"
    public static let schemaVersion = 1

    public let schema: String
    public let schemaVersion: Int
    public let sessionID: UUID
    public let packageDigest: SessionDigestV1
    public let byteCount: UInt64
    public let createdAt: Date

    public init(
        sessionID: UUID,
        packageDigest: SessionDigestV1,
        byteCount: UInt64,
        createdAt: Date
    ) {
        self.schema = Self.schema
        self.schemaVersion = Self.schemaVersion
        self.sessionID = sessionID
        self.packageDigest = packageDigest
        self.byteCount = byteCount
        self.createdAt = createdAt
    }

    public func validate() throws {
        guard schema == Self.schema, schemaVersion == Self.schemaVersion else {
            throw SessionTransferErrorV1.unsupportedEnvelope
        }
        guard byteCount > 0 else {
            throw SessionTransferErrorV1.invalidByteCount
        }
        guard packageDigest.bytes.count == 32 else {
            throw SessionTransferErrorV1.invalidDigest
        }
    }
}

public struct InspectedSessionPackageV1: Sendable, Equatable {
    public let transferEnvelope: SessionTransferEnvelopeV1
    public let sessionEnvelope: SessionEnvelopeV1
    public let completion: SessionCompletionV1

    public init(
        transferEnvelope: SessionTransferEnvelopeV1,
        sessionEnvelope: SessionEnvelopeV1,
        completion: SessionCompletionV1
    ) {
        self.transferEnvelope = transferEnvelope
        self.sessionEnvelope = sessionEnvelope
        self.completion = completion
    }
}

public enum SessionTransferErrorV1: Error, Sendable, Equatable {
    case unsupportedEnvelope
    case invalidByteCount
    case invalidDigest
    case incompletePackage
    case missingEnvelope
    case missingCompletion
    case metadataMismatch
}

public enum SessionTransferCodecV1 {
    public static let metadataKey = "footySessionTransferEnvelopeV1"
    public static let receiptKey = "footySessionSyncReceiptV1"

    public static func inspectCompletePackage(
        at url: URL,
        createdAt: Date = Date()
    ) throws -> InspectedSessionPackageV1 {
        let read = try FootySessionPackageV1.read(from: url)
        guard read.status == .complete else {
            throw SessionTransferErrorV1.incompletePackage
        }
        guard let first = read.frames.first,
              case let .envelope(sessionEnvelope) = first.payload else {
            throw SessionTransferErrorV1.missingEnvelope
        }
        guard let last = read.frames.last,
              case let .completion(completion) = last.payload else {
            throw SessionTransferErrorV1.missingCompletion
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = UInt64(values.fileSize ?? 0)
        let transferEnvelope = SessionTransferEnvelopeV1(
            sessionID: sessionEnvelope.sessionID,
            packageDigest: read.wholeFileDigest,
            byteCount: byteCount,
            createdAt: createdAt
        )
        try transferEnvelope.validate()

        return InspectedSessionPackageV1(
            transferEnvelope: transferEnvelope,
            sessionEnvelope: sessionEnvelope,
            completion: completion
        )
    }

    public static func encodeTransferEnvelope(
        _ envelope: SessionTransferEnvelopeV1
    ) throws -> Data {
        try envelope.validate()
        return try makeEncoder().encode(envelope)
    }

    public static func decodeTransferEnvelope(_ data: Data) throws -> SessionTransferEnvelopeV1 {
        let envelope = try PropertyListDecoder().decode(
            SessionTransferEnvelopeV1.self,
            from: data
        )
        try envelope.validate()
        return envelope
    }

    public static func encodeReceipt(_ receipt: SyncReceiptV1) throws -> Data {
        guard receipt.packageDigest.bytes.count == 32 else {
            throw SessionTransferErrorV1.invalidDigest
        }
        return try makeEncoder().encode(receipt)
    }

    public static func decodeReceipt(_ data: Data) throws -> SyncReceiptV1 {
        let receipt = try PropertyListDecoder().decode(SyncReceiptV1.self, from: data)
        guard receipt.packageDigest.bytes.count == 32 else {
            throw SessionTransferErrorV1.invalidDigest
        }
        return receipt
    }

    public static func validate(
        packageAt url: URL,
        matches metadata: SessionTransferEnvelopeV1
    ) throws -> InspectedSessionPackageV1 {
        try metadata.validate()
        let inspected = try inspectCompletePackage(at: url)
        guard inspected.transferEnvelope.sessionID == metadata.sessionID,
              inspected.transferEnvelope.packageDigest == metadata.packageDigest,
              inspected.transferEnvelope.byteCount == metadata.byteCount else {
            throw SessionTransferErrorV1.metadataMismatch
        }
        return inspected
    }

    private static func makeEncoder() -> PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
