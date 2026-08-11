import Foundation

/// A stable identity for a private session package. A receipt must match both
/// components before the Watch can claim that the companion imported it.
struct WatchTransferOutboxKeyV1: Codable, Sendable, Equatable, Hashable {
    let sessionID: UUID
    let packageDigest: SessionDigestV1

    init(sessionID: UUID, packageDigest: SessionDigestV1) {
        self.sessionID = sessionID
        self.packageDigest = packageDigest
    }

    var storageKey: String {
        "\(sessionID.uuidString.lowercased())-\(packageDigest.hexString)"
    }
}

enum WatchTransferOutboxStatusV1: String, Codable, Sendable, Equatable {
    /// The package has been sealed but has not yet been handed to
    /// WatchConnectivity.
    case pending
    /// WatchConnectivity accepted a file transfer. This is delivery work, not
    /// proof that the iPhone imported the package.
    case queued
    /// WatchConnectivity reported successful framework completion. An explicit
    /// receipt is still required before the package is considered imported.
    case waitingForReceipt
    /// A future activation may submit the same immutable package again.
    case retryableFailure
    /// A matching, decoded receipt was durably recorded.
    case imported
}

struct WatchTransferOutboxRecordV1: Codable, Sendable, Equatable {
    let key: WatchTransferOutboxKeyV1
    /// A filename rather than a path keeps file submission constrained to the
    /// outbox's sibling Sessions directory.
    let packageFilename: String
    let byteCount: UInt64
    let createdAt: Date
    var status: WatchTransferOutboxStatusV1
    var attemptCount: Int
    var lastError: String?
    var lastUpdatedAt: Date
    var importedAt: Date?

    init(
        transferEnvelope: SessionTransferEnvelopeV1,
        packageFilename: String,
        now: Date
    ) {
        self.key = WatchTransferOutboxKeyV1(
            sessionID: transferEnvelope.sessionID,
            packageDigest: transferEnvelope.packageDigest
        )
        self.packageFilename = packageFilename
        self.byteCount = transferEnvelope.byteCount
        self.createdAt = transferEnvelope.createdAt
        self.status = .pending
        self.attemptCount = 0
        self.lastError = nil
        self.lastUpdatedAt = now
        self.importedAt = nil
    }
}

/// Kept intentionally small and pure so receipt and transition behavior can
/// be verified without a WatchConnectivity runtime.
struct WatchTransferOutboxStateV1: Codable, Sendable, Equatable {
    static let formatVersion = 1

    let formatVersion: Int
    var records: [String: WatchTransferOutboxRecordV1]

    init(records: [String: WatchTransferOutboxRecordV1] = [:]) {
        self.formatVersion = Self.formatVersion
        self.records = records
    }

    mutating func enqueue(
        transferEnvelope: SessionTransferEnvelopeV1,
        packageFilename: String,
        now: Date
    ) throws -> WatchTransferOutboxRecordV1 {
        try transferEnvelope.validate()
        let key = WatchTransferOutboxKeyV1(
            sessionID: transferEnvelope.sessionID,
            packageDigest: transferEnvelope.packageDigest
        )
        let storageKey = key.storageKey

        if let existing = records[storageKey] {
            // The same immutable digest is idempotent. A filename or byte-count
            // disagreement is not silently repaired because that could point at
            // a different private package.
            guard existing.packageFilename == packageFilename,
                  existing.byteCount == transferEnvelope.byteCount else {
                throw WatchTransferOutboxErrorV1.conflictingPackageIdentity
            }
            return existing
        }

        let record = WatchTransferOutboxRecordV1(
            transferEnvelope: transferEnvelope,
            packageFilename: packageFilename,
            now: now
        )
        records[storageKey] = record
        return record
    }

    mutating func claimRecordsForTransfer(now: Date) -> [WatchTransferOutboxRecordV1] {
        let candidates = records.values
            .filter { $0.status == .pending || $0.status == .retryableFailure }
            .sorted { $0.createdAt < $1.createdAt }

        for candidate in candidates {
            mutate(candidate.key, now: now) { record in
                record.status = .queued
                record.attemptCount += 1
                record.lastError = nil
            }
        }

        return candidates.compactMap { records[$0.key.storageKey] }
    }

    mutating func recordFrameworkCompletion(
        for key: WatchTransferOutboxKeyV1,
        errorDescription: String?,
        now: Date
    ) {
        mutate(key, now: now) { record in
            if let errorDescription {
                record.status = .retryableFailure
                record.lastError = errorDescription
            } else if record.status != .imported {
                record.status = .waitingForReceipt
                // Completion means the framework is done with its transfer. It
                // deliberately does not mean the iPhone has imported data.
                record.lastError = nil
            }
        }
    }

    /// An outstanding transfer is retained as queued. If it disappeared before
    /// this process observed its completion callback, retry on a later
    /// activation rather than fabricating an imported state.
    mutating func reconcileOutstandingTransfers(
        _ outstanding: Set<WatchTransferOutboxKeyV1>,
        now: Date
    ) {
        for key in records.values.map(\.key) {
            guard let record = records[key.storageKey], record.status == .queued else { continue }
            guard !outstanding.contains(key) else { continue }
            mutate(key, now: now) { mutableRecord in
                mutableRecord.status = .retryableFailure
                mutableRecord.lastError = "Framework transfer was no longer outstanding; retry is pending."
            }
        }
    }

