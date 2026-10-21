import Foundation
import zlib

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
    case gzipFailure(Int32)
}

public enum SessionTransferCodecV1 {
    public static let metadataKey = "footySessionTransferEnvelopeV1"
    public static let receiptKey = "footySessionSyncReceiptV1"

    public static func inspectCompletePackage(
        at url: URL,
        createdAt: Date = Date()
    ) throws -> InspectedSessionPackageV1 {
        // Bounded-memory scan: packages of unbounded session length are
        // inspected on the Watch before transfer; a full-frame decode there
        // trips watchOS jetsam. Only envelope + completion are retained.
        let scan = try FootySessionPackageV1.scanStructure(of: url)
        guard scan.status == .complete else {
            throw SessionTransferErrorV1.incompletePackage
        }
        guard let sessionEnvelope = scan.envelope else {
            throw SessionTransferErrorV1.missingEnvelope
        }
        guard let completion = scan.completion else {
            throw SessionTransferErrorV1.missingCompletion
        }

        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = UInt64(values.fileSize ?? 0)
        let transferEnvelope = SessionTransferEnvelopeV1(
            sessionID: sessionEnvelope.sessionID,
            packageDigest: scan.wholeFileDigest,
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

public enum SessionTransferGzipV1 {
    private static let bufferSize = 64 * 1024

    public static func compressPackage(at sourceURL: URL, to destinationURL: URL) throws {
        let temporaryURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).gzip-partial")
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        guard let output = gzopen(temporaryURL.path, "wb1") else {
            throw SessionTransferErrorV1.gzipFailure(Z_ERRNO)
        }
        var outputIsOpen = true
        defer {
            if outputIsOpen { gzclose(output) }
            try? FileManager.default.removeItem(at: temporaryURL)
        }

        var hasMore = true
        while hasMore {
            hasMore = try autoreleasepool {
                guard let data = try source.read(upToCount: bufferSize), !data.isEmpty else {
                    return false
                }
                let written = data.withUnsafeBytes { bytes in
                    gzwrite(output, bytes.baseAddress, UInt32(bytes.count))
                }
                guard written == data.count else {
                    var code: Int32 = Z_OK
                    _ = gzerror(output, &code)
                    throw SessionTransferErrorV1.gzipFailure(code)
                }
                return true
            }
        }
        let code = gzclose(output)
        outputIsOpen = false
        guard code == Z_OK else {
            throw SessionTransferErrorV1.gzipFailure(code)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }

    public static func decompressPackageIfNeeded(
        at url: URL,
        expectedByteCount: UInt64
    ) throws {
        let source = try FileHandle(forReadingFrom: url)
        let header: Data
        do {
            header = try source.read(upToCount: 3) ?? Data()
            try source.close()
        } catch {
            try? source.close()
            throw error
        }
        guard header.starts(with: [0x1f, 0x8b]) else { return }
        guard header.count == 3, header[2] == 8 else {
            throw SessionTransferErrorV1.gzipFailure(Z_DATA_ERROR)
        }

        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).gunzip-partial")
        guard let input = gzopen(url.path, "rb") else {
            throw SessionTransferErrorV1.gzipFailure(Z_ERRNO)
        }
        var inputIsOpen = true
        defer {
            if inputIsOpen { gzclose(input) }
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: temporaryURL)
        defer { try? output.close() }
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var byteCount: UInt64 = 0

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                gzread(input, bytes.baseAddress, UInt32(bytes.count))
            }
            guard count >= 0 else {
                var code: Int32 = Z_OK
                _ = gzerror(input, &code)
                throw SessionTransferErrorV1.gzipFailure(code)
            }
            if count == 0 { break }
            guard UInt64(count) <= expectedByteCount - byteCount else {
                throw SessionTransferErrorV1.invalidByteCount
            }
            byteCount += UInt64(count)
            try autoreleasepool {
                try output.write(contentsOf: Data(buffer.prefix(Int(count))))
            }
        }

        let code = gzclose(input)
        inputIsOpen = false
        guard code == Z_OK else {
            throw SessionTransferErrorV1.gzipFailure(code)
        }
        guard byteCount == expectedByteCount else {
            throw SessionTransferErrorV1.invalidByteCount
        }
        try output.synchronize()
        try output.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
    }
}

/// The player's maximum heart rate, sent from the iPhone (where the age is
/// entered) to the Watch, which colors its live effort zones with it.
public enum PlayerProfileContextV1 {
    public static let maximumHeartRateKey = "playerMaxHeartRate"

    /// Zero or missing means "not set"; the Watch then uses its fallback.
    public static func maximumHeartRate(in context: [String: Any]) -> Double? {
        guard let value = context[maximumHeartRateKey] as? Double,
              value.isFinite, (100...230).contains(value) else { return nil }
        return value
    }
}
