import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import FootballPerformanceWatch

final class WatchSessionRepositoryRecoveryTests: XCTestCase {
    private func makeEnvelope() -> SessionEnvelopeV1 {
        SessionEnvelopeV1(
            sessionID: UUID(),
            createdAt: Date(),
            startedAt: Date(),
            captureSource: .batchedCoreMotion,
            initialAccelerometerAvailability: .available,
            initialDeviceMotionAvailability: .available
        )
    }

    private func makeHeartRate(_ bpm: Double) -> HeartRateSnapshotV1 {
        HeartRateSnapshotV1(
            timestamp: Date(),
            beatsPerMinute: SessionMetricV1(
                value: bpm,
                unit: .beatsPerMinute,
                provenance: .healthKitLive
            )
        )
    }

    private func makeLargePartial(
        at url: URL,
        envelope: SessionEnvelopeV1,
        batchCount: Int = 70,
        samplesPerBatch: Int = 8_000
    ) throws -> UInt64 {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try FootySessionPackageV1.writeHeader(to: handle)
        _ = try FootySessionPackageV1.append(
            frame: FootySessionFrameV1(payload: .envelope(envelope)),
            to: handle,
            limits: .default
        )

        let samples = (0..<samplesPerBatch).map { index in
            let value = Double(index) / 10_000
            return DeviceMotionSampleV1(
                timestamp: Double(index) / 100,
                userAcceleration: Vector3V1(x: value, y: value + 0.1, z: value + 0.2),
                gravity: Vector3V1(x: value + 0.3, y: value + 0.4, z: value + 0.5),
                rotationRate: Vector3V1(x: value + 0.6, y: value + 0.7, z: value + 0.8)
            )
        }
        let frame = FootySessionFrameV1(
            payload: .deviceMotionBatch(
                DeviceMotionBatchV1(source: .batchedCoreMotion, samples: samples)
            )
        )
        for _ in 0..<batchCount {
            try autoreleasepool {
                _ = try FootySessionPackageV1.append(
                    frame: frame,
                    to: handle,
                    limits: .default
                )
            }
        }

        // Add a torn final record. Recovery must ignore these bytes while it
        // preserves every complete record before them.
        try handle.write(contentsOf: Data([0, 0, 0, 100, 0x62, 0x70, 0x6C, 0x69]))
        try handle.synchronize()
        return try XCTUnwrap(
            url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(UInt64.init)
        ) - 8
    }

    private func assertPrefixesEqual(
        _ firstURL: URL,
        _ secondURL: URL,
        byteCount: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let first = try FileHandle(forReadingFrom: firstURL)
        let second = try FileHandle(forReadingFrom: secondURL)
        defer {
            try? first.close()
            try? second.close()
        }

        var remaining = byteCount
        while remaining > 0 {
            let count = Int(min(remaining, 64 * 1024))
            let firstChunk = try first.read(upToCount: count) ?? Data()
            let secondChunk = try second.read(upToCount: count) ?? Data()
            XCTAssertEqual(firstChunk, secondChunk, file: file, line: line)
            guard firstChunk.count == count, secondChunk.count == count else {
                return XCTFail("package prefix ended early", file: file, line: line)
            }
            remaining -= UInt64(count)
        }
    }

