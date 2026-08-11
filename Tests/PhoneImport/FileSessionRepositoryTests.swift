import Foundation
import Testing
@testable import FootballPerformance

@Suite("FileSessionRepository")
struct FileSessionRepositoryTests {
    @Test("a complete matching package imports and persists a receipt")
    func validImport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        try await repository.reconcileOnStartup()

        let package = try fixture.writePackage(sessionID: fixture.firstSessionID, startedAt: fixture.start)
        let deliveryID = try fixture.stage(package)
        let outcome = await repository.importStaged(deliveryID: deliveryID)

        guard case let .imported(record, payload) = outcome else {
            Issue.record("Expected durable import, received \(outcome)")
            return
        }
        #expect(record.sessionID == fixture.firstSessionID)
        #expect(try SessionTransferCodecV1.decodeReceipt(payload).sessionID == fixture.firstSessionID)
        let sessions = await repository.sessions()
        let receipts = await repository.durableReceiptPayloads()
        #expect(sessions.count == 1)
        #expect(receipts.count == 1)
    }

    @Test("the same session and digest is idempotent and requeues its durable receipt")
    func sameDigestDuplicate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let package = try fixture.writePackage(sessionID: fixture.firstSessionID, startedAt: fixture.start)
        let copy = fixture.directory.appendingPathComponent("copy.footysession")
        try Data(contentsOf: package.url).write(to: copy, options: .atomic)

        _ = await repository.importStaged(deliveryID: try fixture.stage(package))
        let duplicate = await repository.importStaged(deliveryID: try fixture.stage(.init(url: copy, metadata: package.metadata)))

        guard case let .duplicate(record, receiptPayload) = duplicate else {
            Issue.record("Expected an idempotent duplicate, received \(duplicate)")
            return
        }
        #expect(record.packageDigest == package.metadata.packageDigest)
        #expect(try SessionTransferCodecV1.decodeReceipt(receiptPayload).packageDigest == package.metadata.packageDigest)
        let sessions = await repository.sessions()
        #expect(sessions.count == 1)
    }

    @Test("the same session identifier with different bytes is quarantined without another receipt")
    func sameIDDifferentDigestConflict() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let first = try fixture.writePackage(sessionID: fixture.firstSessionID, startedAt: fixture.start)
        let conflicting = try fixture.writePackage(
            sessionID: fixture.firstSessionID,
            startedAt: fixture.start,
            includeHeartRateSnapshot: true,
            filename: "conflicting.footysession"
        )

        _ = await repository.importStaged(deliveryID: try fixture.stage(first))
        let outcome = await repository.importStaged(deliveryID: try fixture.stage(conflicting))

        guard case .quarantined = outcome else {
            Issue.record("Expected conflicting package to be quarantined, received \(outcome)")
            return
        }
        let sessions = await repository.sessions()
        let receipts = await repository.durableReceiptPayloads()
        #expect(sessions.count == 1)
        #expect(receipts.count == 1)
        #expect(try fixture.quarantineDeliveryCount() == 1)
    }

    @Test("corrupt, unknown-version, and incomplete packages are quarantined")
    func invalidPackagesQuarantine() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()

        let corrupt = try fixture.writePackage(sessionID: fixture.firstSessionID, startedAt: fixture.start)
        var corruptBytes = try Data(contentsOf: corrupt.url)
        corruptBytes[corruptBytes.index(before: corruptBytes.endIndex)] ^= 0xFF
        try corruptBytes.write(to: corrupt.url, options: .atomic)

        let unknown = try fixture.writePackage(
            sessionID: fixture.secondSessionID,
            startedAt: fixture.start,
            filename: "unknown.footysession"
        )
        var unknownBytes = try Data(contentsOf: unknown.url)
        unknownBytes[8] = 0
        unknownBytes[9] = 0
        unknownBytes[10] = 0
        unknownBytes[11] = 2
        try unknownBytes.write(to: unknown.url, options: .atomic)

        let incomplete = try fixture.writePackage(
            sessionID: fixture.thirdSessionID,
            startedAt: fixture.start,
            complete: false,
            filename: "incomplete.footysession"
        )

        let corruptOutcome = await repository.importStaged(deliveryID: try fixture.stage(corrupt))
        let unknownOutcome = await repository.importStaged(deliveryID: try fixture.stage(unknown))
        let incompleteOutcome = await repository.importStaged(deliveryID: try fixture.stage(incomplete))
        guard case .quarantined = corruptOutcome,
              case .quarantined = unknownOutcome,
              case .quarantined = incompleteOutcome else {
            Issue.record("Every invalid package must be quarantined")
            return
        }
        let sessions = await repository.sessions()
        #expect(sessions.isEmpty)
        #expect(try fixture.quarantineDeliveryCount() == 3)
    }

    @Test("startup rebuild orders sessions newest-first with UUID as a deterministic tie-breaker")
    func indexRebuildAndNewestOrdering() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let first = try fixture.writePackage(
            sessionID: fixture.firstSessionID,
            startedAt: fixture.start,
            filename: "first.footysession"
        )
        let second = try fixture.writePackage(
            sessionID: fixture.secondSessionID,
            startedAt: fixture.start,
            filename: "second.footysession"
        )
        let newest = try fixture.writePackage(
            sessionID: fixture.thirdSessionID,
            startedAt: fixture.start.addingTimeInterval(60),
            filename: "newest.footysession"
        )

        _ = await repository.importStaged(deliveryID: try fixture.stage(second))
        _ = await repository.importStaged(deliveryID: try fixture.stage(newest))
        _ = await repository.importStaged(deliveryID: try fixture.stage(first))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("index.json"))

        let rebuilt = try fixture.repository()
        try await rebuilt.reconcileOnStartup()
        let identifiers = await rebuilt.sessions().map(\.sessionID)
        #expect(identifiers == [fixture.thirdSessionID, fixture.firstSessionID, fixture.secondSessionID])
    }

    @Test("an offered export is the exact stored byte sequence after digest verification")
    func exactExportDigest() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let package = try fixture.writePackage(sessionID: fixture.firstSessionID, startedAt: fixture.start)
        let originalBytes = try Data(contentsOf: package.url)
        _ = await repository.importStaged(deliveryID: try fixture.stage(package))

        let exportURL = try await repository.verifiedExportURL(for: fixture.firstSessionID)
        #expect(try Data(contentsOf: exportURL) == originalBytes)
        #expect(try FootySessionPackageV1.digest(of: exportURL) == package.metadata.packageDigest)
    }

    @Test("a tombstone suppresses a late duplicate without restoring the iPhone copy")
    func tombstoneSuppression() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let package = try fixture.writePackage(sessionID: fixture.firstSessionID, startedAt: fixture.start)
        let originalBytes = try Data(contentsOf: package.url)
        _ = await repository.importStaged(deliveryID: try fixture.stage(package))
        _ = try await repository.deleteIPhoneCopy(for: fixture.firstSessionID)

        let lateCopy = fixture.directory.appendingPathComponent("late.footysession")
        try originalBytes.write(to: lateCopy, options: .atomic)
        let outcome = await repository.importStaged(
            deliveryID: try fixture.stage(.init(url: lateCopy, metadata: package.metadata))
        )
        guard case .suppressedByTombstone = outcome else {
            Issue.record("Expected late duplicate to be tombstone-suppressed, received \(outcome)")
            return
        }
        let sessions = await repository.sessions()
        let receipts = await repository.durableReceiptPayloads()
        #expect(sessions.isEmpty)
        #expect(receipts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("tombstones.json").path))
    }

    @Test("missing summary values and snapshots remain absent rather than becoming zero")
    func honestMissingMetrics() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.repository()
        let package = try fixture.writePackage(
            sessionID: fixture.firstSessionID,
            startedAt: fixture.start,
            includeHeartRateSnapshot: false,
            includeDistanceSnapshot: false,
            includeSummary: false
        )
        _ = await repository.importStaged(deliveryID: try fixture.stage(package))

        let detail = try await repository.detail(for: fixture.firstSessionID)
        #expect(detail.heartRateSnapshots.isEmpty)
        #expect(detail.distanceSnapshots.isEmpty)
        #expect(detail.record.completion.summary == nil)
    }

    private struct Fixture {
        struct Package {
            let url: URL
            let metadata: SessionTransferEnvelopeV1
        }

        let directory: URL
        let root: URL
        let start = Date(timeIntervalSinceReferenceDate: 100_000)
        let firstSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let thirdSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PhoneImportTests-\(UUID().uuidString)", isDirectory: true)
            root = directory.appendingPathComponent("FootballPerformance", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func repository() throws -> FileSessionRepository {
            try FileSessionRepository(configuration: .init(rootDirectory: root))
        }

        func writePackage(
            sessionID: UUID,
            startedAt: Date,
            includeHeartRateSnapshot: Bool = false,
            includeDistanceSnapshot: Bool = false,
            includeSummary: Bool = true,
            complete: Bool = true,
            filename: String = "package.footysession"
        ) throws -> Package {
            let envelope = SessionEnvelopeV1(
                sessionID: sessionID,
                createdAt: startedAt,
                startedAt: startedAt,
                captureSource: .batchedCoreMotion,
                initialAccelerometerAvailability: .available,
                initialDeviceMotionAvailability: .available
            )
            var frames: [FootySessionFrameV1] = [.init(payload: .envelope(envelope))]
            if includeHeartRateSnapshot {
                frames.append(.init(payload: .heartRateSnapshot(
                    .init(
                        timestamp: startedAt.addingTimeInterval(15),
                        beatsPerMinute: .init(value: 135, unit: .beatsPerMinute, provenance: .healthKitLive)
                    )
                )))
            }
            if includeDistanceSnapshot {
                frames.append(.init(payload: .distanceSnapshot(
                    .init(
                        timestamp: startedAt.addingTimeInterval(20),
                        meters: .init(value: 42, unit: .meters, provenance: .healthKitFinalWorkout)
                    )
                )))
            }
            if complete {
                frames.append(.init(payload: .completion(
                    .init(
                        endedAt: startedAt.addingTimeInterval(90),
                        lifecycle: .completed,
                        summary: includeSummary ? .init(
                            duration: .init(value: 90, unit: .seconds, provenance: .healthKitFinalWorkout),
                            distance: includeDistanceSnapshot ? .init(value: 42, unit: .meters, provenance: .healthKitFinalWorkout) : nil,
                            averageHeartRate: includeHeartRateSnapshot ? .init(value: 135, unit: .beatsPerMinute, provenance: .healthKitLive) : nil
                        ) : nil,
                        healthKitSaveOutcome: .unavailable(reason: .notAttempted)
                    )
                )))
            }

            let url = directory.appendingPathComponent(filename)
            try FootySessionPackageV1.writePackage(frames: frames, to: url)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let metadata = SessionTransferEnvelopeV1(
                sessionID: sessionID,
                packageDigest: try FootySessionPackageV1.digest(of: url),
                byteCount: UInt64(values.fileSize ?? 0),
                createdAt: start
            )
            return Package(url: url, metadata: metadata)
        }

        func stage(_ package: Package) throws -> String {
            try FileSessionRepository.stageReceivedFileSynchronously(
                from: package.url,
                envelopeData: try SessionTransferCodecV1.encodeTransferEnvelope(package.metadata),
                configuration: .init(rootDirectory: root)
            )
        }

        func quarantineDeliveryCount() throws -> Int {
            try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("Quarantine", isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .count
        }
    }
}
