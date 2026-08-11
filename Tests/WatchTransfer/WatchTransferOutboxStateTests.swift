import Foundation
import XCTest
@testable import FootballPerformanceWatch

final class WatchTransferOutboxStateTests: XCTestCase {
    func testReceiptImportsOnlyTheMatchingSessionAndDigest() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let digest = SessionDigestV1(bytes: Data(repeating: 0x11, count: 32))
        let envelope = SessionTransferEnvelopeV1(
            sessionID: sessionID,
            packageDigest: digest,
            byteCount: 512,
            createdAt: now
        )
        var state = WatchTransferOutboxStateV1()
        let record = try state.enqueue(
            transferEnvelope: envelope,
            packageFilename: "\(sessionID.uuidString).footysession",
            now: now
        )

        let wrongReceipt = SyncReceiptV1(
            receiptID: UUID(),
            sessionID: sessionID,
            packageDigest: SessionDigestV1(bytes: Data(repeating: 0x22, count: 32)),
            acknowledgedAt: now,
            destination: "iPhone"
        )
        XCTAssertFalse(state.recordReceipt(wrongReceipt, now: now))
        XCTAssertEqual(state.record(for: record.key)?.status, .pending)

        let matchingReceipt = SyncReceiptV1(
            receiptID: UUID(),
            sessionID: sessionID,
            packageDigest: digest,
            acknowledgedAt: now.addingTimeInterval(1),
            destination: "iPhone"
        )
        XCTAssertTrue(state.recordReceipt(matchingReceipt, now: now.addingTimeInterval(1)))
        XCTAssertEqual(state.record(for: record.key)?.status, .imported)
        XCTAssertEqual(state.record(for: record.key)?.importedAt, matchingReceipt.acknowledgedAt)
    }

    func testRetryAndFrameworkCompletionRemainDistinctFromImportProof() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let digest = SessionDigestV1(bytes: Data(repeating: 0x33, count: 32))
        let envelope = SessionTransferEnvelopeV1(
            sessionID: sessionID,
            packageDigest: digest,
            byteCount: 256,
            createdAt: now
        )
        var state = WatchTransferOutboxStateV1()
        let record = try state.enqueue(
            transferEnvelope: envelope,
            packageFilename: "\(sessionID.uuidString).footysession",
            now: now
        )

        XCTAssertEqual(state.claimRecordsForTransfer(now: now).map(\.key), [record.key])
        XCTAssertEqual(state.record(for: record.key)?.status, .queued)
        XCTAssertEqual(state.record(for: record.key)?.attemptCount, 1)

        state.recordFrameworkCompletion(
            for: record.key,
            errorDescription: "Counterpart unavailable",
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(state.record(for: record.key)?.status, .retryableFailure)

        _ = state.claimRecordsForTransfer(now: now.addingTimeInterval(2))
        XCTAssertEqual(state.record(for: record.key)?.attemptCount, 2)
        state.recordFrameworkCompletion(
            for: record.key,
            errorDescription: nil,
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(state.record(for: record.key)?.status, .waitingForReceipt)
        XCTAssertNil(state.record(for: record.key)?.importedAt)
    }
}