    func testHeaderOnlyPartialCanBeQuarantinedWithoutRepeatingRecoveryError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSessionRepositoryRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try WatchSessionRepository(sessionsDirectory: directory)
        let filename = "orphan.partial"
        let partialURL = directory.appendingPathComponent(filename)
        XCTAssertTrue(FileManager.default.createFile(atPath: partialURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: partialURL)
        try FootySessionPackageV1.writeHeader(to: handle)
        try handle.close()

        do {
            _ = try await repository.recoverPartial(named: filename)
            XCTFail("A partial without an envelope must not be presented as a recovered session")
        } catch let error as SessionPackageError {
            XCTAssertEqual(error, .missingSessionEnvelope)
        }

        let quarantinedFilename = try await repository.quarantinePartial(named: filename)
        let quarantinedURL = directory
            .appendingPathComponent("Quarantine", isDirectory: true)
            .appendingPathComponent(quarantinedFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedURL.path))
        let remainingPackages = try await repository.discover()
        XCTAssertTrue(remainingPackages.isEmpty)
    }

    @MainActor
    func testRecoveredSealedPartialIsEnqueuedExactlyOnceThroughOutbox() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSessionRepositoryRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try WatchSessionRepository(sessionsDirectory: directory)

        // A valid open package with one durable HR frame, abandoned mid-write
        // (no completion frame): the shape a hung "Saving session" leaves.
        let envelope = makeEnvelope()
        let writer = try await repository.startWriter(envelope: envelope)
        try await writer.appendHeartRateSnapshot(makeHeartRate(150))
        let partialFilename = envelope.sessionID.uuidString + "." + FootySessionPackageV1.partialFileExtension

        let recovered = try await repository.recoverPartial(named: partialFilename)
        let recoveredURL = directory.appendingPathComponent(recovered.recoveredFilename)

        let outbox = try WatchTransferOutbox(
            outboxDirectory: directory.appendingPathComponent("Outbox", isDirectory: true),
            sessionsDirectory: directory
        )

        let counter = SubmissionCounter()
        let launchSync = LaunchRecoverySync { url in
            counter.count += 1
            _ = try? await outbox.enqueue(sealedPackageAt: url)
        }
        await launchSync.submitDiscoveredPackage(at: recoveredURL)
        await launchSync.submitDiscoveredPackage(at: recoveredURL)

        XCTAssertEqual(counter.count, 2, "bounded re-submission must still retry across launches")
        let snapshot = await outbox.snapshot()
        XCTAssertEqual(snapshot.records.count, 1, "digest-keyed outbox must deduplicate re-submissions")
        let record = try XCTUnwrap(snapshot.records.values.first)
        XCTAssertEqual(record.packageFilename, recovered.recoveredFilename)
        XCTAssertEqual(record.status, .pending)
    }

    @MainActor
    func testRelaunchedAuditReusesExistingRecoveredFileInsteadOfDuplicating() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSessionRepositoryRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try WatchSessionRepository(sessionsDirectory: directory)
        let envelope = makeEnvelope()
        let writer = try await repository.startWriter(envelope: envelope)
        try await writer.appendHeartRateSnapshot(makeHeartRate(150))
        let partialFilename = envelope.sessionID.uuidString + "." + FootySessionPackageV1.partialFileExtension

        let first = try await repository.recoverPartial(named: partialFilename)
        let discovered = try await repository.discover()

        let reused = LaunchRecoverySync.recoveredFilename(
            forPartialNamed: partialFilename,
            discovered: discovered
        )
        XCTAssertEqual(reused, first.recoveredFilename)

        let second = try await repository.recoverPartial(named: partialFilename)
        XCTAssertNotEqual(second.recoveredFilename, first.recoveredFilename)
        let finalDiscovery = try await repository.discover()
        XCTAssertEqual(
            discovered.filter { $0.kind == .sealed }.count + 1,
            finalDiscovery.filter { $0.kind == .sealed }.count
        )
    }

    func testStreamVerifiedFramesCountsOnlyRecordsCopied() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSessionRepositoryRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sourceURL = directory.appendingPathComponent("source.partial")
        let destinationURL = directory.appendingPathComponent("destination.partial")
        let envelope = makeEnvelope()
        let completion = SessionCompletionV1(
            endedAt: Date(),
            lifecycle: .completed,
            summary: nil,
            healthKitSaveOutcome: .unavailable(reason: .notAttempted)
        )
        try FootySessionPackageV1.writePackage(
            frames: [
                FootySessionFrameV1(payload: .envelope(envelope)),
                FootySessionFrameV1(payload: .completion(completion))
            ],
            to: sourceURL
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: destinationURL.path, contents: nil))
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer { try? destination.close() }
        try FootySessionPackageV1.writeHeader(to: destination)

        let copiedCount = try FootySessionPackageV1.streamVerifiedFrames(
            from: sourceURL,
            to: destination,
            limits: .default
        )
        try destination.synchronize()

        XCTAssertEqual(copiedCount, 1)
        let destinationScan = try FootySessionPackageV1.scanStructure(of: destinationURL)
        XCTAssertEqual(destinationScan.frameCount, 1)
        XCTAssertEqual(destinationScan.envelope, envelope)
        XCTAssertEqual(destinationScan.status, .incomplete)
    }

    func testBoundedReadersRejectNonpositiveFrameLimitsAndAcceptAboveUInt32Maximum() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSessionRepositoryRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sourceURL = directory.appendingPathComponent("source.partial")
        try FootySessionPackageV1.writePackage(
            frames: [FootySessionFrameV1(payload: .envelope(makeEnvelope()))],
            to: sourceURL
        )

        for maximumFrameBytes in [0, -1] {
            let limits = SessionPackageReaderLimitsV1(maximumFrameBytes: maximumFrameBytes)
            XCTAssertThrowsError(try FootySessionPackageV1.scanStructure(of: sourceURL, limits: limits)) {
                XCTAssertEqual($0 as? SessionPackageError, .invalidSynchronizationPolicy)
            }

            let destinationURL = directory.appendingPathComponent("invalid-\(maximumFrameBytes).partial")
            XCTAssertTrue(FileManager.default.createFile(atPath: destinationURL.path, contents: nil))
            let destination = try FileHandle(forWritingTo: destinationURL)
            defer { try? destination.close() }
            XCTAssertThrowsError(
                try FootySessionPackageV1.streamVerifiedFrames(
                    from: sourceURL,
                    to: destination,
                    limits: limits
                )
            ) {
                XCTAssertEqual($0 as? SessionPackageError, .invalidSynchronizationPolicy)
            }
        }

        if MemoryLayout<Int>.size > MemoryLayout<UInt32>.size {
            let limits = SessionPackageReaderLimitsV1(maximumFrameBytes: Int(UInt32.max) + 1)
            XCTAssertEqual(try FootySessionPackageV1.scanStructure(of: sourceURL, limits: limits).frameCount, 1)

            let destinationURL = directory.appendingPathComponent("large-limit.partial")
            XCTAssertTrue(FileManager.default.createFile(atPath: destinationURL.path, contents: nil))
            let destination = try FileHandle(forWritingTo: destinationURL)
            defer { try? destination.close() }
            XCTAssertEqual(
                try FootySessionPackageV1.streamVerifiedFrames(
                    from: sourceURL,
                    to: destination,
                    limits: limits
                ),
                1
            )
        }
    }

    func testScanStructureMatchesReadDigestAndStatusOnTornTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSessionRepositoryRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Enough frames to make whole-package retention meaningful; each frame
        // is individually small, which is exactly the long-session shape.
        let url = directory.appendingPathComponent("torn.\(FootySessionPackageV1.partialFileExtension)")
        let envelope = makeEnvelope()
        let frames = (0..<500).map { index -> FootySessionFrameV1 in
            index == 0
                ? FootySessionFrameV1(payload: .envelope(envelope))
                : FootySessionFrameV1(payload: .heartRateSnapshot(makeHeartRate(140 + Double(index % 40))))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FootySessionPackageV1.writePackage(frames: frames, to: url)

        // Tear the tail: drop the final frame's digest bytes.
        let fullData = try Data(contentsOf: url)
        let tornData = fullData.dropLast(FootySessionPackageV1.frameDigestByteCount)
        try tornData.write(to: url)

        let scan = try FootySessionPackageV1.scanStructure(of: url)
        let read = try FootySessionPackageV1.read(from: url)

        XCTAssertEqual(scan.status, .tornTail)
        XCTAssertEqual(read.status, .tornTail)
        XCTAssertEqual(scan.frameCount, read.frames.count, "both readers stop before the torn frame")
        XCTAssertEqual(scan.envelope, envelope)
        XCTAssertNil(scan.completion)
        XCTAssertEqual(scan.wholeFileDigest, read.wholeFileDigest, "digest covers exactly the bytes on disk")
    }

    /// The Watch Jetsam killer terminated the app while `digest(of:)` checked a
    /// 549 MB sealed package during recovery (build 23, 2026-09-01). `digest`
    /// looped over `FileHandle.read(upToCount:)` without a per-iteration
    /// autorelease pool, so every 64 KiB autoreleased chunk accumulated until
    /// the enclosing pool drained — roughly one heap region per chunk, matching
    /// the observed ~4,800 regions for a 300 MiB peak. This test writes a large
    /// file incrementally (never holding a package-sized Data), hashes it with
    /// an INDEPENDENT SHA256 computed entirely outside `FootySessionPackageV1`,
    /// then verifies (a) the digest matches that trusted value and (b) physical
    /// footprint stays far below the file size while it runs.
    func testWholeFileDigestStaysBoundedAndMatchesIndependentSHA256() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSessionRepositoryRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("large-digest.footysession")
        let chunkSize = 64 * 1024
        let totalBytes = 32 * 1024 * 1024 // 32 MiB — ~6% of the 549 MB real package

        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var expectedHasher = SHA256()
        var remaining = totalBytes
        var seed: UInt8 = 0x5A
        while remaining > 0 {
            let count = min(chunkSize, remaining)
            let bytes = (0..<count).map { _ -> UInt8 in
                seed &+= 0x11
                return seed
            }
            let chunk = Data(bytes)
            try handle.write(contentsOf: chunk)
            expectedHasher.update(data: chunk)
            remaining -= count
        }
        try handle.synchronize()

        let expectedDigest = SessionDigestV1(bytes: Data(expectedHasher.finalize()))

        let sampler = PhysicalFootprintSampler()
        try sampler.start()
        let digest = try FootySessionPackageV1.digest(of: url)
        let growth = try sampler.stop()

        XCTAssertEqual(digest, expectedDigest, "whole-file digest must match an independently computed SHA256")
        XCTAssertLessThan(
            growth,
            16 * 1024 * 1024,
            "digest of a 32 MiB file grew physical footprint by \(growth) bytes; "
                + "expected bounded memory (no file-sized autorelease accumulation)"
        )
    }

    @MainActor
    func testLargeTornRecoveryAndEnqueueStayBoundedAndIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSessionRepositoryRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try WatchSessionRepository(sessionsDirectory: directory)
        let envelope = makeEnvelope()
        let partialFilename = envelope.sessionID.uuidString
            + "."
            + FootySessionPackageV1.partialFileExtension
        let partialURL = directory.appendingPathComponent(partialFilename)

        // 560,000 motion samples approximate 90 minutes at 100 Hz. The file is
        // written from one reusable frame, so the fixture itself never holds a
        // package-sized Data or frame array in memory. Each near-limit frame
        // also reproduces the Foundation decode expansion that small HR frames
        // cannot expose.
        let validPrefixByteCount = try makeLargePartial(at: partialURL, envelope: envelope)
        let sourceDigestBefore = try FootySessionPackageV1.digest(of: partialURL)
        let sampler = PhysicalFootprintSampler()
        try sampler.start()
        defer { _ = try? sampler.stop() }

        let recovered = try await repository.recoverPartial(named: partialFilename)
        let footprintGrowth = try sampler.stop()
        XCTAssertLessThan(
            footprintGrowth,
            24 * 1024 * 1024,
            "recovery peaked \(footprintGrowth) bytes above baseline"
        )
        XCTAssertEqual(recovered.sourceStatus, .tornTail)
        let recoveredURL = directory.appendingPathComponent(recovered.recoveredFilename)

        let outbox = try WatchTransferOutbox(
            outboxDirectory: directory.appendingPathComponent("Outbox", isDirectory: true),
            sessionsDirectory: directory
        )
        try sampler.start()
        _ = try await outbox.enqueue(sealedPackageAt: recoveredURL)
        _ = try await outbox.enqueue(sealedPackageAt: recoveredURL)
        let enqueueFootprintGrowth = try sampler.stop()
        XCTAssertLessThan(
            enqueueFootprintGrowth,
            24 * 1024 * 1024,
            "duplicate transfer enqueue peaked \(enqueueFootprintGrowth) bytes above baseline"
        )

        XCTAssertEqual(try FootySessionPackageV1.digest(of: partialURL), sourceDigestBefore)
        try assertPrefixesEqual(partialURL, recoveredURL, byteCount: validPrefixByteCount)

        let recoveredScan = try FootySessionPackageV1.scanStructure(of: recoveredURL)
        XCTAssertEqual(recoveredScan.status, .complete)
        XCTAssertEqual(recoveredScan.frameCount, 72)
        XCTAssertEqual(
            recoveredScan.completion?.lifecycle,
            .interrupted(reason: .partialFileRecovery)
        )

        let discovered = try await repository.discover()
        XCTAssertEqual(
            LaunchRecoverySync.recoveredFilename(
                forPartialNamed: partialFilename,
                discovered: discovered
            ),
            recovered.recoveredFilename
        )
        XCTAssertEqual(discovered.filter { $0.kind == .partial }.count, 1)
        XCTAssertEqual(discovered.filter { $0.kind == .sealed }.count, 1)
        let outboxSnapshot = await outbox.snapshot()
        XCTAssertEqual(outboxSnapshot.records.count, 1)
    }

    @MainActor
    func testRecoveryStreamsByteIdenticalFramesAcrossLongPackage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSessionRepositoryRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let repository = try WatchSessionRepository(sessionsDirectory: directory)
        let envelope = makeEnvelope()
        let writer = try await repository.startWriter(envelope: envelope)
        for index in 0..<500 {
            try await writer.appendHeartRateSnapshot(makeHeartRate(140 + Double(index % 40)))
        }
        let partialFilename = envelope.sessionID.uuidString + "." + FootySessionPackageV1.partialFileExtension

        let recovered = try await repository.recoverPartial(named: partialFilename)
        let recoveredURL = directory.appendingPathComponent(recovered.recoveredFilename)

        // The recovered package must be structurally valid, end with the new
        // interrupted completion, and preserve every source frame exactly.
        let read = try FootySessionPackageV1.read(from: recoveredURL)
        XCTAssertEqual(read.status, .complete)
        XCTAssertEqual(read.frames.count, 502, "envelope + 500 streamed frames + new completion")
        guard case let .envelope(recoveredEnvelope) = read.frames.first?.payload else {
            return XCTFail("recovered package must start with the original envelope")
        }
        XCTAssertEqual(recoveredEnvelope, envelope)
        guard case let .completion(completion) = read.frames.last?.payload else {
            return XCTFail("recovered package must end with a completion frame")
        }
        XCTAssertEqual(completion.lifecycle, .interrupted(reason: .partialFileRecovery))

        // Frame-for-frame identity with the source for all non-completion frames.
        let sourceRead = try FootySessionPackageV1.read(
            from: directory.appendingPathComponent(partialFilename)
        )
        let recoveredSensorFrames = read.frames.dropLast()
        XCTAssertEqual(recoveredSensorFrames.count, sourceRead.frames.count)
        for (recoveredFrame, sourceFrame) in zip(recoveredSensorFrames, sourceRead.frames) {
            XCTAssertEqual(recoveredFrame, sourceFrame)
        }

        // And the outbox must accept it: inspectCompletePackage now runs the
        // same bounded scan the Watch uses before transfer.
        let inspected = try SessionTransferCodecV1.inspectCompletePackage(at: recoveredURL)
        XCTAssertEqual(inspected.sessionEnvelope, envelope)
        XCTAssertEqual(inspected.completion, completion)
    }
}

