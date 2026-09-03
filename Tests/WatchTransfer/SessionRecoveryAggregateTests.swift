import Foundation
import XCTest
@testable import FootballPerformanceWatch

final class SessionRecoveryAggregateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func partial(_ sessionID: UUID) -> StoredSessionPackageV1 {
        StoredSessionPackageV1(
            filename: "\(sessionID.uuidString).partial",
            kind: .partial,
            byteCount: 4096
        )
    }

    private func recovered(_ sessionID: UUID) -> StoredSessionPackageV1 {
        StoredSessionPackageV1(
            filename: "\(sessionID.uuidString).recovered.\(UUID().uuidString).footysession",
            kind: .sealed,
            byteCount: 4096
        )
    }

    private func completed(_ sessionID: UUID) -> StoredSessionPackageV1 {
        StoredSessionPackageV1(
            filename: "\(sessionID.uuidString).footysession",
            kind: .sealed,
            byteCount: 4096
        )
    }

    private func record(
        sessionID: UUID,
        status: WatchTransferOutboxStatusV1,
        digestSeed: UInt8
    ) -> WatchTransferOutboxRecordV1 {
        let envelope = SessionTransferEnvelopeV1(
            sessionID: sessionID,
            packageDigest: SessionDigestV1(bytes: Data(repeating: digestSeed, count: 32)),
            byteCount: 4096,
            createdAt: now
        )
        var record = WatchTransferOutboxRecordV1(
            transferEnvelope: envelope,
            packageFilename: "\(sessionID.uuidString).footysession",
            now: now
        )
        record.status = status
        return record
    }

    func testNoSessionsProducesEmptyAggregate() {
        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: [],
            outboxRecords: []
        )

        XCTAssertEqual(aggregate.interruptedCount, 0)
        XCTAssertEqual(aggregate.needsRecoveryCount, 0)
        XCTAssertEqual(aggregate.recoveredCount, 0)
        XCTAssertEqual(aggregate.sourceSessionCount, 0)
        XCTAssertEqual(aggregate.waitingForIPhoneCount, 0)
        XCTAssertEqual(aggregate.importedCount, 0)
        XCTAssertEqual(aggregate.needsAttentionCount, 0)
        // An empty universe has nothing transferred, so it never claims the
        // all-complete banner.
        XCTAssertFalse(aggregate.allSessionsTransferred)
        XCTAssertFalse(aggregate.attentionRequired)
    }

    func testPartialWithoutRecoveredCopyNeedsRecovery() {
        let sessionID = UUID()
        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: [partial(sessionID)],
            outboxRecords: []
        )

        XCTAssertEqual(aggregate.interruptedCount, 1)
        XCTAssertEqual(aggregate.needsRecoveryCount, 1)
        XCTAssertEqual(aggregate.recoveredCount, 0)
        XCTAssertEqual(aggregate.sourceSessionCount, 1)
        XCTAssertEqual(aggregate.waitingForIPhoneCount, 0)
        XCTAssertEqual(aggregate.importedCount, 0)
        XCTAssertEqual(aggregate.needsAttentionCount, 0)
        XCTAssertFalse(aggregate.allSessionsTransferred)
        XCTAssertTrue(aggregate.attentionRequired)
    }

    func testRecoveredSessionWithPendingRecordWaitsForIPhone() {
        let sessionID = UUID()
        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: [partial(sessionID), recovered(sessionID)],
            outboxRecords: [
                record(sessionID: sessionID, status: .pending, digestSeed: 0x01),
            ]
        )

        XCTAssertEqual(aggregate.needsRecoveryCount, 0)
        XCTAssertEqual(aggregate.recoveredCount, 1)
        XCTAssertEqual(aggregate.sourceSessionCount, 1)
        XCTAssertEqual(aggregate.waitingForIPhoneCount, 1)
        XCTAssertEqual(aggregate.importedCount, 0)
        XCTAssertEqual(aggregate.needsAttentionCount, 0)
        XCTAssertFalse(aggregate.allSessionsTransferred)
    }

    func testQueuedRecordCountsAsWaitingForIPhone() {
        let sessionID = UUID()
        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: [partial(sessionID), recovered(sessionID)],
            outboxRecords: [
                record(sessionID: sessionID, status: .queued, digestSeed: 0x02),
            ]
        )

        XCTAssertEqual(aggregate.waitingForIPhoneCount, 1)
        XCTAssertEqual(aggregate.importedCount, 0)
        XCTAssertFalse(aggregate.allSessionsTransferred)
    }

    func testWaitingForReceiptCountsAsWaitingForIPhone() {
        let sessionID = UUID()
        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: [partial(sessionID), recovered(sessionID)],
            outboxRecords: [
                record(sessionID: sessionID, status: .waitingForReceipt, digestSeed: 0x03),
            ]
        )

        XCTAssertEqual(aggregate.waitingForIPhoneCount, 1)
        XCTAssertEqual(aggregate.importedCount, 0)
        XCTAssertFalse(aggregate.allSessionsTransferred)
    }

    func testRetryableFailureNeedsAttention() {
        let sessionID = UUID()
        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: [partial(sessionID), recovered(sessionID)],
            outboxRecords: [
                record(sessionID: sessionID, status: .retryableFailure, digestSeed: 0x04),
            ]
        )

        XCTAssertEqual(aggregate.waitingForIPhoneCount, 0)
        XCTAssertEqual(aggregate.importedCount, 0)
        XCTAssertEqual(aggregate.needsAttentionCount, 1)
        XCTAssertFalse(aggregate.allSessionsTransferred)
        XCTAssertTrue(aggregate.attentionRequired)
    }

    func testImportedReceiptCompletesTheSession() {
        let sessionID = UUID()
        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: [partial(sessionID), recovered(sessionID)],
            outboxRecords: [
                record(sessionID: sessionID, status: .imported, digestSeed: 0x05),
            ]
        )

        XCTAssertEqual(aggregate.waitingForIPhoneCount, 0)
        XCTAssertEqual(aggregate.importedCount, 1)
        XCTAssertEqual(aggregate.needsAttentionCount, 0)
        XCTAssertTrue(aggregate.allSessionsTransferred)
        XCTAssertFalse(aggregate.attentionRequired)
    }

    func testDuplicateRecoveredCopiesAndRecordsCountAsOneSession() {
        let sessionID = UUID()
        // Two historical recovery runs produced two recovered copies, and the
        // outbox holds two digest-distinct records for the same sessionID.
        let discovered = [
            partial(sessionID),
            recovered(sessionID),
            recovered(sessionID),
        ]
        let records = [
            record(sessionID: sessionID, status: .pending, digestSeed: 0x11),
            record(sessionID: sessionID, status: .imported, digestSeed: 0x12),
        ]
        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: discovered,
            outboxRecords: records
        )

        XCTAssertEqual(aggregate.interruptedCount, 1)
        XCTAssertEqual(aggregate.recoveredCount, 1)
        XCTAssertEqual(aggregate.sourceSessionCount, 1)
        XCTAssertEqual(aggregate.waitingForIPhoneCount, 0)
        XCTAssertEqual(aggregate.importedCount, 1)
        XCTAssertEqual(aggregate.needsAttentionCount, 0)
        XCTAssertTrue(aggregate.allSessionsTransferred)

        // Both records still pending: still one unique session waiting.
        let pendingOnly = SessionRecoveryAggregateV1.compute(
            discovered: discovered,
            outboxRecords: [
                record(sessionID: sessionID, status: .queued, digestSeed: 0x13),
                record(sessionID: sessionID, status: .waitingForReceipt, digestSeed: 0x14),
            ]
        )
        XCTAssertEqual(pendingOnly.recoveredCount, 1)
        XCTAssertEqual(pendingOnly.waitingForIPhoneCount, 1)
        XCTAssertEqual(pendingOnly.importedCount, 0)
        XCTAssertFalse(pendingOnly.allSessionsTransferred)
    }

    func testMixedSessionsAggregateIndependently() {
        let needsRecovery = UUID()
        let waiting = UUID()
        let imported = UUID()
        let failed = UUID()
        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: [
                partial(needsRecovery),
                partial(waiting), recovered(waiting),
                partial(imported), recovered(imported),
                partial(failed), recovered(failed),
            ],
            outboxRecords: [
                record(sessionID: waiting, status: .queued, digestSeed: 0x21),
                record(sessionID: imported, status: .imported, digestSeed: 0x22),
                record(sessionID: failed, status: .retryableFailure, digestSeed: 0x23),
            ]
        )

        XCTAssertEqual(aggregate.interruptedCount, 4)
        XCTAssertEqual(aggregate.needsRecoveryCount, 1)
        XCTAssertEqual(aggregate.recoveredCount, 3)
        XCTAssertEqual(aggregate.sourceSessionCount, 4)
        XCTAssertEqual(aggregate.waitingForIPhoneCount, 1)
        XCTAssertEqual(aggregate.importedCount, 1)
        XCTAssertEqual(aggregate.needsAttentionCount, 1)
        XCTAssertFalse(aggregate.allSessionsTransferred)
    }

    func testAllCompleteRequiresEverySourceImportedAndNoUnresolvedRecovery() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        // All recovered, all imported: complete.
        let complete = SessionRecoveryAggregateV1.compute(
            discovered: [
                partial(first), recovered(first),
                partial(second), recovered(second),
            ],
            outboxRecords: [
                record(sessionID: first, status: .imported, digestSeed: 0x31),
                record(sessionID: second, status: .imported, digestSeed: 0x32),
            ]
        )
        XCTAssertTrue(complete.allSessionsTransferred)
        XCTAssertFalse(complete.attentionRequired)

        // One imported receipt missing: not complete.
        let missingReceipt = SessionRecoveryAggregateV1.compute(
            discovered: [
                partial(first), recovered(first),
                partial(second), recovered(second),
            ],
            outboxRecords: [
                record(sessionID: first, status: .imported, digestSeed: 0x31),
                record(sessionID: second, status: .waitingForReceipt, digestSeed: 0x33),
            ]
        )
        XCTAssertFalse(missingReceipt.allSessionsTransferred)

        // One session still unrecovered: not complete even with receipts.
        let unresolvedRecovery = SessionRecoveryAggregateV1.compute(
            discovered: [
                partial(first), recovered(first),
                partial(third),
            ],
            outboxRecords: [
                record(sessionID: first, status: .imported, digestSeed: 0x31),
            ]
        )
        XCTAssertFalse(unresolvedRecovery.allSessionsTransferred)
        XCTAssertEqual(unresolvedRecovery.needsRecoveryCount, 1)
    }

    func testCompletedSealedPackageIsNotARecoverySource() {
        // A normally completed session is outside the recovery universe; its
        // transfer status is shown on the Saved screen, not aggregated here.
        let sessionID = UUID()
        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: [completed(sessionID)],
            outboxRecords: [
                record(sessionID: sessionID, status: .imported, digestSeed: 0x41),
            ]
        )

        XCTAssertEqual(aggregate.interruptedCount, 0)
        XCTAssertEqual(aggregate.needsRecoveryCount, 0)
        XCTAssertEqual(aggregate.recoveredCount, 0)
        XCTAssertEqual(aggregate.sourceSessionCount, 0)
        XCTAssertEqual(aggregate.waitingForIPhoneCount, 0)
        XCTAssertEqual(aggregate.importedCount, 0)
        XCTAssertEqual(aggregate.needsAttentionCount, 0)
        XCTAssertFalse(aggregate.allSessionsTransferred)
    }

    func testProductionFilenameConventionsClassifyCorrectly() {
        // Exact representative production filenames: a partial observed on a
        // physical Watch (33029638-… partial), the recovered copy
        // WatchSessionRepository.recoverPartial writes, and a normal sealed
        // package. The aggregate must classify all three and complete when
        // the recovered session has an imported receipt.
        let sessionID = UUID(uuidString: "33029638-1111-2222-3333-444455556666")!
        let recoveryID = "9F8E7D6C-5B4A-4C3D-9E2F-1A2B3C4D5E6F"
        let partialFilename = "\(sessionID.uuidString).partial"
        let recoveredFilename = "\(sessionID.uuidString).recovered.\(recoveryID).footysession"
        let completedFilename = "\(sessionID.uuidString).footysession"

        XCTAssertEqual(SessionRecoveryFilenameV1.sessionID(from: partialFilename), sessionID)
        XCTAssertEqual(SessionRecoveryFilenameV1.sessionID(from: recoveredFilename), sessionID)
        XCTAssertEqual(SessionRecoveryFilenameV1.sessionID(from: completedFilename), sessionID)
        XCTAssertFalse(SessionRecoveryFilenameV1.isRecoveredCopy(partialFilename))
        XCTAssertTrue(SessionRecoveryFilenameV1.isRecoveredCopy(recoveredFilename))
        XCTAssertFalse(SessionRecoveryFilenameV1.isRecoveredCopy(completedFilename))

        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: [
                StoredSessionPackageV1(filename: partialFilename, kind: .partial, byteCount: 4096),
                StoredSessionPackageV1(filename: recoveredFilename, kind: .sealed, byteCount: 4096),
                StoredSessionPackageV1(filename: completedFilename, kind: .sealed, byteCount: 4096),
            ],
            outboxRecords: [
                record(sessionID: sessionID, status: .imported, digestSeed: 0x51),
            ]
        )

        XCTAssertEqual(aggregate.interruptedCount, 1)
        XCTAssertEqual(aggregate.needsRecoveryCount, 0)
        XCTAssertEqual(aggregate.recoveredCount, 1)
        XCTAssertEqual(aggregate.sourceSessionCount, 1)
        XCTAssertEqual(aggregate.waitingForIPhoneCount, 0)
        XCTAssertEqual(aggregate.importedCount, 1)
        XCTAssertEqual(aggregate.needsAttentionCount, 0)
        XCTAssertTrue(aggregate.allSessionsTransferred)
        XCTAssertFalse(aggregate.attentionRequired)
    }

    func testUnparseableFilenamesAreIgnored() {
        // "orphan.recovered.zzz.footysession" is the real recovered shape with
        // a non-UUID recovery token, and the 5-component
        // "<uuid>.footysession.recovered.<uuid>.footysession" alternate was
        // never written by production — both must stay unrecognized.
        let aggregate = SessionRecoveryAggregateV1.compute(
            discovered: [
                StoredSessionPackageV1(filename: "orphan.partial", kind: .partial, byteCount: 1),
                StoredSessionPackageV1(filename: "garbage.footysession", kind: .sealed, byteCount: 1),
                StoredSessionPackageV1(filename: "orphan.recovered.zzz.footysession", kind: .sealed, byteCount: 1),
                StoredSessionPackageV1(
                    filename: "33029638-1111-2222-3333-444455556666.footysession.recovered.9F8E7D6C-5B4A-4C3D-9E2F-1A2B3C4D5E6F.footysession",
                    kind: .sealed,
                    byteCount: 1
                ),
            ],
            outboxRecords: []
        )

        XCTAssertEqual(aggregate.interruptedCount, 0)
        XCTAssertEqual(aggregate.recoveredCount, 0)
        XCTAssertEqual(aggregate.sourceSessionCount, 0)
        XCTAssertFalse(aggregate.allSessionsTransferred)
    }
}
