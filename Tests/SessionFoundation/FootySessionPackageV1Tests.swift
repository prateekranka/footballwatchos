import Foundation
import Testing
@testable import FootballPerformance

@Suite("FootySessionPackageV1")
struct FootySessionPackageV1Tests {
    @Test("completed packages round-trip exactly")
    func completedRoundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let envelope = fixtureEnvelope()
        let completed = SessionCompletionV1(
            endedAt: fixtureDate.addingTimeInterval(90),
            lifecycle: .completed,
            summary: SessionSummaryMetricsV1(
                duration: SessionMetricV1(
                    value: 90,
                    unit: .seconds,
                    provenance: .healthKitFinalWorkout
                ),
                distance: SessionMetricV1(
                    value: 123.4,
                    unit: .meters,
                    provenance: .healthKitFinalWorkout
                )
            ),
            healthKitSaveOutcome: .saved(workoutUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        )
        let frames = [
            FootySessionFrameV1(payload: .envelope(envelope)),
            FootySessionFrameV1(payload: .heartRateSnapshot(
                HeartRateSnapshotV1(
                    timestamp: fixtureDate.addingTimeInterval(30),
                    beatsPerMinute: SessionMetricV1(
                        value: 142,
                        unit: .beatsPerMinute,
                        provenance: .healthKitLive
                    )
                )
            )),
            FootySessionFrameV1(payload: .completion(completed)),
        ]
        let url = directory.appendingPathComponent("completed.footysession")

        try FootySessionPackageV1.writePackage(frames: frames, to: url)
        let read = try FootySessionPackageV1.read(from: url)

        #expect(read.status == .complete)
        #expect(read.hasVerifiedCompletion)
        #expect(read.frames == frames)
        let digest = try FootySessionPackageV1.digest(of: url)
        #expect(read.wholeFileDigest == digest)
    }

    @Test("a torn tail recovers only the verified prefix")
    func tornTailValidPrefixRecovery() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let envelope = fixtureEnvelope()
        let originalURL = directory.appendingPathComponent("capture.partial")
        try FootySessionPackageV1.writePackage(
            frames: [
                FootySessionFrameV1(payload: .envelope(envelope)),
                FootySessionFrameV1(payload: .completion(interruptedCompletion())),
            ],
            to: originalURL
        )
        var bytes = try Data(contentsOf: originalURL)
        bytes.removeLast(8)
        try bytes.write(to: originalURL, options: .atomic)

        let prefix = try FootySessionPackageV1.read(from: originalURL)
        #expect(prefix.status == .tornTail)
        #expect(prefix.frames == [FootySessionFrameV1(payload: .envelope(envelope))])

