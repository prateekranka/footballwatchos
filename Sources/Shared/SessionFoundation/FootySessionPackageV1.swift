import CryptoKit
import Foundation

public enum SessionFrameKindV1: String, Codable, Sendable, Equatable {
    case envelope
    case accelerometerBatch
    case deviceMotionBatch
    case heartRateSnapshot
    case distanceSnapshot
    case sprintBatch
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
    case sprintBatch(SprintBatchV1)
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
        case .sprintBatch:
            return .sprintBatch
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

/// The bounded-memory result of a structural scan over a package file. Unlike
/// `SessionPackageReadResultV1` it carries no sensor frames — only the
/// terminal payloads the Watch needs to make recovery/transfer decisions.
public struct SessionPackageScanV1: Sendable, Equatable {
    public let envelope: SessionEnvelopeV1?
    public let completion: SessionCompletionV1?
    public let status: SessionPackageReadStatusV1
    public let frameCount: Int
    public let wholeFileDigest: SessionDigestV1
    /// The latest absolute timestamp recorded in any frame of the package
    /// (snapshot, diagnostics, quality, sprint, or completion frame). Nil when
    /// no dated frame exists beyond the envelope. Recovery uses this to report
    /// a truthful "recorded until" time without fabricating one.
    public let lastRecordedAt: Date?

