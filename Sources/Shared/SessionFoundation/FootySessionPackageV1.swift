import CryptoKit
import Foundation

public enum SessionFrameKindV1: String, Codable, Sendable, Equatable {
    case envelope
    case accelerometerBatch
    case deviceMotionBatch
    case heartRateSnapshot
    case distanceSnapshot
    case captureDiagnostics
    case qualityEvent
    case completion
}

public enum SessionFramePayloadV1: Codable, Sendable, Equatable {
    case envelope(SessionEnvelopeV1)
    case accelerometerBatch(AccelerometerBatchV1)
    case deviceMotionBatch(DeviceMotionBatchV1)
    case heartRateSnapshot(HeartRateSnapshotV1)
    case distanceSnapshot(DistanceSnapshotV1)
    case captureDiagnostics(CaptureDiagnosticsV1)
    case qualityEvent(CaptureQualityEventV1)
    case completion(SessionCompletionV1)

    public var kind: SessionFrameKindV1 {
        switch self {
        case .envelope:
            return .envelope
        case .accelerometerBatch:
            return .accelerometerBatch
        case .deviceMotionBatch:
            return .deviceMotionBatch
        case .heartRateSnapshot:
            return .heartRateSnapshot
        case .distanceSnapshot:
            return .distanceSnapshot
        case .captureDiagnostics:
            return .captureDiagnostics
        case .qualityEvent:
            return .qualityEvent
        case .completion:
            return .completion
        }
    }
}

/// The explicit kind is duplicated beside the payload so a decoder can reject
/// a mismatched or malformed record before it is treated as session data.
public struct FootySessionFrameV1: Codable, Sendable, Equatable {
    public let kind: SessionFrameKindV1
    public let payload: SessionFramePayloadV1

    public init(payload: SessionFramePayloadV1) {
        self.kind = payload.kind
        self.payload = payload
    }

    public init(kind: SessionFrameKindV1, payload: SessionFramePayloadV1) throws {
        guard kind == payload.kind else {
            throw SessionPackageError.invalidFrameKind
        }
        self.kind = kind
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(SessionFrameKindV1.self, forKey: .kind)
        let payload = try container.decode(SessionFramePayloadV1.self, forKey: .payload)
        try self.init(kind: kind, payload: payload)
    }
}

public struct SessionPackageReaderLimitsV1: Sendable, Equatable {
    /// The maximum uncompressed binary-property-list frame the reader will
    /// allocate. A writer applies the same bound before writing a frame.
    public let maximumFrameBytes: Int
    /// A file with more frames than this is rejected rather than accumulating an
    /// unbounded in-memory recovery result.
    public let maximumFrameCount: Int

    public init(maximumFrameBytes: Int = 1_048_576, maximumFrameCount: Int = 100_000) {
        self.maximumFrameBytes = maximumFrameBytes
        self.maximumFrameCount = maximumFrameCount
    }

    public static let `default` = SessionPackageReaderLimitsV1()
}

public enum SessionPackageReadStatusV1: String, Codable, Sendable, Equatable {
    /// The file ended on a verified completion frame.
    case complete
    /// The file ended cleanly but a completion frame was never written.
    case incomplete
    /// The final frame was interrupted. Every returned frame precedes it and
    /// has passed its integrity check.
    case tornTail
}

public struct SessionPackageReadResultV1: Sendable, Equatable {
    public let frames: [FootySessionFrameV1]
    public let status: SessionPackageReadStatusV1
    public let validPrefixByteCount: UInt64
    /// SHA-256 over exactly the bytes present on disk, including a torn tail.
    public let wholeFileDigest: SessionDigestV1

    public init(
        frames: [FootySessionFrameV1],
        status: SessionPackageReadStatusV1,
        validPrefixByteCount: UInt64,
        wholeFileDigest: SessionDigestV1
    ) {
        self.frames = frames
        self.status = status
        self.validPrefixByteCount = validPrefixByteCount
        self.wholeFileDigest = wholeFileDigest
    }

    public var hasVerifiedCompletion: Bool {
        status == .complete
    }
}

