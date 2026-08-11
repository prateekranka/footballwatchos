import Foundation
import Testing
@testable import FootballPerformance

@Suite("WatchDiagnosticTransferV1")
struct WatchDiagnosticTransferV1Tests {
    @Test("a valid report and receipt round trip through the shared codec")
    func roundTrip() throws {
        let now = Date(timeIntervalSinceReferenceDate: 123_456)
        let report = WatchDiagnosticReportV1(
            reportID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            attemptID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            kind: .unexpectedPriorInterruption,
            createdAt: now,
            detectedAt: now.addingTimeInterval(10),
            appVersion: "1.0.1",
            buildNumber: "6",
            operatingSystemVersion: "watchOS 26.5",
            checkpoints: [
                .init(sequence: 0, timestamp: now, code: "start_attempt_created"),
                .init(sequence: 1, timestamp: now.addingTimeInterval(1), code: "health_start_requested"),
            ]
        )

        let decoded = try WatchDiagnosticTransferCodecV1.decodeReport(
            WatchDiagnosticTransferCodecV1.encodeReport(report)
        )
        #expect(decoded == report)

        let receipt = WatchDiagnosticReceiptV1(reportID: report.reportID, acknowledgedAt: now)
        #expect(
            try WatchDiagnosticTransferCodecV1.decodeReceipt(
                WatchDiagnosticTransferCodecV1.encodeReceipt(receipt)
            ) == receipt
        )
    }

    @Test("the codec rejects an empty checkpoint report")
    func invalidReport() {
        let report = WatchDiagnosticReportV1(
            attemptID: UUID(),
            kind: .unexpectedPriorInterruption,
            createdAt: Date(),
            detectedAt: Date(),
            appVersion: "1.0.1",
            buildNumber: "6",
            operatingSystemVersion: "watchOS 26.5",
            checkpoints: []
        )

        #expect(throws: WatchDiagnosticTransferErrorV1.invalidReport) {
            try WatchDiagnosticTransferCodecV1.encodeReport(report)
        }
    }
}
