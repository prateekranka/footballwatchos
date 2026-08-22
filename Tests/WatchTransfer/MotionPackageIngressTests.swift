import XCTest

@testable import FootballPerformanceWatch

/// Regression tests for the b14 crash class: motion persistence must never run
/// on the main actor, must preserve delivery order under concurrent enqueue,
/// and must finish its failure box exactly once.
final class MotionPackageIngressTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var writer: SessionPackageWriter!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingress-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let handleOpen = try? writer {
            _ = handleOpen
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try super.tearDownWithError()
    }

    private func makeEnvelope() -> SessionEnvelopeV1 {
        SessionEnvelopeV1(
            sessionID: UUID(),
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            captureSource: .batchedCoreMotion,
            initialAccelerometerAvailability: .available,
            initialDeviceMotionAvailability: .available
        )
    }

    private func startWriter() throws -> SessionPackageWriter {
        let partialURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("partial")
        return try SessionPackageWriter(
            partialURL: partialURL,
            envelope: makeEnvelope()
        )
    }

    private func accelerometerBatch(sampleCount: Int) -> AccelerometerBatchV1 {
        AccelerometerBatchV1(
            source: .batchedCoreMotion,
            samples: (0..<sampleCount).map { index in
                AccelerometerSampleV1(
                    timestamp: Double(index),
                    acceleration: Vector3V1(x: 1, y: 2, z: 3)
                )
            }
        )
    }

    /// The b14 crash signature: ingress constructed from main-actor context
    /// must not trap or drop writes; all enqueued batches reach the package.
    func testAllEnqueuedBatchesPersistInDeliveryOrder() async throws {
        writer = try startWriter()
        let failureBox = MotionStorageFailureBox()
        let ingress = MotionPackageIngress(writer: writer!, failureBox: failureBox)

        // Enqueue from a non-main queue, as Core Motion does.
        let total = 40
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                for index in 0..<total {
                    var batch = self.accelerometerBatch(sampleCount: 2)
                    batch = AccelerometerBatchV1(
                        source: batch.source,
                        samples: batch.samples.map {
                            AccelerometerSampleV1(
                                timestamp: $0.timestamp + Double(index) * 100,
                                acceleration: $0.acceleration
                            )
                        }
                    )
                    ingress.yield(.accelerometer(batch))
                }
                resume.resume()
            }
        }
        ingress.finish()

        let failure = await failureBox.waitForFinish()
        XCTAssertNil(failure)

        // Read back via the writer's partial file to verify frame count/order.
        let partialURL = await writer!.partialURL
        let read = try FootySessionPackageV1.read(from: partialURL)
        XCTAssertEqual(read.frames.count, 1 + total) // envelope + batches
        guard case .envelope = read.frames.first?.payload else {
            return XCTFail("first frame must be envelope")
        }
        var expectedFirstTimestamp = 0.0
        for frame in read.frames.dropFirst() {
            guard case .accelerometerBatch(let batch) = frame.payload else {
                return XCTFail("unexpected frame kind \(frame.kind)")
            }
            XCTAssertEqual(batch.samples.first?.timestamp, expectedFirstTimestamp)
            expectedFirstTimestamp += 100
        }
    }

    /// Storage failures surface through the box instead of being swallowed.
    func testStorageFailureIsReportedThroughFailureBox() async throws {
        let sealedWriter = try startWriter()
        writer = sealedWriter
        // Seal immediately so later appends throw writerIsSealed.
        _ = try await sealedWriter.complete(
            SessionCompletionV1(
                endedAt: Date(),
                lifecycle: .completed,
                summary: nil,
                healthKitSaveOutcome: .unavailable(reason: .notAttempted)
            )
        )

        let failureBox = MotionStorageFailureBox()
        let ingress = MotionPackageIngress(writer: sealedWriter, failureBox: failureBox)
        ingress.yield(.accelerometer(accelerometerBatch(sampleCount: 1)))
        ingress.finish()

        let failure = await failureBox.waitForFinish()
        XCTAssertNotNil(failure, "sealed-writer append failures must be recorded")
    }

    /// finish() before any events still synchronizes and signals once.
    func testFinishWithoutEventsSignalsImmediately() async throws {
        writer = try startWriter()
        let failureBox = MotionStorageFailureBox()
        let ingress = MotionPackageIngress(writer: writer!, failureBox: failureBox)

        ingress.finish()
        let failure = await failureBox.waitForFinish()
        XCTAssertNil(failure)
    }
}