    public init(
        envelope: SessionEnvelopeV1?,
        completion: SessionCompletionV1?,
        status: SessionPackageReadStatusV1,
        frameCount: Int,
        wholeFileDigest: SessionDigestV1,
        lastRecordedAt: Date? = nil
    ) {
        self.envelope = envelope
        self.completion = completion
        self.status = status
        self.frameCount = frameCount
        self.wholeFileDigest = wholeFileDigest
        self.lastRecordedAt = lastRecordedAt
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
            // `FileHandle.read(upToCount:)` returns an autoreleased Data. Without
            // a per-iteration autorelease pool the chunks from a large package
            // accumulate (one heap region per chunk) until the enclosing pool
            // drains — on a physical Watch that grew resident memory by roughly
            // the whole package size and triggered Jetsam (build 23, 2026-09-01).
            // Draining each iteration keeps whole-file digest memory O(1) in
            // file size; the returned chunk is ARC-held only within this body.
            let chunk = try autoreleasepool {
                try handle.read(upToCount: readChunkSize) ?? Data()
            }
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
        try validateReaderLimits(limits)

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
            guard frameLength(declaredLength, isWithin: limits) else {
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

    /// Bounded-memory structural scan: like `read(from:)` (same header
    /// validation, frame integrity checks, sequence rules, torn-tail and
    /// whole-file digest semantics) but it retains only the envelope and
    /// completion payloads. Sensor frames are decoded one at a time and
    /// dropped, so peak memory is one frame instead of the whole package.
    /// This is what resource-constrained Watch code must use on packages of
    /// unbounded length; `read(from:)` remains for phone-side ingest.
    static func scanStructure(
        of url: URL,
        limits: SessionPackageReaderLimitsV1 = .default
    ) throws -> SessionPackageScanV1 {
        try validateReaderLimits(limits)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var wholeFileHasher = SHA256()
        let header = try readUpTo(headerByteCount, from: handle, hasher: &wholeFileHasher)
        guard header.count == headerByteCount else {
            throw SessionPackageError.truncatedHeader
        }
        try validateHeader(header)

        var envelope: SessionEnvelopeV1?
        var completion: SessionCompletionV1?
        var lastRecordedAt: Date?
        var frameCount = 0
        var sawCompletion = false

        while true {
            switch try scanNextFrame(
                from: handle,
                hasher: &wholeFileHasher,
                index: frameCount,
                sawCompletion: sawCompletion,
                limits: limits
            ) {
            case .end:
                return SessionPackageScanV1(
                    envelope: envelope,
                    completion: completion,
                    status: sawCompletion ? .complete : .incomplete,
                    frameCount: frameCount,
                    wholeFileDigest: SessionDigestV1(bytes: Data(wholeFileHasher.finalize())),
                    lastRecordedAt: lastRecordedAt
                )
            case .torn:
                return SessionPackageScanV1(
                    envelope: envelope,
                    completion: completion,
                    status: .tornTail,
                    frameCount: frameCount,
                    wholeFileDigest: SessionDigestV1(bytes: Data(wholeFileHasher.finalize())),
                    lastRecordedAt: lastRecordedAt
                )
            case let .frame(kind, foundEnvelope, foundCompletion, foundRecordedAt):
                if let foundEnvelope { envelope = foundEnvelope }
                if let foundCompletion { completion = foundCompletion }
                if let foundRecordedAt {
                    if lastRecordedAt == nil || foundRecordedAt > lastRecordedAt! {
                        lastRecordedAt = foundRecordedAt
                    }
                }
                sawCompletion = kind == .completion
                frameCount += 1
            }
        }
    }

    /// Copies verified frames from a source package to an opened, header-less
    /// destination handle one frame at a time, byte-for-byte (no re-encoding),
    /// skipping completion frames. Stops cleanly at a torn tail. Peak memory
    /// is one frame. Returns the number of frames copied.
    static func streamVerifiedFrames(
        from sourceURL: URL,
        to destinationHandle: FileHandle,
        limits: SessionPackageReaderLimitsV1
    ) throws -> Int {
        try validateReaderLimits(limits)

        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }

        var hasher = SHA256()
        let header = try readUpTo(headerByteCount, from: source, hasher: &hasher)
        guard header.count == headerByteCount else {
            throw SessionPackageError.truncatedHeader
        }
        try validateHeader(header)

        var sourceFrameCount = 0
        var copiedFrameCount = 0
        var sawCompletion = false

        while true {
            let copied = try copyNextFrame(
                from: source,
                to: destinationHandle,
                index: sourceFrameCount,
                sawCompletion: sawCompletion,
                limits: limits
            )
            guard let kind = copied else { return copiedFrameCount }
            sawCompletion = kind == .completion
            sourceFrameCount += 1
            if kind != .completion {
                copiedFrameCount += 1
            }
        }
    }

    private enum ScanFrameStep {
        case end
        case torn
        case frame(SessionFrameKindV1, SessionEnvelopeV1?, SessionCompletionV1?, Date?)
    }

    private static func scanNextFrame(
        from source: FileHandle,
        hasher: inout SHA256,
        index: Int,
        sawCompletion: Bool,
        limits: SessionPackageReaderLimitsV1
    ) throws -> ScanFrameStep {
        try autoreleasepool {
            let lengthData = try readUpTo(4, from: source, hasher: &hasher)
            if lengthData.isEmpty { return .end }
            guard lengthData.count == 4 else { return .torn }
            let declaredLength = lengthData.uint32BigEndian(at: 0)
            guard declaredLength > 0 else {
                throw SessionPackageError.invalidFrameLength(declaredLength)
            }
            guard frameLength(declaredLength, isWithin: limits) else {
                throw SessionPackageError.frameTooLarge(declared: declaredLength, limit: limits.maximumFrameBytes)
            }
            guard index < limits.maximumFrameCount else {
                throw SessionPackageError.tooManyFrames(limit: limits.maximumFrameCount)
            }

            let frameData = try readUpTo(Int(declaredLength), from: source, hasher: &hasher)
            guard frameData.count == Int(declaredLength) else { return .torn }
            let integrity = try readUpTo(frameDigestByteCount, from: source, hasher: &hasher)
            guard integrity.count == frameDigestByteCount else { return .torn }
            guard integrity == Data(SHA256.hash(data: frameData)) else {
                throw SessionPackageError.corruptFrameIntegrity(index: index)
            }

            let kind: SessionFrameKindV1
            do {
                kind = try binaryPlistFrameKind(in: frameData)
            } catch {
                throw SessionPackageError.corruptFrame(index: index)
            }
            try validateFrameKind(kind, at: index, sawCompletion: sawCompletion)

            var envelope: SessionEnvelopeV1?
            var completion: SessionCompletionV1?
            var lastRecordedAt: Date?
            if kind == .envelope || kind == .completion {
                do {
                    let frame = try PropertyListDecoder().decode(FootySessionFrameV1.self, from: frameData)
                    switch frame.payload {
                    case let .envelope(value): envelope = value
                    case let .completion(value): completion = value
                    default: throw SessionPackageError.invalidFrameKind
                    }
                } catch let error as SessionPackageError {
                    throw error
                } catch {
                    throw SessionPackageError.corruptFrame(index: index)
                }
            } else if let date = try dateRecordedByKind(kind, frameData: frameData, index: index) {
                lastRecordedAt = date
            }
            return .frame(kind, envelope, completion, lastRecordedAt)
        }
    }

    /// Extracts the absolute timestamp carried by the small, dated frame kinds.
    /// Motion batches are deliberately skipped: their sample timestamps are
    /// seconds since boot, not absolute date values. This keeps the scan
    /// bounded: the date kinds carry only a handful of values per frame, so the
    /// decode cost here is negligible next to the batch frames.
    private static func dateRecordedByKind(
        _ kind: SessionFrameKindV1,
        frameData: Data,
        index: Int
    ) throws -> Date? {
        switch kind {
        case .heartRateSnapshot, .distanceSnapshot, .captureDiagnostics, .qualityEvent, .sprintBatch:
            do {
                let frame = try PropertyListDecoder().decode(FootySessionFrameV1.self, from: frameData)
                switch frame.payload {
                case let .heartRateSnapshot(value): return value.timestamp
                case let .distanceSnapshot(value): return value.timestamp
                case let .captureDiagnostics(value): return value.recordedAt
                case let .qualityEvent(value): return value.timestamp
                case let .sprintBatch(value): return value.recordedAt
                default: return nil
                }
            } catch let error as SessionPackageError {
                throw error
            } catch {
                throw SessionPackageError.corruptFrame(index: index)
            }
        default:
            return nil
        }
    }

    /// Returns nil at clean EOF or a torn tail. All package-sized temporary
    /// Data values live inside one autorelease pool and are drained per frame.
    private static func copyNextFrame(
        from source: FileHandle,
        to destination: FileHandle,
        index: Int,
        sawCompletion: Bool,
        limits: SessionPackageReaderLimitsV1
    ) throws -> SessionFrameKindV1? {
        try autoreleasepool {
            let lengthData = try source.read(upToCount: 4) ?? Data()
            guard lengthData.count == 4 else { return nil }
            let declaredLength = lengthData.uint32BigEndian(at: 0)
            guard declaredLength > 0 else {
                throw SessionPackageError.invalidFrameLength(declaredLength)
            }
            guard frameLength(declaredLength, isWithin: limits) else {
                throw SessionPackageError.frameTooLarge(declared: declaredLength, limit: limits.maximumFrameBytes)
            }
            guard index < limits.maximumFrameCount else {
                throw SessionPackageError.tooManyFrames(limit: limits.maximumFrameCount)
            }

            let frameData = try source.read(upToCount: Int(declaredLength)) ?? Data()
            guard frameData.count == Int(declaredLength) else { return nil }
            let integrity = try source.read(upToCount: frameDigestByteCount) ?? Data()
            guard integrity.count == frameDigestByteCount else { return nil }
            guard integrity == Data(SHA256.hash(data: frameData)) else {
                throw SessionPackageError.corruptFrameIntegrity(index: index)
            }

            let kind: SessionFrameKindV1
            do {
                kind = try binaryPlistFrameKind(in: frameData)
            } catch {
                throw SessionPackageError.corruptFrame(index: index)
            }
            try validateFrameKind(kind, at: index, sawCompletion: sawCompletion)
            if kind != .completion {
                try destination.write(contentsOf: lengthData)
                try destination.write(contentsOf: frameData)
                try destination.write(contentsOf: integrity)
            }
            return kind
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

    /// Reads the top-level `kind` string from the binary property-list object
    /// table without asking Foundation to materialize the payload graph. A
    /// near-limit motion frame can expand to more than 100 MB when decoded into
    /// thousands of sample dictionaries, which exceeds the Watch memory budget.
    private static func binaryPlistFrameKind(in data: Data) throws -> SessionFrameKindV1 {
        guard data.count >= 40,
              data.prefix(8) == Data("bplist00".utf8) else {
            throw SessionPackageError.malformedHeader
        }

        let trailer = data.count - 32
        let offsetWidth = Int(data[trailer + 6])
        let referenceWidth = Int(data[trailer + 7])
        guard (1...8).contains(offsetWidth), (1...8).contains(referenceWidth),
              let objectCount = Int(exactly: try readUnsigned(data, at: trailer + 8, width: 8)),
              let topObject = Int(exactly: try readUnsigned(data, at: trailer + 16, width: 8)),
              let offsetTable = Int(exactly: try readUnsigned(data, at: trailer + 24, width: 8)),
              objectCount > 0, topObject < objectCount,
              offsetTable >= 8,
              offsetTable <= trailer,
              objectCount <= (trailer - offsetTable) / offsetWidth else {
            throw SessionPackageError.malformedHeader
        }

        func objectOffset(_ reference: Int) throws -> Int {
            guard reference >= 0, reference < objectCount else {
                throw SessionPackageError.malformedHeader
            }
            let tableIndex = offsetTable + reference * offsetWidth
            guard let offset = Int(exactly: try readUnsigned(data, at: tableIndex, width: offsetWidth)),
                  offset >= 8, offset < offsetTable else {
                throw SessionPackageError.malformedHeader
            }
            return offset
        }

        func objectLength(at offset: Int) throws -> (count: Int, headerBytes: Int) {
            let marker = data[offset]
            let inline = Int(marker & 0x0F)
            guard inline == 0x0F else { return (inline, 1) }
            let integerOffset = offset + 1
            guard integerOffset < offsetTable else { throw SessionPackageError.malformedHeader }
            let integerMarker = data[integerOffset]
            guard integerMarker >> 4 == 0x1 else { throw SessionPackageError.malformedHeader }
            let widthShift = Int(integerMarker & 0x0F)
            guard widthShift < 4 else { throw SessionPackageError.malformedHeader }
            let width = 1 << widthShift
            guard let count = Int(exactly: try readUnsigned(data, at: integerOffset + 1, width: width)) else {
                throw SessionPackageError.malformedHeader
            }
            return (count, 2 + width)
        }

        func string(for reference: Int) throws -> String {
            let offset = try objectOffset(reference)
            let marker = data[offset]
            let type = marker >> 4
            let length = try objectLength(at: offset)
            let contentOffset = offset + length.headerBytes
            switch type {
            case 0x5:
                guard length.count <= offsetTable - contentOffset else {
                    throw SessionPackageError.malformedHeader
                }
                return String(decoding: data[contentOffset..<(contentOffset + length.count)], as: UTF8.self)
            case 0x6:
                let byteCount = length.count.multipliedReportingOverflow(by: 2)
                guard !byteCount.overflow, byteCount.partialValue <= offsetTable - contentOffset else {
                    throw SessionPackageError.malformedHeader
                }
                let bytes = data[contentOffset..<(contentOffset + byteCount.partialValue)]
                var codeUnits: [UInt16] = []
                codeUnits.reserveCapacity(length.count)
                var index = bytes.startIndex
                while index < bytes.endIndex {
                    let next = bytes.index(after: index)
                    codeUnits.append(UInt16(bytes[index]) << 8 | UInt16(bytes[next]))
                    index = bytes.index(next, offsetBy: 1)
                }
                return String(decoding: codeUnits, as: UTF16.self)
            default:
                throw SessionPackageError.malformedHeader
            }
        }

        let dictionaryOffset = try objectOffset(topObject)
        guard data[dictionaryOffset] >> 4 == 0xD else {
            throw SessionPackageError.malformedHeader
        }
        let dictionaryLength = try objectLength(at: dictionaryOffset)
        let referencesOffset = dictionaryOffset + dictionaryLength.headerBytes
        let referencesByteCount = dictionaryLength.count
            .multipliedReportingOverflow(by: referenceWidth * 2)
        guard !referencesByteCount.overflow,
              referencesByteCount.partialValue <= offsetTable - referencesOffset else {
            throw SessionPackageError.malformedHeader
        }

        for index in 0..<dictionaryLength.count {
            let keyReference = try readUnsigned(
                data,
                at: referencesOffset + index * referenceWidth,
                width: referenceWidth
            )
            guard let keyReference = Int(exactly: keyReference) else {
                throw SessionPackageError.malformedHeader
            }
            guard try string(for: keyReference) == "kind" else { continue }

            let valueReferencesOffset = referencesOffset + dictionaryLength.count * referenceWidth
            let valueReference = try readUnsigned(
                data,
                at: valueReferencesOffset + index * referenceWidth,
                width: referenceWidth
            )
            guard let valueReference = Int(exactly: valueReference),
                  let kind = SessionFrameKindV1(rawValue: try string(for: valueReference)) else {
                throw SessionPackageError.invalidFrameKind
            }
            return kind
        }
        throw SessionPackageError.invalidFrameKind
    }

    private static func readUnsigned(_ data: Data, at offset: Int, width: Int) throws -> UInt64 {
        guard (1...8).contains(width), offset >= 0, offset <= data.count - width else {
            throw SessionPackageError.malformedHeader
        }
        var value: UInt64 = 0
        for byte in data[offset..<(offset + width)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private static func validateReaderLimits(_ limits: SessionPackageReaderLimitsV1) throws {
        guard limits.maximumFrameBytes > 0, limits.maximumFrameCount > 0 else {
            throw SessionPackageError.invalidSynchronizationPolicy
        }
    }

    private static func frameLength(
        _ declaredLength: UInt32,
        isWithin limits: SessionPackageReaderLimitsV1
    ) -> Bool {
        UInt64(declaredLength) <= UInt64(limits.maximumFrameBytes)
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
        try validateFrameKind(frame.kind, at: index, sawCompletion: sawCompletion)
    }

    private static func validateFrameKind(
        _ kind: SessionFrameKindV1,
        at index: Int,
        sawCompletion: Bool
    ) throws {
        guard !sawCompletion else {
            throw SessionPackageError.invalidFrameSequence(index: index)
        }
        if index == 0, kind != .envelope {
            throw SessionPackageError.missingSessionEnvelope
        }
        if index > 0, kind == .envelope {
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