/// Class-based counter: the `LaunchRecoverySync.submit` closure is
/// `@MainActor`-isolated, so a captured local `var` cannot be mutated from it
/// under Swift 6 strict concurrency.
final class SubmissionCounter: @unchecked Sendable {
    var count = 0
}

private enum PhysicalFootprintSamplerError: Error {
    case alreadyRunning
    case taskInfoFailed(kern_return_t)
}

final class PhysicalFootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private let taskGroup = DispatchGroup()
    private var running = false
    private var baseline: UInt64 = 0
    private var maximum: UInt64 = 0
    private var samplingFailure: PhysicalFootprintSamplerError?
    private var task: Task<Void, Never>?

    func start() throws {
        let initial = try Self.current()

        lock.lock()
        guard !running else {
            lock.unlock()
            throw PhysicalFootprintSamplerError.alreadyRunning
        }
        baseline = initial
        maximum = initial
        samplingFailure = nil
        running = true
        let taskGroup = taskGroup
        taskGroup.enter()
        task = Task.detached(priority: .high) { [weak self] in
            defer { taskGroup.leave() }
            while let self, self.sample() {
                do {
                    try await Task.sleep(for: .milliseconds(1))
                } catch {
                    break
                }
            }
        }
        lock.unlock()
    }

    @discardableResult
    func stop() throws -> UInt64 {
        let finalSample = Result { try Self.current() }

        lock.lock()
        guard running || task != nil else {
            let growth = maximum > baseline ? maximum - baseline : 0
            let failure = samplingFailure
            lock.unlock()
            if let failure { throw failure }
            return growth
        }
        running = false
        let measurementTask = task
        lock.unlock()

        measurementTask?.cancel()
        taskGroup.wait()

        lock.lock()
        if case let .success(current) = finalSample {
            maximum = max(maximum, current)
        }
        let growth = maximum > baseline ? maximum - baseline : 0
        let backgroundFailure = samplingFailure
        task = nil
        lock.unlock()

        if let backgroundFailure { throw backgroundFailure }
        _ = try finalSample.get()
        return growth
    }

    private func sample() -> Bool {
        do {
            let current = try Self.current()
            lock.lock()
            defer { lock.unlock() }
            guard running else { return false }
            maximum = max(maximum, current)
            return true
        } catch let error as PhysicalFootprintSamplerError {
            lock.lock()
            samplingFailure = error
            running = false
            lock.unlock()
            return false
        } catch {
            preconditionFailure("Unexpected physical-footprint sampling error: \(error)")
        }
    }

    private static func current() throws -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw PhysicalFootprintSamplerError.taskInfoFailed(result)
        }
        return info.resident_size
    }
}