    @discardableResult
    mutating func recordReceipt(_ receipt: SyncReceiptV1, now: Date) -> Bool {
        let key = WatchTransferOutboxKeyV1(
            sessionID: receipt.sessionID,
            packageDigest: receipt.packageDigest
        )
        guard records[key.storageKey] != nil else { return false }

        mutate(key, now: now) { record in
            record.status = .imported
            record.lastError = nil
            record.importedAt = receipt.acknowledgedAt
        }
        return true
    }

    func record(for key: WatchTransferOutboxKeyV1) -> WatchTransferOutboxRecordV1? {
        records[key.storageKey]
    }

    private mutating func mutate(
        _ key: WatchTransferOutboxKeyV1,
        now: Date,
        _ body: (inout WatchTransferOutboxRecordV1) -> Void
    ) {
        guard var record = records[key.storageKey] else { return }
        body(&record)
        record.lastUpdatedAt = now
        records[key.storageKey] = record
    }
}

enum WatchTransferOutboxErrorV1: Error, Sendable, Equatable {
    case invalidFilename
    case unsupportedStateFormat(Int)
    case conflictingPackageIdentity
    case packageOutsideSessionsDirectory
}

/// File-backed WatchConnectivity outbox. It retains every private package;
/// its JSON state is an atomic journal of transport facts, not a deletion queue.
actor WatchTransferOutbox {
    let outboxDirectory: URL
    let sessionsDirectory: URL

    private let fileManager: FileManager
    private let stateURL: URL
    private var state: WatchTransferOutboxStateV1

    init(
        outboxDirectory: URL? = nil,
        sessionsDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw CocoaError(.fileNoSuchFile)
        }

        self.outboxDirectory = outboxDirectory ?? applicationSupport
            .appendingPathComponent("FootballCapture", isDirectory: true)
            .appendingPathComponent("Outbox", isDirectory: true)
        self.sessionsDirectory = sessionsDirectory ?? applicationSupport
            .appendingPathComponent("FootballCapture", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
        self.stateURL = self.outboxDirectory.appendingPathComponent("state.json", isDirectory: false)

        try fileManager.createDirectory(at: self.outboxDirectory, withIntermediateDirectories: true)
        try? (self.outboxDirectory as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)

        if fileManager.fileExists(atPath: stateURL.path) {
            let decoded = try JSONDecoder().decode(
                WatchTransferOutboxStateV1.self,
                from: Data(contentsOf: stateURL)
            )
            guard decoded.formatVersion == WatchTransferOutboxStateV1.formatVersion else {
                throw WatchTransferOutboxErrorV1.unsupportedStateFormat(decoded.formatVersion)
            }
            self.state = decoded
        } else {
            self.state = WatchTransferOutboxStateV1()
        }
    }

    func enqueue(sealedPackageAt packageURL: URL, now: Date = Date()) throws -> WatchTransferOutboxRecordV1 {
        let canonicalPackageURL = packageURL.standardizedFileURL
        let canonicalSessionsDirectory = sessionsDirectory.standardizedFileURL
        guard canonicalPackageURL.deletingLastPathComponent() == canonicalSessionsDirectory,
              canonicalPackageURL.pathExtension == FootySessionPackageV1.fileExtension else {
            throw WatchTransferOutboxErrorV1.packageOutsideSessionsDirectory
        }

        let filename = canonicalPackageURL.lastPathComponent
        guard filename == URL(fileURLWithPath: filename).lastPathComponent else {
            throw WatchTransferOutboxErrorV1.invalidFilename
        }
        let inspected = try SessionTransferCodecV1.inspectCompletePackage(
            at: canonicalPackageURL,
            createdAt: now
        )
        let record = try state.enqueue(
            transferEnvelope: inspected.transferEnvelope,
            packageFilename: filename,
            now: now
        )
        try persist()
        return record
    }

    /// Claims only records which are safe to hand to the framework once. The
    /// state is persisted before `transferFile` is called so a crash cannot
    /// cause the same activation to forget that it attempted submission.
    func claimRecordsForTransfer(now: Date = Date()) throws -> [WatchTransferOutboxRecordV1] {
        let records = state.claimRecordsForTransfer(now: now)
        if !records.isEmpty {
            try persist()
        }
        return records
    }

    func packageURL(for record: WatchTransferOutboxRecordV1) -> URL {
        sessionsDirectory.appendingPathComponent(record.packageFilename, isDirectory: false)
    }

    func recordFrameworkCompletion(
        for key: WatchTransferOutboxKeyV1,
        errorDescription: String?,
        now: Date = Date()
    ) throws {
        state.recordFrameworkCompletion(for: key, errorDescription: errorDescription, now: now)
        try persist()
    }

    func reconcileOutstandingTransfers(
        _ outstanding: Set<WatchTransferOutboxKeyV1>,
        now: Date = Date()
    ) throws {
        let before = state
        state.reconcileOutstandingTransfers(outstanding, now: now)
        if state != before {
            try persist()
        }
    }

    @discardableResult
    func recordReceipt(_ receipt: SyncReceiptV1, now: Date = Date()) throws -> Bool {
        let didMatch = state.recordReceipt(receipt, now: now)
        if didMatch {
            try persist()
        }
        return didMatch
    }

    func snapshot() -> WatchTransferOutboxStateV1 {
        state
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }
}
