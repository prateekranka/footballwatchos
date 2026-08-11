import Foundation

/// The sole owner of a Watch session's `.partial` handle. Callers submit
/// already-bounded batches; this actor deliberately never creates one task per
/// sensor sample.
public actor SessionPackageWriter {
    public struct SynchronizationPolicy: Sendable, Equatable {
        public let maximumUnsynchronizedBytes: Int
        public let maximumUnsynchronizedInterval: TimeInterval

        public init(
            maximumUnsynchronizedBytes: Int = 256 * 1024,
            maximumUnsynchronizedInterval: TimeInterval = 10
        ) throws {
            guard maximumUnsynchronizedBytes > 0, maximumUnsynchronizedInterval > 0 else {
                throw SessionPackageError.invalidSynchronizationPolicy
            }
            self.maximumUnsynchronizedBytes = maximumUnsynchronizedBytes
            self.maximumUnsynchronizedInterval = maximumUnsynchronizedInterval
        }

        /// This is a bounded durability policy, not a claim about physical
        /// energy suitability on any particular Watch model.
        public static let `default` = try! SynchronizationPolicy()
    }

    private enum State: Sendable, Equatable {
        case open
        case sealed(URL)
    }

    public let partialURL: URL
    public let sessionID: UUID

    private let fileManager: FileManager
    private let limits: SessionPackageReaderLimitsV1
    private let policy: SynchronizationPolicy
    private var handle: FileHandle?
    private var state: State = .open
    private var unsynchronizedByteCount = 0
    private var lastSynchronizedAt: Date

    public static func start(
        in directory: URL,
        envelope: SessionEnvelopeV1,
        policy: SynchronizationPolicy = .default,
        limits: SessionPackageReaderLimitsV1 = .default
    ) throws -> SessionPackageWriter {
        let partialURL = directory
            .appendingPathComponent(envelope.sessionID.uuidString, isDirectory: false)
            .appendingPathExtension(FootySessionPackageV1.partialFileExtension)
        WatchLog.capture(
            WatchLog.writer,
            "start: creating writer at \(partialURL.lastPathComponent)"
        )
        return try SessionPackageWriter(
            partialURL: partialURL,
            envelope: envelope,
            policy: policy,
            limits: limits
        )
    }

    public init(
        partialURL: URL,
        envelope: SessionEnvelopeV1,
        policy: SynchronizationPolicy = .default,
        limits: SessionPackageReaderLimitsV1 = .default,
        fileManager: FileManager = .default
    ) throws {
        guard partialURL.pathExtension == FootySessionPackageV1.partialFileExtension else {
            throw SessionPackageError.notAPartialPackage
        }
        guard limits.maximumFrameBytes > 0, limits.maximumFrameCount > 0 else {
            throw SessionPackageError.invalidSynchronizationPolicy
        }
        guard !fileManager.fileExists(atPath: partialURL.path) else {
            throw SessionPackageError.destinationAlreadyExists
        }

        self.partialURL = partialURL
        self.sessionID = envelope.sessionID
        self.fileManager = fileManager
        self.limits = limits
        self.policy = policy
        self.lastSynchronizedAt = Date()

        do {
            try fileManager.createDirectory(
                at: partialURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                throw SessionPackageError.destinationAlreadyExists
            }

            let openedHandle = try FileHandle(forWritingTo: partialURL)
            self.handle = openedHandle
            try FootySessionPackageV1.writeHeader(to: openedHandle)
            let bytes = try FootySessionPackageV1.append(
                frame: FootySessionFrameV1(payload: .envelope(envelope)),
                to: openedHandle,
                limits: limits
            )
            unsynchronizedByteCount = FootySessionPackageV1.headerByteCount + bytes
            // No synchronize() here. The bounded policy (below) flushes the
            // first append, and complete() synchronizes before the rename.
            // A blocking fsync during session startup is what let watchOS
            // suspend/kill the app mid-write in the previous builds.
            lastSynchronizedAt = Date()
            WatchLog.capture(
                WatchLog.writer,
                "init: header + envelope written (\(bytes) bytes)"
            )
        } catch {
            // Retain the partial bytes for diagnosis/recovery. The repository
            // decides whether a valid prefix can be recovered later.
            WatchLog.writer.logError("init: writer creation failed", error: error)
            throw error
        }
    }

    public func appendAccelerometerBatch(_ batch: AccelerometerBatchV1) throws {
        try append(.accelerometerBatch(batch))
    }

    public func appendDeviceMotionBatch(_ batch: DeviceMotionBatchV1) throws {
        try append(.deviceMotionBatch(batch))
    }

    public func appendHeartRateSnapshot(_ snapshot: HeartRateSnapshotV1) throws {
        try append(.heartRateSnapshot(snapshot))
    }

    public func appendDistanceSnapshot(_ snapshot: DistanceSnapshotV1) throws {
        try append(.distanceSnapshot(snapshot))
    }

    public func appendCaptureDiagnostics(_ diagnostics: CaptureDiagnosticsV1) throws {
        try append(.captureDiagnostics(diagnostics))
    }

    public func appendQualityEvent(_ event: CaptureQualityEventV1) throws {
        try append(.qualityEvent(event))
    }

    /// Forces the bounded policy's current bytes to disk. This does not make a
    /// battery or performance claim; it only bounds the writer's pending bytes
    /// and elapsed synchronization interval.
    public func synchronizeNow() throws {
        try ensureOpen()
        try synchronize()
    }

    /// Appends a terminal completion frame, synchronizes it, closes the handle,
    /// and renames the package on the same volume from `.partial` to
    /// `.footysession`. No existing sealed package is overwritten.
    @discardableResult
    public func complete(_ completion: SessionCompletionV1) throws -> URL {
        try append(.completion(completion))
        try synchronize()

        guard let handle else { throw SessionPackageError.writerIsSealed }
        try handle.close()
        self.handle = nil

        let sealedURL = partialURL
            .deletingPathExtension()
            .appendingPathExtension(FootySessionPackageV1.fileExtension)
        guard !fileManager.fileExists(atPath: sealedURL.path) else {
            throw SessionPackageError.destinationAlreadyExists
        }
        try fileManager.moveItem(at: partialURL, to: sealedURL)
        state = .sealed(sealedURL)
        return sealedURL
    }

    private func append(_ payload: SessionFramePayloadV1) throws {
        try ensureOpen()
        guard let handle else { throw SessionPackageError.writerIsSealed }

        let bytes = try FootySessionPackageV1.append(
            frame: FootySessionFrameV1(payload: payload),
            to: handle,
            limits: limits
        )
        unsynchronizedByteCount += bytes

        let interval = Date().timeIntervalSince(lastSynchronizedAt)
        if unsynchronizedByteCount >= policy.maximumUnsynchronizedBytes
            || interval >= policy.maximumUnsynchronizedInterval {
            try synchronize()
        }
    }

    private func ensureOpen() throws {
        guard case .open = state else {
            throw SessionPackageError.writerIsSealed
        }
    }

    private func synchronize() throws {
        guard let handle else { throw SessionPackageError.writerIsSealed }
        try handle.synchronize()
        unsynchronizedByteCount = 0
        lastSynchronizedAt = Date()
    }
}