public enum SessionPackageError: Error, Sendable, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt32)
    case malformedHeader
    case truncatedHeader
    case invalidFrameLength(UInt32)
    case frameTooLarge(declared: UInt32, limit: Int)
    case tooManyFrames(limit: Int)
    case corruptFrame(index: Int)
    case corruptFrameIntegrity(index: Int)
    case invalidFrameKind
    case invalidFrameSequence(index: Int)
    case missingSessionEnvelope
    case destinationAlreadyExists
    case notAPartialPackage
    case writerIsSealed
    case invalidSynchronizationPolicy
}

/// An append-only format:
///
/// `magic[8] | version(UInt32, BE) | reserved(UInt32, BE) |
///  repeated(frameLength(UInt32, BE) | binaryPlistFrame | SHA256(frame))`
///
/// Lengths are explicit big-endian `UInt32` values. Every frame is capped by
/// `SessionPackageReaderLimitsV1`, and all unknown versions and unknown frame
/// kinds fail closed.
public enum FootySessionPackageV1 {
    public static let fileExtension = "footysession"
    public static let partialFileExtension = "partial"
    public static let headerByteCount = 16
    public static let frameDigestByteCount = 32

    private static let magic = Data([0x46, 0x54, 0x59, 0x53, 0x50, 0x4B, 0x47, 0x31]) // FTYSPKG1
    private static let reservedHeaderValue: UInt32 = 0

