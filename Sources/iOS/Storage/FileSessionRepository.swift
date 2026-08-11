import Foundation

/// A durable, local-only iPhone library of packages received from the Watch.
///
/// The repository never treats a WatchConnectivity callback as import proof. A
/// package is acknowledged only after its bytes, index entry, and receipt have
/// all been written successfully on this device.
public actor FileSessionRepository {
    public struct Configuration: Sendable, Equatable {
        public let rootDirectory: URL

        public init(rootDirectory: URL) {
            self.rootDirectory = rootDirectory
        }

        public static func applicationSupport(fileManager: FileManager = .default) throws -> Configuration {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            return Configuration(
                rootDirectory: applicationSupport
                    .appendingPathComponent("FootballPerformance", isDirectory: true)
            )
        }
    }

    public enum RepositoryError: Error, Sendable, Equatable {
        case sessionNotFound
        case exportIntegrityFailure
        case invalidDeliveryID
    }

    public struct SessionRecord: Codable, Sendable, Equatable, Identifiable {
        public let sessionID: UUID
        public let packageDigest: SessionDigestV1
        public let byteCount: UInt64
        public let transferEnvelope: SessionTransferEnvelopeV1
        public let sessionEnvelope: SessionEnvelopeV1
        public let completion: SessionCompletionV1

        public var id: UUID { sessionID }
        public var startedAt: Date { sessionEnvelope.startedAt }

        public init(
            transferEnvelope: SessionTransferEnvelopeV1,
            sessionEnvelope: SessionEnvelopeV1,
            completion: SessionCompletionV1
        ) {
            self.sessionID = sessionEnvelope.sessionID
            self.packageDigest = transferEnvelope.packageDigest
            self.byteCount = transferEnvelope.byteCount
            self.transferEnvelope = transferEnvelope
            self.sessionEnvelope = sessionEnvelope
            self.completion = completion
        }
    }

    public struct ChartPoint: Identifiable, Sendable, Equatable {
        public let id: String
        public let timestamp: Date
        public let value: Double

        public init(id: String, timestamp: Date, value: Double) {
            self.id = id
            self.timestamp = timestamp
            self.value = value
        }
    }

    public struct SessionDetail: Sendable, Equatable {
        public let record: SessionRecord
        public let heartRateSnapshots: [ChartPoint]
        public let distanceSnapshots: [ChartPoint]
        public let diagnostics: [CaptureDiagnosticsV1]

        public init(
            record: SessionRecord,
            heartRateSnapshots: [ChartPoint],
            distanceSnapshots: [ChartPoint],
            diagnostics: [CaptureDiagnosticsV1]
        ) {
            self.record = record
            self.heartRateSnapshots = heartRateSnapshots
            self.distanceSnapshots = distanceSnapshots
            self.diagnostics = diagnostics
        }
    }

    public enum ImportOutcome: Sendable, Equatable {
        case imported(record: SessionRecord, receiptPayload: Data)
        case duplicate(record: SessionRecord, receiptPayload: Data)
        case quarantined(deliveryID: String, reason: String)
        case suppressedByTombstone(deliveryID: String)
        case alreadyHandled(deliveryID: String)

        public var receiptPayload: Data? {
            switch self {
            case let .imported(_, receiptPayload), let .duplicate(_, receiptPayload):
                return receiptPayload
            case .quarantined, .suppressedByTombstone, .alreadyHandled:
                return nil
            }
        }
    }

    private struct Index: Codable, Sendable {
        let schemaVersion: Int
        let entries: [SessionRecord]
    }

    private struct Tombstone: Codable, Sendable, Equatable {
        let sessionID: UUID
        let packageDigest: SessionDigestV1
        let deletedAt: Date
    }

    private struct TombstoneStore: Codable, Sendable {
        let schemaVersion: Int
        let entries: [Tombstone]
    }

    private struct IncomingManifest: Codable, Sendable {
        let deliveryID: String
        let receivedAt: Date
        let hasEnvelopeMetadata: Bool
    }

    private struct IncomingImportMarker: Codable, Sendable {
        let result: String
        let sessionID: UUID?
        let packageDigest: SessionDigestV1?
        let handledAt: Date
    }

    private let fileManager: FileManager
    public let rootDirectory: URL
    public let incomingDirectory: URL
    public let packagesDirectory: URL
    public let quarantineDirectory: URL
    public let receiptsDirectory: URL

    private let indexURL: URL
    private let tombstonesURL: URL
    private var index: Index
    private var tombstones: TombstoneStore

    public init(
        configuration: Configuration? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        let chosenConfiguration = try configuration ?? Configuration.applicationSupport(fileManager: fileManager)
        self.rootDirectory = chosenConfiguration.rootDirectory
        self.incomingDirectory = rootDirectory.appendingPathComponent("Incoming", isDirectory: true)
        self.packagesDirectory = rootDirectory.appendingPathComponent("Packages", isDirectory: true)
        self.quarantineDirectory = rootDirectory.appendingPathComponent("Quarantine", isDirectory: true)
        self.receiptsDirectory = rootDirectory.appendingPathComponent("Receipts", isDirectory: true)
        self.indexURL = rootDirectory.appendingPathComponent("index.json", isDirectory: false)
        self.tombstonesURL = rootDirectory.appendingPathComponent("tombstones.json", isDirectory: false)
        self.index = Index(schemaVersion: 1, entries: [])
        self.tombstones = TombstoneStore(schemaVersion: 1, entries: [])

        for directory in [rootDirectory, incomingDirectory, packagesDirectory, quarantineDirectory, receiptsDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? (rootDirectory as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        if fileManager.fileExists(atPath: tombstonesURL.path) {
            let loaded = try JSONDecoder().decode(TombstoneStore.self, from: Data(contentsOf: tombstonesURL))
            guard loaded.schemaVersion == 1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.tombstones = loaded
        }
    }

    /// Moves the temporary WatchConnectivity URL before its delegate callback
    /// returns. This synchronous boundary intentionally accepts only Foundation
    /// values, never a `WCSessionFile` object.
    @discardableResult
    public static func stageReceivedFileSynchronously(
        from temporaryURL: URL,
        envelopeData: Data?,
        deliveryID: String = UUID().uuidString.lowercased(),
        configuration: Configuration? = nil,
        fileManager: FileManager = .default,
        receivedAt: Date = Date()
    ) throws -> String {
        guard deliveryID == URL(fileURLWithPath: deliveryID).lastPathComponent,
              !deliveryID.isEmpty else {
            throw RepositoryError.invalidDeliveryID
        }

        let chosenConfiguration = try configuration ?? Configuration.applicationSupport(fileManager: fileManager)
        let incomingDirectory = chosenConfiguration.rootDirectory
            .appendingPathComponent("Incoming", isDirectory: true)
        let deliveryDirectory = incomingDirectory.appendingPathComponent(deliveryID, isDirectory: true)
        let packageURL = deliveryDirectory.appendingPathComponent(
            "package.\(FootySessionPackageV1.fileExtension)",
            isDirectory: false
        )

        try fileManager.createDirectory(at: deliveryDirectory, withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: packageURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }

        // `moveItem` is deliberately used instead of deferring work to an
        // actor. WatchConnectivity owns the source URL only for this callback.
        try fileManager.moveItem(at: temporaryURL, to: packageURL)

        try writeDataAtomically(
            envelopeData ?? Data(),
            to: deliveryDirectory.appendingPathComponent("transfer-envelope.plist", isDirectory: false)
        )
        let manifest = IncomingManifest(
            deliveryID: deliveryID,
            receivedAt: receivedAt,
            hasEnvelopeMetadata: envelopeData != nil
        )
        try writePropertyListAtomically(
            manifest,
            to: deliveryDirectory.appendingPathComponent("manifest.plist", isDirectory: false)
        )
        return deliveryID
    }

    public func sessions() -> [SessionRecord] {
        sorted(index.entries)
    }

    /// Rebuilds the index, recovers an interrupted promote, and processes
    /// retained incoming staging directories. Call once as the application
    /// starts, before presenting the library as current.
    public func reconcileOnStartup() throws {
        tombstones = try loadTombstones()
        try rebuildIndexFromPackages()
        try reconcileIncomingStaging()
    }

    public func detail(for sessionID: UUID) throws -> SessionDetail {
        guard let record = index.entries.first(where: { $0.sessionID == sessionID }) else {
            throw RepositoryError.sessionNotFound
        }

        let packageURL = packageURL(for: record)
        let inspected = try SessionTransferCodecV1.inspectCompletePackage(at: packageURL)
        guard inspected.transferEnvelope.packageDigest == record.packageDigest,
              inspected.transferEnvelope.byteCount == record.byteCount else {
            throw RepositoryError.exportIntegrityFailure
        }

        let read = try FootySessionPackageV1.read(from: packageURL)
        var heartRateSnapshots: [ChartPoint] = []
        var distanceSnapshots: [ChartPoint] = []
        var diagnostics: [CaptureDiagnosticsV1] = []

        for (offset, frame) in read.frames.enumerated() {
            switch frame.payload {
            case let .heartRateSnapshot(snapshot):
                heartRateSnapshots.append(
                    ChartPoint(
                        id: "heart-rate-\(offset)-\(snapshot.timestamp.timeIntervalSinceReferenceDate)",
                        timestamp: snapshot.timestamp,
                        value: snapshot.beatsPerMinute.value
                    )
                )
            case let .distanceSnapshot(snapshot):
                distanceSnapshots.append(
                    ChartPoint(
                        id: "distance-\(offset)-\(snapshot.timestamp.timeIntervalSinceReferenceDate)",
                        timestamp: snapshot.timestamp,
                        value: snapshot.meters.value
                    )
                )
            case let .captureDiagnostics(diagnostic):
                diagnostics.append(diagnostic)
            default:
                break
            }
        }

        return SessionDetail(
            record: record,
            heartRateSnapshots: heartRateSnapshots,
            distanceSnapshots: distanceSnapshots,
            diagnostics: diagnostics
        )
    }

    /// Returns the stored package URL only after recalculating its digest. A
    /// `ShareLink` can share this URL directly, so no transformed export bytes
    /// are ever generated by the iPhone.
    public func verifiedExportURL(for sessionID: UUID) throws -> URL {
        guard let record = index.entries.first(where: { $0.sessionID == sessionID }) else {
            throw RepositoryError.sessionNotFound
        }
        let url = packageURL(for: record)
        let digest = try FootySessionPackageV1.digest(of: url)
        guard digest == record.packageDigest else {
            throw RepositoryError.exportIntegrityFailure
        }
        return url
    }

    /// Persists the deletion tombstone before removing this device's package
    /// and index entry. It intentionally has no HealthKit or WatchConnectivity
    /// side effects.
    @discardableResult
    public func deleteIPhoneCopy(for sessionID: UUID, deletedAt: Date = Date()) throws -> SessionRecord {
        guard let record = index.entries.first(where: { $0.sessionID == sessionID }) else {
            throw RepositoryError.sessionNotFound
        }

        if !tombstones.entries.contains(where: {
            $0.sessionID == record.sessionID && $0.packageDigest == record.packageDigest
        }) {
            tombstones = TombstoneStore(
                schemaVersion: 1,
                entries: tombstones.entries + [
                    Tombstone(
                        sessionID: record.sessionID,
                        packageDigest: record.packageDigest,
                        deletedAt: deletedAt
                    )
                ]
            )
            try writeJSONAtomically(tombstones, to: tombstonesURL)
        }

        let packageURL = packageURL(for: record)
        if fileManager.fileExists(atPath: packageURL.path) {
            try fileManager.removeItem(at: packageURL)
        }
        let metadataURL = storedMetadataURL(for: packageURL)
        if fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.removeItem(at: metadataURL)
        }
        let receiptDirectory = receiptsDirectory.appendingPathComponent(
            record.sessionID.uuidString.lowercased(),
            isDirectory: true
        )
        if fileManager.fileExists(atPath: receiptDirectory.path) {
            try fileManager.removeItem(at: receiptDirectory)
        }

        index = Index(
            schemaVersion: 1,
            entries: index.entries.filter { $0.sessionID != sessionID }
        )
        try writeJSONAtomically(index, to: indexURL)
        return record
    }

    /// Imports one staged delivery. Invalid, incomplete, unknown, conflicting,
    /// or tombstoned deliveries are preserved in quarantine with a reason.
    public func importStaged(deliveryID: String) -> ImportOutcome {
        guard deliveryID == URL(fileURLWithPath: deliveryID).lastPathComponent,
              !deliveryID.isEmpty else {
            return .quarantined(deliveryID: deliveryID, reason: "Invalid delivery identifier")
        }

        let deliveryDirectory = incomingDirectory.appendingPathComponent(deliveryID, isDirectory: true)
        let markerURL = deliveryDirectory.appendingPathComponent("import-marker.plist", isDirectory: false)
        if fileManager.fileExists(atPath: markerURL.path) {
            return .alreadyHandled(deliveryID: deliveryID)
        }

        do {
            let metadataData = try Data(contentsOf: deliveryDirectory.appendingPathComponent("transfer-envelope.plist"))
            let manifest = try PropertyListDecoder().decode(
                IncomingManifest.self,
                from: Data(contentsOf: deliveryDirectory.appendingPathComponent("manifest.plist"))
            )
            guard manifest.deliveryID == deliveryID, manifest.hasEnvelopeMetadata else {
                return quarantine(deliveryID: deliveryID, reason: "Missing transfer-envelope metadata")
            }
            let metadata = try SessionTransferCodecV1.decodeTransferEnvelope(metadataData)
            let sourceURL = deliveryDirectory.appendingPathComponent(
                "package.\(FootySessionPackageV1.fileExtension)",
                isDirectory: false
            )
            let inspected = try SessionTransferCodecV1.validate(packageAt: sourceURL, matches: metadata)

            if tombstones.entries.contains(where: {
                $0.sessionID == metadata.sessionID && $0.packageDigest == metadata.packageDigest
            }) {
                try writeImportMarker(
                    .init(result: "suppressed-by-tombstone", sessionID: metadata.sessionID, packageDigest: metadata.packageDigest, handledAt: Date()),
                    in: deliveryDirectory
                )
                _ = quarantine(deliveryID: deliveryID, reason: "Suppressed by an iPhone deletion tombstone")
                return .suppressedByTombstone(deliveryID: deliveryID)
            }

            if let existing = index.entries.first(where: { $0.sessionID == metadata.sessionID }) {
                guard existing.packageDigest == metadata.packageDigest else {
                    return quarantine(
                        deliveryID: deliveryID,
                        reason: "Session identifier already exists with a different package digest"
                    )
                }
                let receiptPayload = try persistReceipt(for: existing)
                try writeImportMarker(
                    .init(result: "duplicate", sessionID: existing.sessionID, packageDigest: existing.packageDigest, handledAt: Date()),
                    in: deliveryDirectory
                )
                return .duplicate(record: existing, receiptPayload: receiptPayload)
            }

            let targetURL = packageURL(sessionID: metadata.sessionID, digest: metadata.packageDigest)
            let targetDirectory = targetURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

            let record: SessionRecord
            if fileManager.fileExists(atPath: targetURL.path) {
                // A crash can happen after the package move and before index
                // persistence. The existing bytes must validate before they are
                // adopted into a rebuilt index.
                let promoted = try SessionTransferCodecV1.validate(packageAt: targetURL, matches: metadata)
                record = SessionRecord(
                    transferEnvelope: metadata,
                    sessionEnvelope: promoted.sessionEnvelope,
                    completion: promoted.completion
                )
            } else {
                // Write the sidecar before the package move. If the process is
                // interrupted after the move, startup reconciliation has both
                // durable package metadata and bytes with which to rebuild the
                // missing index entry.
                try writeDataAtomically(metadataData, to: storedMetadataURL(for: targetURL))
                try fileManager.moveItem(at: sourceURL, to: targetURL)
                record = SessionRecord(
                    transferEnvelope: metadata,
                    sessionEnvelope: inspected.sessionEnvelope,
                    completion: inspected.completion
                )
            }

            index = Index(schemaVersion: 1, entries: index.entries + [record])
            try writeJSONAtomically(index, to: indexURL)
            let receiptPayload = try persistReceipt(for: record)
            try writeImportMarker(
                .init(result: "imported", sessionID: record.sessionID, packageDigest: record.packageDigest, handledAt: Date()),
                in: deliveryDirectory
            )
            return .imported(record: record, receiptPayload: receiptPayload)
        } catch {
            return quarantine(
                deliveryID: deliveryID,
                reason: "Package validation failed: \(String(describing: error))"
            )
        }
    }

    /// Durable receipts are intentionally retained. Requeueing one is safe for
    /// the receiver to make idempotent, and a WC callback alone never removes
    /// proof that the import completed locally.
    public func durableReceiptPayloads() -> [Data] {
        guard let sessionDirectories = try? fileManager.contentsOfDirectory(
            at: receiptsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return sessionDirectories
            .flatMap { directory in
                (try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
            }
            .sorted { $0.path < $1.path }
            .compactMap { try? Data(contentsOf: $0) }
            .filter { payload in
                guard let receipt = try? SessionTransferCodecV1.decodeReceipt(payload) else {
                    return false
                }
                return !tombstones.entries.contains {
                    $0.sessionID == receipt.sessionID
                        && $0.packageDigest == receipt.packageDigest
                }
            }
    }

    private func loadTombstones() throws -> TombstoneStore {
        guard fileManager.fileExists(atPath: tombstonesURL.path) else {
            return TombstoneStore(schemaVersion: 1, entries: [])
        }
        let loaded = try JSONDecoder().decode(TombstoneStore.self, from: Data(contentsOf: tombstonesURL))
        guard loaded.schemaVersion == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return loaded
    }

    private func rebuildIndexFromPackages() throws {
        let sessionDirectories = try fileManager.contentsOfDirectory(
            at: packagesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var recordsBySessionID: [UUID: SessionRecord] = [:]

        for sessionDirectory in sessionDirectories.sorted(by: { $0.path < $1.path }) {
            let values = try sessionDirectory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let packageURLs = try fileManager.contentsOfDirectory(
                at: sessionDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for candidateURL in packageURLs
                .filter({ $0.pathExtension == FootySessionPackageV1.fileExtension })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    let inspected = try SessionTransferCodecV1.inspectCompletePackage(at: candidateURL)
                    if tombstones.entries.contains(where: {
                        $0.sessionID == inspected.sessionEnvelope.sessionID
                            && $0.packageDigest == inspected.transferEnvelope.packageDigest
                    }) {
                        // A crash after the tombstone write but before package
                        // removal must not resurrect the deleted iPhone copy.
                        try quarantineStoredPackage(
                            candidateURL,
                            reason: "Suppressed by an iPhone deletion tombstone during startup reconciliation"
                        )
                        continue
                    }
                    let expectedURL = packageURL(
                        sessionID: inspected.sessionEnvelope.sessionID,
                        digest: inspected.transferEnvelope.packageDigest
                    )
                    guard candidateURL.standardizedFileURL == expectedURL.standardizedFileURL else {
                        try quarantineStoredPackage(candidateURL, reason: "Stored package path does not match its session identifier and digest")
                        continue
                    }
                    let storedEnvelope = try readStoredEnvelope(for: candidateURL) ?? inspected.transferEnvelope
                    guard storedEnvelope.sessionID == inspected.sessionEnvelope.sessionID,
                          storedEnvelope.packageDigest == inspected.transferEnvelope.packageDigest,
                          storedEnvelope.byteCount == inspected.transferEnvelope.byteCount else {
                        try quarantineStoredPackage(candidateURL, reason: "Stored transfer metadata does not match package bytes")
                        continue
                    }
                    let record = SessionRecord(
                        transferEnvelope: storedEnvelope,
                        sessionEnvelope: inspected.sessionEnvelope,
                        completion: inspected.completion
                    )
                    if let existing = recordsBySessionID[record.sessionID], existing.packageDigest != record.packageDigest {
                        try quarantineStoredPackage(candidateURL, reason: "Stored session identifier conflicts with a different digest")
                        continue
                    }
                    recordsBySessionID[record.sessionID] = record
                } catch {
                    try quarantineStoredPackage(
                        candidateURL,
                        reason: "Stored package validation failed: \(String(describing: error))"
                    )
                }
            }
        }

        index = Index(schemaVersion: 1, entries: sorted(Array(recordsBySessionID.values)))
        try writeJSONAtomically(index, to: indexURL)
        // A package that survived a crash after promotion but before index or
        // receipt persistence becomes an ordinary durable import here. The
        // coordinator will requeue these persisted payloads after activation.
        for record in index.entries {
            _ = try persistReceipt(for: record)
        }
    }

    private func reconcileIncomingStaging() throws {
        let deliveryDirectories = try fileManager.contentsOfDirectory(
            at: incomingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for deliveryDirectory in deliveryDirectories.sorted(by: { $0.path < $1.path }) {
            let values = try deliveryDirectory.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            _ = importStaged(deliveryID: deliveryDirectory.lastPathComponent)
        }
    }

    private func sorted(_ entries: [SessionRecord]) -> [SessionRecord] {
        entries.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt > $1.startedAt
            }
            return $0.sessionID.uuidString.lowercased() < $1.sessionID.uuidString.lowercased()
        }
    }

    private func packageURL(for record: SessionRecord) -> URL {
        packageURL(sessionID: record.sessionID, digest: record.packageDigest)
    }

    private func packageURL(sessionID: UUID, digest: SessionDigestV1) -> URL {
        packagesDirectory
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(digest.hexString, isDirectory: false)
            .appendingPathExtension(FootySessionPackageV1.fileExtension)
    }

    private func storedMetadataURL(for packageURL: URL) -> URL {
        packageURL.appendingPathExtension("transfer-envelope.plist")
    }

    private func receiptURL(for record: SessionRecord) -> URL {
        receiptsDirectory
            .appendingPathComponent(record.sessionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(record.packageDigest.hexString, isDirectory: false)
            .appendingPathExtension("plist")
    }

    private func persistReceipt(for record: SessionRecord) throws -> Data {
        let url = receiptURL(for: record)
        if fileManager.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url)
            _ = try SessionTransferCodecV1.decodeReceipt(existing)
            return existing
        }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let receipt = SyncReceiptV1(
            receiptID: UUID(),
            sessionID: record.sessionID,
            packageDigest: record.packageDigest,
            acknowledgedAt: Date(),
            destination: "iPhone"
        )
        let payload = try SessionTransferCodecV1.encodeReceipt(receipt)
        try writeDataAtomically(payload, to: url)
        return payload
    }

    private func readStoredEnvelope(for packageURL: URL) throws -> SessionTransferEnvelopeV1? {
        let url = storedMetadataURL(for: packageURL)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try SessionTransferCodecV1.decodeTransferEnvelope(Data(contentsOf: url))
    }

    private func writeImportMarker(_ marker: IncomingImportMarker, in directory: URL) throws {
        try writePropertyListAtomically(
            marker,
            to: directory.appendingPathComponent("import-marker.plist", isDirectory: false)
        )
    }

    private func quarantine(deliveryID: String, reason: String) -> ImportOutcome {
        let source = incomingDirectory.appendingPathComponent(deliveryID, isDirectory: true)
        let destination = quarantineDirectory.appendingPathComponent(deliveryID, isDirectory: true)
        do {
            if fileManager.fileExists(atPath: source.path) {
                let finalDestination: URL
                if fileManager.fileExists(atPath: destination.path) {
                    finalDestination = quarantineDirectory.appendingPathComponent(
                        "\(deliveryID)-\(UUID().uuidString.lowercased())",
                        isDirectory: true
                    )
                } else {
                    finalDestination = destination
                }
                try fileManager.moveItem(at: source, to: finalDestination)
                try writeDataAtomically(
                    Data(reason.utf8),
                    to: finalDestination.appendingPathComponent("quarantine-reason.txt", isDirectory: false)
                )
            }
        } catch {
            // Retain the delivery in place if moving it is impossible; the
            // source bytes are still safer than discarding a failed transfer.
            try? writeDataAtomically(
                Data("\(reason) (quarantine move failed: \(String(describing: error)))".utf8),
                to: source.appendingPathComponent("quarantine-reason.txt", isDirectory: false)
            )
        }
        return .quarantined(deliveryID: deliveryID, reason: reason)
    }

    private func quarantineStoredPackage(_ packageURL: URL, reason: String) throws {
        let deliveryID = "recovery-\(UUID().uuidString.lowercased())"
        let destination = quarantineDirectory.appendingPathComponent(deliveryID, isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.moveItem(
            at: packageURL,
            to: destination.appendingPathComponent(packageURL.lastPathComponent, isDirectory: false)
        )
        let metadataURL = storedMetadataURL(for: packageURL)
        if fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.moveItem(
                at: metadataURL,
                to: destination.appendingPathComponent(metadataURL.lastPathComponent, isDirectory: false)
            )
        }
        try writeDataAtomically(
            Data(reason.utf8),
            to: destination.appendingPathComponent("quarantine-reason.txt", isDirectory: false)
        )
    }

    private static func writeDataAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    private func writeDataAtomically(_ data: Data, to url: URL) throws {
        try Self.writeDataAtomically(data, to: url)
    }

    private static func writePropertyListAtomically<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try writeDataAtomically(try encoder.encode(value), to: url)
    }

    private func writePropertyListAtomically<Value: Encodable>(_ value: Value, to url: URL) throws {
        try Self.writePropertyListAtomically(value, to: url)
    }

    private func writeJSONAtomically<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeDataAtomically(try encoder.encode(value), to: url)
    }
}