        let recoveredURL = directory.appendingPathComponent("recovered.footysession")
        try FootySessionPackageV1.writePackage(
            frames: prefix.frames + [FootySessionFrameV1(payload: .completion(interruptedCompletion()))],
            to: recoveredURL
        )
        let recovered = try FootySessionPackageV1.read(from: recoveredURL)
        #expect(recovered.status == .complete)
        #expect(recovered.frames.count == 2)
        guard case let .completion(completion) = recovered.frames[1].payload else {
            Issue.record("Expected a recovered completion frame")
            return
        }
        #expect(completion.lifecycle == .interrupted(reason: .partialFileRecovery))
    }

    @Test("a frame with a bad SHA-256 is rejected")
    func corruptFrameIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("corrupt.footysession")
        try FootySessionPackageV1.writePackage(
            frames: [FootySessionFrameV1(payload: .envelope(fixtureEnvelope()))],
            to: url
        )
        var bytes = try Data(contentsOf: url)
        bytes[bytes.index(before: bytes.endIndex)] ^= 0xFF
        try bytes.write(to: url, options: .atomic)

        #expect(throws: SessionPackageError.self) {
            try FootySessionPackageV1.read(from: url)
        }
    }

    @Test("an unknown package version fails closed")
    func unknownVersionFailsClosed() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("future.footysession")
        try FootySessionPackageV1.writePackage(
            frames: [FootySessionFrameV1(payload: .envelope(fixtureEnvelope()))],
            to: url
        )
        var bytes = try Data(contentsOf: url)
        bytes[8] = 0
        bytes[9] = 0
        bytes[10] = 0
        bytes[11] = 2
        try bytes.write(to: url, options: .atomic)

        #expect(throws: SessionPackageError.self) {
            try FootySessionPackageV1.read(from: url)
        }
    }

    @Test("missing streams retain their unavailable state")
    func missingStreamIsUnavailableRatherThanZero() throws {
        let diagnostics = CaptureDiagnosticsV1(
            recordedAt: fixtureDate,
            source: .unavailable(reason: .hardwareUnsupported),
            accelerometerAvailability: .unavailable(reason: .hardwareUnsupported),
            deviceMotionAvailability: .insufficient(reason: .noSamples),
            accelerometerSampleCount: 0,
            deviceMotionSampleCount: 0
        )
        let encoded = try PropertyListEncoder().encode(diagnostics)
        let decoded = try PropertyListDecoder().decode(CaptureDiagnosticsV1.self, from: encoded)

        #expect(decoded.accelerometerAvailability == .unavailable(reason: .hardwareUnsupported))
        #expect(decoded.deviceMotionAvailability == .insufficient(reason: .noSamples))
        #expect(SessionSummaryMetricsV1().averageHeartRate == nil)
        #expect(SessionSummaryMetricsV1().distance == nil)
    }

    @Test("capture diagnostics carry per-stream delivery stats")
    func captureDiagnosticsCarryPerStreamStats() throws {
        let diagnostics = CaptureDiagnosticsV1(
            recordedAt: fixtureDate,
            source: .batchedCoreMotion,
            accelerometerAvailability: .available,
            deviceMotionAvailability: .available,
            accelerometerSampleCount: 12_300,
            deviceMotionSampleCount: 11_900,
            accelerometerReportedHz: 50,
            deviceMotionReportedHz: 25,
            accelerometerBatchCount: 41,
            deviceMotionBatchCount: 39,
            accelerometerLastError: nil,
            deviceMotionLastError: "Device-motion stream ended early.",
            maximumObservedGap: 0.32
        )
        let encoded = try PropertyListEncoder().encode(diagnostics)
        let decoded = try PropertyListDecoder().decode(CaptureDiagnosticsV1.self, from: encoded)

        #expect(decoded.accelerometerReportedHz == 50)
        #expect(decoded.deviceMotionReportedHz == 25)
        #expect(decoded.accelerometerBatchCount == 41)
        #expect(decoded.deviceMotionBatchCount == 39)
        #expect(decoded.accelerometerLastError == nil)
        #expect(decoded.deviceMotionLastError == "Device-motion stream ended early.")
        #expect(decoded.maximumObservedGap == 0.32)
    }

    @Test("diagnostics sealed before the per-stream fields still decode")
    func legacyDiagnosticsDecodeWithDefaults() throws {
        // Encode the exact pre-extension shape through a mirror struct with
        // synthesized Codable, so the fixture matches what earlier builds wrote.
        let legacy = LegacyCaptureDiagnosticsV1(
            recordedAt: fixtureDate,
            source: .batchedCoreMotion,
            accelerometerAvailability: .available,
            deviceMotionAvailability: .available,
            accelerometerSampleCount: 9_000,
            deviceMotionSampleCount: 8_800,
            maximumObservedGap: 0.25
        )
        let data = try PropertyListEncoder().encode(legacy)
        let decoded = try PropertyListDecoder().decode(CaptureDiagnosticsV1.self, from: data)

        #expect(decoded.source == .batchedCoreMotion)
        #expect(decoded.accelerometerSampleCount == 9_000)
        #expect(decoded.deviceMotionSampleCount == 8_800)
        #expect(decoded.maximumObservedGap == 0.25)
        #expect(decoded.accelerometerReportedHz == nil)
        #expect(decoded.deviceMotionReportedHz == nil)
        #expect(decoded.accelerometerBatchCount == 0)
        #expect(decoded.deviceMotionBatchCount == 0)
        #expect(decoded.accelerometerLastError == nil)
        #expect(decoded.deviceMotionLastError == nil)
    }

    @Test("the whole-file digest is stable for identical bytes")
    func digestIsStable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let frames = [
            FootySessionFrameV1(payload: .envelope(fixtureEnvelope())),
            FootySessionFrameV1(payload: .completion(interruptedCompletion())),
        ]
        let first = directory.appendingPathComponent("one.footysession")
        let second = directory.appendingPathComponent("two.footysession")
        try FootySessionPackageV1.writePackage(frames: frames, to: first)
        try FootySessionPackageV1.writePackage(frames: frames, to: second)

        let firstDigest = try FootySessionPackageV1.digest(of: first)
        let secondDigest = try FootySessionPackageV1.digest(of: second)
        #expect(firstDigest == secondDigest)
    }

    private let fixtureDate = Date(timeIntervalSinceReferenceDate: 123_456)

    /// Mirrors the pre-extension CaptureDiagnosticsV1 shape exactly, including
    /// the synthesized Codable behavior, to produce a legacy-format fixture.
    private struct LegacyCaptureDiagnosticsV1: Codable {
        let recordedAt: Date
        let source: MotionCaptureSourceV1
        let accelerometerAvailability: StreamAvailabilityV1
        let deviceMotionAvailability: StreamAvailabilityV1
        let accelerometerSampleCount: Int
        let deviceMotionSampleCount: Int
        let maximumObservedGap: TimeInterval?
    }

    private func fixtureEnvelope() -> SessionEnvelopeV1 {
        SessionEnvelopeV1(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: fixtureDate,
            startedAt: fixtureDate,
            captureSource: .batchedCoreMotion,
            initialAccelerometerAvailability: .available,
            initialDeviceMotionAvailability: .available
        )
    }

    private func interruptedCompletion() -> SessionCompletionV1 {
        SessionCompletionV1(
            endedAt: fixtureDate.addingTimeInterval(30),
            lifecycle: .interrupted(reason: .partialFileRecovery),
            summary: nil,
            healthKitSaveOutcome: .unavailable(reason: .notAttempted)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FootySessionPackageV1Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