    public static func digest(of url: URL, readChunkSize: Int = 64 * 1024) throws -> SessionDigestV1 {
        guard readChunkSize > 0 else { throw SessionPackageError.malformedHeader }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: readChunkSize) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return SessionDigestV1(bytes: Data(hasher.finalize()))
    }

    public static func writePackage(
        frames: [FootySessionFrameV1],
        to url: URL,
        limits: SessionPackageReaderLimitsV1 = .default
    ) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SessionPackageError.destinationAlreadyExists
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw SessionPackageError.destinationAlreadyExists
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            try writeHeader(to: handle)
            for frame in frames {
                _ = try append(frame: frame, to: handle, limits: limits)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            // The caller owns the new destination and can make an explicit
            // retention decision; do not delete an on-disk partial package.
            throw error
        }
    }

    public static func read(
        from url: URL,
        limits: SessionPackageReaderLimitsV1 = .default
    ) throws -> SessionPackageReadResultV1 {
        guard limits.maximumFrameBytes > 0, limits.maximumFrameCount > 0 else {
            throw SessionPackageError.invalidSynchronizationPolicy
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var wholeFileHasher = SHA256()
        let header = try readUpTo(headerByteCount, from: handle, hasher: &wholeFileHasher)
        guard header.count == headerByteCount else {
            throw SessionPackageError.truncatedHeader
        }
        try validateHeader(header)

        var frames: [FootySessionFrameV1] = []
        frames.reserveCapacity(32)
        var validPrefixByteCount = UInt64(headerByteCount)
        var sawCompletion = false

        while true {
            let lengthData = try readUpTo(4, from: handle, hasher: &wholeFileHasher)
            if lengthData.isEmpty {
                let status: SessionPackageReadStatusV1 = sawCompletion ? .complete : .incomplete
                return makeReadResult(
                    frames: frames,
                    status: status,
                    validPrefixByteCount: validPrefixByteCount,
                    hasher: wholeFileHasher
                )
            }
            guard lengthData.count == 4 else {
                return makeReadResult(
                    frames: frames,
                    status: .tornTail,
                    validPrefixByteCount: validPrefixByteCount,
                    hasher: wholeFileHasher
                )
            }

            let declaredLength = lengthData.uint32BigEndian(at: 0)
            guard declaredLength > 0 else {
                throw SessionPackageError.invalidFrameLength(declaredLength)
            }
            guard declaredLength <= UInt32(limits.maximumFrameBytes) else {
                throw SessionPackageError.frameTooLarge(
                    declared: declaredLength,
                    limit: limits.maximumFrameBytes
                )
            }
            guard frames.count < limits.maximumFrameCount else {
                throw SessionPackageError.tooManyFrames(limit: limits.maximumFrameCount)
            }

            let frameData = try readUpTo(Int(declaredLength), from: handle, hasher: &wholeFileHasher)
            guard frameData.count == Int(declaredLength) else {
                return makeReadResult(
                    frames: frames,
                    status: .tornTail,
                    validPrefixByteCount: validPrefixByteCount,
                    hasher: wholeFileHasher
                )
            }

            let integrity = try readUpTo(frameDigestByteCount, from: handle, hasher: &wholeFileHasher)
            guard integrity.count == frameDigestByteCount else {
                return makeReadResult(
                    frames: frames,
                    status: .tornTail,
                    validPrefixByteCount: validPrefixByteCount,
                    hasher: wholeFileHasher
                )
            }
            let expectedIntegrity = Data(SHA256.hash(data: frameData))
            guard integrity == expectedIntegrity else {
                throw SessionPackageError.corruptFrameIntegrity(index: frames.count)
            }

            let frame: FootySessionFrameV1
            do {
                frame = try PropertyListDecoder().decode(FootySessionFrameV1.self, from: frameData)
            } catch {
                throw SessionPackageError.corruptFrame(index: frames.count)
            }
            try validateFrameSequence(frame, at: frames.count, sawCompletion: sawCompletion)
            if frame.kind == .completion {
                sawCompletion = true
            }
            frames.append(frame)
            validPrefixByteCount += UInt64(4 + Int(declaredLength) + frameDigestByteCount)
        }
    }

    static func writeHeader(to handle: FileHandle) throws {
        var data = magic
        data.appendBigEndian(SessionPackageVersionV1.value)
        data.appendBigEndian(reservedHeaderValue)
        try handle.write(contentsOf: data)
    }

    @discardableResult
    static func append(
        frame: FootySessionFrameV1,
        to handle: FileHandle,
        limits: SessionPackageReaderLimitsV1
    ) throws -> Int {
        guard limits.maximumFrameBytes > 0 else {
            throw SessionPackageError.invalidSynchronizationPolicy
        }

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let frameData = try encoder.encode(frame)
        guard frameData.count <= limits.maximumFrameBytes else {
            throw SessionPackageError.frameTooLarge(
                declared: UInt32(clamping: frameData.count),
                limit: limits.maximumFrameBytes
            )
        }
        // The length prefix is UInt32. Use `UInt32(exactly:)` rather than
        // `Int(UInt32.max)` for the bound check: on arm64_32 (Apple Watch
        // ILP32 ABI) Int is 32-bit, so `Int(UInt32.max)` itself traps with
        // "Not enough bits to represent the passed value" on every call.
        guard let frameLength = UInt32(exactly: frameData.count) else {
            throw SessionPackageError.frameTooLarge(
                declared: UInt32.max,
                limit: limits.maximumFrameBytes
            )
        }

        var record = Data()
        record.reserveCapacity(4 + frameData.count + frameDigestByteCount)
        record.appendBigEndian(frameLength)
        record.append(frameData)
        record.append(Data(SHA256.hash(data: frameData)))
        try handle.write(contentsOf: record)
        return record.count
    }

    private static func validateHeader(_ data: Data) throws {
        guard data.prefix(magic.count) == magic else {
            throw SessionPackageError.invalidMagic
        }
        let version = data.uint32BigEndian(at: magic.count)
        guard version == SessionPackageVersionV1.value else {
            throw SessionPackageError.unsupportedVersion(version)
        }
        let reserved = data.uint32BigEndian(at: magic.count + 4)
        guard reserved == reservedHeaderValue else {
            throw SessionPackageError.malformedHeader
        }
    }

    private static func validateFrameSequence(
        _ frame: FootySessionFrameV1,
        at index: Int,
        sawCompletion: Bool
    ) throws {
        guard !sawCompletion else {
            throw SessionPackageError.invalidFrameSequence(index: index)
        }
        if index == 0, frame.kind != .envelope {
            throw SessionPackageError.missingSessionEnvelope
        }
        if index > 0, frame.kind == .envelope {
            throw SessionPackageError.invalidFrameSequence(index: index)
        }
    }

    private static func readUpTo(
        _ count: Int,
        from handle: FileHandle,
        hasher: inout SHA256
    ) throws -> Data {
        let data = try handle.read(upToCount: count) ?? Data()
        hasher.update(data: data)
        return data
    }

    private static func makeReadResult(
        frames: [FootySessionFrameV1],
        status: SessionPackageReadStatusV1,
        validPrefixByteCount: UInt64,
        hasher: SHA256
    ) -> SessionPackageReadResultV1 {
        SessionPackageReadResultV1(
            frames: frames,
            status: status,
            validPrefixByteCount: validPrefixByteCount,
            wholeFileDigest: SessionDigestV1(bytes: Data(hasher.finalize()))
        )
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }

    func uint32BigEndian(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }
}
