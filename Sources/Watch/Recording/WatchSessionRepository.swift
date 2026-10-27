import Foundation

public struct ActiveRecordingMarkerV1: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let partialFilename: String
    public let startedAt: Date
    public let sessionType: FootballSessionTypeV1
    public let motionPlanSource: MotionCaptureSourceV1

    init(envelope: SessionEnvelopeV1) {
        sessionID = envelope.sessionID
        partialFilename = "\(envelope.sessionID.uuidString).\(FootySessionPackageV1.partialFileExtension)"
        startedAt = envelope.startedAt
        sessionType = envelope.footballType
        motionPlanSource = envelope.captureSource
    }
}

public enum StoredSessionPackageKindV1: String, Codable, Sendable, Equatable {
    case sealed
    case partial
}

public struct StoredSessionPackageV1: Sendable, Equatable {
    /// A filename, not an arbitrary URL, keeps recovery constrained to the
    /// repository's Application Support directory.
    public let filename: String
    public let kind: StoredSessionPackageKindV1
    public let byteCount: UInt64

    public init(filename: String, kind: StoredSessionPackageKindV1, byteCount: UInt64) {
        self.filename = filename
        self.kind = kind
        self.byteCount = byteCount
    }
}

public struct RecoveredSessionPackageV1: Sendable, Equatable {
    public let originalFilename: String
    public let recoveredFilename: String
    public let sourceStatus: SessionPackageReadStatusV1
    public let recoveredDigest: SessionDigestV1
    /// Session start from the recovered envelope. Nil only when the envelope
    /// could not be read (recovery fails before that point).
    public let startedAt: Date?
    /// Recorded span: latest dated frame minus `startedAt`. Nil when the
    /// package has no dated frames, or no envelope start.
    public let recordedDuration: TimeInterval?

    public init(
        originalFilename: String,
        recoveredFilename: String,
        sourceStatus: SessionPackageReadStatusV1,
        recoveredDigest: SessionDigestV1,
        startedAt: Date? = nil,
        recordedDuration: TimeInterval? = nil
    ) {
        self.originalFilename = originalFilename
        self.recoveredFilename = recoveredFilename
        self.sourceStatus = sourceStatus
        self.recoveredDigest = recoveredDigest
        self.startedAt = startedAt
        self.recordedDuration = recordedDuration
    }
}

/// Display identity for one session file: what a human needs to tell one
/// session from another. Never the opaque package filename.
public struct SessionPackageMetadataV1: Sendable, Equatable {
    public let sessionID: UUID?
    public let startedAt: Date?
    /// HealthKit summary duration when present; otherwise the recorded span
    /// from the latest dated frame; otherwise nil.
    public let duration: TimeInterval?

    public init(
        sessionID: UUID? = nil,
        startedAt: Date? = nil,
        duration: TimeInterval? = nil
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.duration = duration
    }
}

