import Foundation
import Testing
@testable import FootballPerformance

@Suite("Manual sessions")
struct ManualSessionTests {
    @Test("manual logs persist, export exactly, and contain no sensor evidence or Watch receipt")
    func durableManualLog() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = FileSessionRepository.Configuration(rootDirectory: directory)
        let repository = try FileSessionRepository(configuration: configuration)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let draft = ManualSessionDraft(startedAt: now.addingTimeInterval(-86_400), durationMinutes: 90, sessionType: .elevenASide)
        let record = try await repository.addManualSession(draft, now: now)
        #expect(record.isManualEntry)
        #expect(record.sessionEnvelope.footballType == .elevenASide)
        #expect(record.completion.summary?.duration?.value == 5_400)
        #expect(record.completion.summary?.distance == nil)
        #expect(record.completion.summary?.averageHeartRate == nil)
        #expect(!BaselineEngineV1.isValidSession(record))
        let restarted = try FileSessionRepository(configuration: configuration)
        try await restarted.reconcileOnStartup()
        #expect(await restarted.sessions() == [record])
        #expect(await restarted.durableReceiptPayloads().isEmpty)
        let detail = try await restarted.detail(for: record.sessionID)
        #expect(detail.heartRateSnapshots.isEmpty)
        #expect(detail.distanceSnapshots.isEmpty)
        #expect(detail.accelerometerSamples.isEmpty)
        let export = try await restarted.verifiedExportURL(for: record.sessionID)
        let inspection = try SessionTransferCodecV1.inspectCompletePackage(at: export)
        #expect(inspection.transferEnvelope.packageDigest == record.packageDigest)
    }

    @Test("duration bounds and sessions ending in the future are rejected")
    func validation() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for minutes in [0, -1, 241, Int.max] {
            #expect(throws: ManualSessionDraft.ValidationError.self) {
                try ManualSessionDraft(startedAt: now.addingTimeInterval(-86_400), durationMinutes: minutes, sessionType: .training).validate(now: now)
            }
        }
        for minutes in [1, 240] {
            try ManualSessionDraft(startedAt: now.addingTimeInterval(-86_400), durationMinutes: minutes, sessionType: .calibration).validate(now: now)
        }
        #expect(throws: ManualSessionDraft.ValidationError.self) {
            try ManualSessionDraft(startedAt: now, durationMinutes: 1, sessionType: .football).validate(now: now)
        }
    }

    @Test("legacy envelopes remain readable when the session type key is absent")
    func legacyEnvelope() throws {
        let envelope = SessionEnvelopeV1(
            sessionID: UUID(), createdAt: .now, startedAt: .now,
            captureSource: .foregroundFallback,
            initialAccelerometerAvailability: .available,
            initialDeviceMotionAvailability: .available
        )
        let data = try JSONEncoder().encode(envelope)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["sessionType"] == nil)
        let decoded = try JSONDecoder().decode(SessionEnvelopeV1.self, from: data)
        #expect(decoded == envelope)
        #expect(decoded.footballType == .football)
    }
}
