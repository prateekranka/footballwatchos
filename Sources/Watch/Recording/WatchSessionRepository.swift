import Foundation

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
        guard scan.envelope != nil else {
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
        try FileManager.default.createDirectory(
            at: recoveredURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: recoveredURL.path, contents: nil) else {
            throw SessionPackageError.destinationAlreadyExists
        }

        let completion = SessionCompletionV1(
            endedAt: recoveredAt,
            lifecycle: .interrupted(reason: .partialFileRecovery),
            summary: nil,
            healthKitSaveOutcome: .unavailable(reason: .notAttempted)
        )
        var copiedFrameCount = 0
        do {
            let destination = try FileHandle(forWritingTo: recoveredURL)
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
        } catch {
            // Do not leave a half-written recovery package in discovery.
            try? fileManager.removeItem(at: recoveredURL)
            throw error
        }
        guard copiedFrameCount > 0 else {
            // Scan verified an envelope, so this is unreachable; fail closed.
            try? fileManager.removeItem(at: recoveredURL)
            throw SessionPackageError.missingSessionEnvelope
        }

        try? (recoveredURL as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)

        let startedAt = scan.envelope?.startedAt
        let recordedDuration: TimeInterval? = {
            guard let startedAt, let last = scan.lastRecordedAt else { return nil }
            return max(0, last.timeIntervalSince(startedAt))
        }()

        return RecoveredSessionPackageV1(
            originalFilename: filename,
            recoveredFilename: recoveredURL.lastPathComponent,
            sourceStatus: scan.status,
            recoveredDigest: try FootySessionPackageV1.digest(of: recoveredURL),
            startedAt: startedAt,
            recordedDuration: recordedDuration
        )
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