/// Owns `Application Support/FootballCapture/Sessions`. It never deletes or
/// overwrites a package: recovery validates a partial package, leaves its bytes
/// intact, and writes a new interrupted package from verified frames only.
public actor WatchSessionRepository {
    public let sessionsDirectory: URL

    private var activeRecordingURL: URL {
        sessionsDirectory.deletingLastPathComponent().appendingPathComponent("ActiveRecording.json")
    }

    private let fileManager: FileManager
    private let limits: SessionPackageReaderLimitsV1

    public init(
        sessionsDirectory: URL? = nil,
        limits: SessionPackageReaderLimitsV1 = .default,
        fileManager: FileManager = .default
    ) throws {
        guard limits.maximumFrameBytes > 0, limits.maximumFrameCount > 0 else {
            throw SessionPackageError.invalidSynchronizationPolicy
        }
        self.fileManager = fileManager
        self.limits = limits

        if let sessionsDirectory {
            self.sessionsDirectory = sessionsDirectory
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            self.sessionsDirectory = applicationSupport
                .appendingPathComponent("FootballCapture", isDirectory: true)
                .appendingPathComponent("Sessions", isDirectory: true)
        }

        try fileManager.createDirectory(
            at: self.sessionsDirectory,
            withIntermediateDirectories: true
        )
        try? (self.sessionsDirectory as NSURL).setResourceValue(
            true,
            forKey: .isExcludedFromBackupKey
        )
    }

    public func discover() throws -> [StoredSessionPackageV1] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        let urls = try fileManager.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )

        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { return nil }

            let kind: StoredSessionPackageKindV1
            switch url.pathExtension {
            case FootySessionPackageV1.fileExtension:
                kind = .sealed
            case FootySessionPackageV1.partialFileExtension:
                kind = .partial
            default:
                return nil
            }
            return StoredSessionPackageV1(
                filename: url.lastPathComponent,
                kind: kind,
                byteCount: UInt64(values.fileSize ?? 0)
            )
        }
        .sorted { $0.filename < $1.filename }
    }

    public func startWriter(
        envelope: SessionEnvelopeV1,
        policy: SessionPackageWriter.SynchronizationPolicy = .default
    ) throws -> SessionPackageWriter {
        do {
            let writer = try SessionPackageWriter.start(
                in: sessionsDirectory,
                envelope: envelope,
                policy: policy,
                limits: limits
            )
            try writeActiveRecording(ActiveRecordingMarkerV1(envelope: envelope))
            WatchLog.repository.info(
                "startWriter: created \(writer.partialURL.lastPathComponent, privacy: .public)"
            )
            WatchLog.capture(
                WatchLog.repository,
                "startWriter: created \(writer.partialURL.lastPathComponent)"
            )
            return writer
        } catch {
            WatchLog.repository.logError("startWriter failed", error: error)
            throw error
        }
    }

    public func activeRecording() throws -> ActiveRecordingMarkerV1? {
        guard fileManager.fileExists(atPath: activeRecordingURL.path) else { return nil }
        let marker = try JSONDecoder().decode(
            ActiveRecordingMarkerV1.self,
            from: Data(contentsOf: activeRecordingURL)
        )
        guard marker.partialFilename == "\(marker.sessionID.uuidString).\(FootySessionPackageV1.partialFileExtension)" else {
            throw SessionPackageError.sessionIdentityMismatch
        }
        return marker
    }

    public func writeActiveRecording(_ marker: ActiveRecordingMarkerV1) throws {
        try JSONEncoder().encode(marker).write(to: activeRecordingURL, options: .atomic)
    }

    public func clearActiveRecording(sessionID: UUID? = nil) throws {
        guard fileManager.fileExists(atPath: activeRecordingURL.path) else { return }
        if let sessionID, try activeRecording()?.sessionID != sessionID { return }
        try fileManager.removeItem(at: activeRecordingURL)
    }

    public func resumeWriter(sessionID: UUID) throws -> SessionPackageWriter {
        try SessionPackageWriter.resume(
            partialURL: partialURL(named: "\(sessionID.uuidString).\(FootySessionPackageV1.partialFileExtension)"),
            sessionID: sessionID,
            limits: limits
        )
    }

    public func completeWriter(
        _ writer: SessionPackageWriter,
        completion: SessionCompletionV1
    ) async throws -> URL {
        let sealedURL = try await writer.complete(completion)
        do {
            try clearActiveRecording(sessionID: writer.sessionID)
        } catch {
            WatchLog.repository.logError("completeWriter: marker removal failed", error: error)
        }
        return sealedURL
    }

    /// Creates a newly named `.footysession` recovery package. The original
    /// `.partial` file remains byte-for-byte untouched, including any torn tail.
    ///
    /// Bounded memory: frames are streamed one at a time from the original
    /// (byte-identical, no re-encoding) instead of decoding the whole package
    /// into an array — a long session's full decode trips watchOS jetsam.
    public func recoverPartial(named filename: String, recoveredAt: Date = Date()) throws -> RecoveredSessionPackageV1 {
        let originalURL = try partialURL(named: filename)
        guard fileManager.fileExists(atPath: originalURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let scan = try FootySessionPackageV1.scanStructure(of: originalURL, limits: limits)
        guard let envelope = scan.envelope else {
            throw SessionPackageError.missingSessionEnvelope
        }

        // A recovery always records interruption, even if the completed bytes
        // were written before a crash prevented the final rename (a `.partial`
        // can contain a synced completion frame). This avoids fabricating a
        // completed session from a `.partial` file.
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let recoveredURL = sessionsDirectory
            .appendingPathComponent("\(stem).recovered.\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension(FootySessionPackageV1.fileExtension)
        let temporaryURL = recoveredURL.appendingPathExtension("tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try FileManager.default.createDirectory(
            at: recoveredURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw SessionPackageError.destinationAlreadyExists
        }

        let completion = SessionCompletionV1(
            endedAt: scan.lastRecordedAt ?? envelope.startedAt,
            lifecycle: .interrupted(reason: .partialFileRecovery),
            summary: nil,
            healthKitSaveOutcome: .unavailable(reason: .notAttempted)
        )
        let copiedFrameCount: Int
        let destination = try FileHandle(forWritingTo: temporaryURL)
        do {
            try FootySessionPackageV1.writeHeader(to: destination)
            copiedFrameCount = try FootySessionPackageV1.streamVerifiedFrames(
                from: originalURL,
                to: destination,
                limits: limits
            )
            _ = try FootySessionPackageV1.append(
                frame: FootySessionFrameV1(payload: .completion(completion)),
                to: destination,
                limits: limits
            )
            try destination.synchronize()
            try destination.close()
        } catch {
            try? destination.close()
            throw error
        }
        guard copiedFrameCount > 0 else {
            // Scan verified an envelope, so this is unreachable; fail closed.
            throw SessionPackageError.missingSessionEnvelope
        }
        let recoveredScan = try FootySessionPackageV1.scanStructure(of: temporaryURL, limits: limits)
        guard recoveredScan.status == .complete else { throw SessionPackageError.missingSessionEnvelope }
        try fileManager.moveItem(at: temporaryURL, to: recoveredURL)

        try? (recoveredURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        // The recovered copy is already durable; a stale marker only costs one
        // no-op HealthKit recovery attempt on the next launch.
        try? clearActiveRecording(sessionID: envelope.sessionID)

        let startedAt = scan.envelope?.startedAt
        let recordedDuration: TimeInterval? = {
            guard let startedAt, let last = scan.lastRecordedAt else { return nil }
            return max(0, last.timeIntervalSince(startedAt))
        }()

        return RecoveredSessionPackageV1(
            originalFilename: filename,
            recoveredFilename: recoveredURL.lastPathComponent,
            sourceStatus: scan.status,
            recoveredDigest: recoveredScan.wholeFileDigest,
            startedAt: startedAt,
            recordedDuration: recordedDuration
        )
    }

    func validatedRecoveredFilename(
        forPartialNamed filename: String,
        discovered: [StoredSessionPackageV1]
    ) throws -> String? {
        let source = try FootySessionPackageV1.scanStructure(of: partialURL(named: filename), limits: limits)
        guard let sessionID = source.envelope?.sessionID else { return nil }
        let stem = (filename as NSString).deletingPathExtension
        for package in discovered where package.kind == .sealed
            && package.filename.hasPrefix("\(stem).recovered.") {
            let url = sessionsDirectory.appendingPathComponent(package.filename)
            guard let scan = try? FootySessionPackageV1.scanStructure(of: url, limits: limits),
                  scan.status == .complete,
                  scan.envelope?.sessionID == sessionID,
                  scan.completion?.lifecycle == .interrupted(reason: .partialFileRecovery) else { continue }
            return package.filename
        }
        return nil
    }

    /// Read-only display metadata for any package file in the sessions
    /// directory. Bounded memory: uses the structural scan, never materializes
    /// sensor frames. Used to label queued sessions with their start time and
    /// duration instead of the opaque filename.
    public func sessionMetadata(named filename: String) throws -> SessionPackageMetadataV1 {
        let url = sessionsDirectory.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let scan = try FootySessionPackageV1.scanStructure(of: url, limits: limits)
        let startedAt = scan.envelope?.startedAt
        let duration: TimeInterval?
        if let summaryDuration = scan.completion?.summary?.duration?.value {
            duration = summaryDuration
        } else if let startedAt, let last = scan.lastRecordedAt {
            duration = max(0, last.timeIntervalSince(startedAt))
        } else {
            duration = nil
        }
        return SessionPackageMetadataV1(
            sessionID: scan.envelope?.sessionID,
            startedAt: startedAt,
            duration: duration
        )
    }

    /// Moves an unrecoverable `.partial` file into a private quarantine folder
    /// without deleting or changing its bytes. This prevents the same orphan
    /// from blocking recovery on every Watch launch.
    public func quarantinePartial(named filename: String) throws -> String {
        let originalURL = try partialURL(named: filename)
        guard fileManager.fileExists(atPath: originalURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let quarantineDirectory = sessionsDirectory.appendingPathComponent("Quarantine", isDirectory: true)
        try fileManager.createDirectory(
            at: quarantineDirectory,
            withIntermediateDirectories: true
        )
        try? (quarantineDirectory as NSURL).setResourceValue(
            true,
            forKey: .isExcludedFromBackupKey
        )

        var destinationURL = quarantineDirectory.appendingPathComponent(
            originalURL.lastPathComponent,
            isDirectory: false
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            destinationURL = quarantineDirectory.appendingPathComponent(
                "\(originalURL.deletingPathExtension().lastPathComponent).\(UUID().uuidString).\(FootySessionPackageV1.partialFileExtension)",
                isDirectory: false
            )
        }
        try fileManager.moveItem(at: originalURL, to: destinationURL)
        if try activeRecording()?.partialFilename == filename {
            try clearActiveRecording()
        }
        return destinationURL.lastPathComponent
    }

    private func partialURL(named filename: String) throws -> URL {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix("." + FootySessionPackageV1.partialFileExtension) else {
            throw SessionPackageError.notAPartialPackage
        }
        return sessionsDirectory.appendingPathComponent(filename, isDirectory: false)
    }
}
