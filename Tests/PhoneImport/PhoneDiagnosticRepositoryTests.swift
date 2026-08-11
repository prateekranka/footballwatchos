import Foundation
import Testing
@testable import FootballPerformance

@Suite("PhoneDiagnosticRepository")
struct PhoneDiagnosticRepositoryTests {
    @Test("a report persists idempotently and keeps its durable receipt")
    func durableIdempotentStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneDiagnosticTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = makeReport()
        let firstRepository = try PhoneDiagnosticRepository(rootDirectory: root)
        let firstPayload = try await firstRepository.store(
            report,
            acknowledgedAt: Date(timeIntervalSinceReferenceDate: 200_000)
        )
        let duplicatePayload = try await firstRepository.store(report)
        #expect(firstPayload == duplicatePayload)
        #expect(await firstRepository.reports() == [report])

        let reopened = try PhoneDiagnosticRepository(rootDirectory: root)
        #expect(await reopened.reports() == [report])
        #expect(await reopened.durableReceiptPayloads() == [firstPayload])
        #expect(try WatchDiagnosticTransferCodecV1.decodeReceipt(firstPayload).reportID == report.reportID)
    }

    private func makeReport() -> WatchDiagnosticReportV1 {
        let now = Date(timeIntervalSinceReferenceDate: 199_000)
        return WatchDiagnosticReportV1(
            reportID: UUID(uuidString: "AAAAAAAA-1111-2222-3333-BBBBBBBBBBBB")!,
            attemptID: UUID(uuidString: "CCCCCCCC-4444-5555-6666-DDDDDDDDDDDD")!,
            kind: .unexpectedPriorInterruption,
            createdAt: now,
            detectedAt: now.addingTimeInterval(5),
            appVersion: "1.0.1",
            buildNumber: "6",
            operatingSystemVersion: "watchOS 26.5",
            checkpoints: [
                .init(sequence: 0, timestamp: now, code: "start_attempt_created"),
                .init(sequence: 1, timestamp: now.addingTimeInterval(1), code: "health_start_requested"),
            ]
        )
    }
}
