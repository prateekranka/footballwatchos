import Foundation

/// Parses a repository filename into its original session identity.
///
/// Recovery deliberately preserves each original `.partial`, so a partial file
/// alone never means a session is unrecovered forever. A source session is
/// recovered when a matching `<stem>.recovered.<uuid>.footysession` copy
/// exists. Every repository filename begins with the original session UUID:
///
///     <uuid>.partial
///     <uuid>.recovered.<recovery-uuid>.footysession
///     <uuid>.footysession
///
/// Aggregation always keys on that original session UUID — never on recovered
/// filenames or package digests — so repeated historical recovered copies
/// cannot inflate session counts.
enum SessionRecoveryFilenameV1 {
    static func sessionID(from filename: String) -> UUID? {
        guard let first = filename.split(separator: ".").first else { return nil }
        return UUID(uuidString: String(first))
    }

    /// Positively validates the real recovered-copy format written by
    /// `WatchSessionRepository.recoverPartial`:
    /// `<sessionUUID>.recovered.<recoveryUUID>.footysession` — exactly four
    /// dot components, the literal marker at index 1, a valid recovery UUID
    /// at index 2, and the sealed package extension at the end. No alternate
    /// historical format is accepted: no production source ever wrote one.
    static func isRecoveredCopy(_ filename: String) -> Bool {
        let components = filename.split(separator: ".")
        guard components.count == 4,
              components[1] == "recovered",
              components[3] == FootySessionPackageV1.fileExtension else {
            return false
        }
        return UUID(uuidString: String(components[2])) != nil
    }
}

/// What a recovery action did to one session, for the on-screen log.
enum RecoveryOutcomeV1: String, Sendable, Equatable {
    case recovered
    case queued
    case failed
}

/// One line in the Session Recovery screen's per-session log. Carries the
/// human-readable identity (start time + recorded duration) instead of the
/// opaque package filename.
struct SessionRecoveryLogEntryV1: Sendable, Equatable, Identifiable {
    let id: UUID
    let sessionID: UUID?
    let startedAt: Date?
    let duration: TimeInterval?
    let outcome: RecoveryOutcomeV1
    /// Full descriptive line (same text a summary message would show).
    let message: String

    init(
        id: UUID = UUID(),
        sessionID: UUID? = nil,
        startedAt: Date? = nil,
        duration: TimeInterval? = nil,
        outcome: RecoveryOutcomeV1,
        message: String
    ) {
        self.id = id
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.duration = duration
        self.outcome = outcome
        self.message = message
    }
}

/// Pure, unit-testable aggregation of recovery sources and transfer facts.
///
/// Inputs are the repository's discovery list and the outbox records. Every
/// count is unique original session UUIDs. Transfer status is derived only
/// from outbox records — never from WatchConnectivity framework completion —
/// and one imported receipt is sufficient to mark a unique session imported
/// even when duplicate outbox records share its sessionID.
///
/// Per-source precedence: imported beats active transfer work, and active
/// work beats retryable failure. A session with both a waiting record and a
/// failed record is truthfully "waiting for iPhone" because the pipeline is
/// still working it.
struct SessionRecoveryAggregateV1: Sendable, Equatable {
    /// Unique sessions with a `.partial` on disk (recovered or not).
    let interruptedCount: Int
    /// Unique interrupted sessions without a `<stem>.recovered.*` copy.
    /// These need the Recover Sessions action.
    let needsRecoveryCount: Int
    /// Unique sessions with at least one recovered copy on disk.
    let recoveredCount: Int
    /// Unique sessions ever part of recovery: interrupted or recovered.
    let sourceSessionCount: Int
    /// Recovered sessions with no imported receipt and no retry-only failure.
    /// Includes recovered copies not yet enqueued for transfer.
    let waitingForIPhoneCount: Int
    /// Recovered sessions with at least one imported outbox receipt.
    let importedCount: Int
    /// Recovered sessions whose outbox records are all retryable failures.
    let needsAttentionCount: Int
    /// True only when at least one source session exists, every interrupted
    /// session is recovered, and every recovered session has an imported
    /// receipt. Never inferred from framework completion — receipts only.
    let allSessionsTransferred: Bool

    /// True when the home screen should draw attention to the recovery
    /// screen: source sessions exist and recovery/transfer work remains.
    var attentionRequired: Bool {
        sourceSessionCount > 0 && !allSessionsTransferred
    }

    static func compute(
        discovered: [StoredSessionPackageV1],
        outboxRecords: [WatchTransferOutboxRecordV1]
    ) -> SessionRecoveryAggregateV1 {
        var interrupted = Set<UUID>()
        var recovered = Set<UUID>()
        for package in discovered {
            guard let sessionID = SessionRecoveryFilenameV1.sessionID(from: package.filename) else {
                continue
            }
            switch package.kind {
            case .partial:
                interrupted.insert(sessionID)
            case .sealed:
                if SessionRecoveryFilenameV1.isRecoveredCopy(package.filename) {
                    recovered.insert(sessionID)
                }
            }
        }

        var imported = Set<UUID>()
        var active = Set<UUID>()
        var failed = Set<UUID>()
        for record in outboxRecords {
            switch record.status {
            case .imported:
                imported.insert(record.key.sessionID)
            case .pending, .queued, .waitingForReceipt:
                active.insert(record.key.sessionID)
            case .retryableFailure:
                failed.insert(record.key.sessionID)
            }
        }

        // Only recovered sessions enter the transfer buckets. An unrecovered
        // partial counts solely against needsRecoveryCount.
        let importedSources = recovered.intersection(imported)
        let waitingSources = recovered.subtracting(imported).filter { sessionID in
            active.contains(sessionID) || !failed.contains(sessionID)
        }
        let attentionSources = recovered
            .subtracting(imported)
            .subtracting(active)
            .intersection(failed)

        let sources = interrupted.union(recovered)
        let needsRecovery = interrupted.subtracting(recovered)
        let allComplete = !sources.isEmpty
            && needsRecovery.isEmpty
            && recovered.isSubset(of: imported)

        return SessionRecoveryAggregateV1(
            interruptedCount: interrupted.count,
            needsRecoveryCount: needsRecovery.count,
            recoveredCount: recovered.count,
            sourceSessionCount: sources.count,
            waitingForIPhoneCount: waitingSources.count,
            importedCount: importedSources.count,
            needsAttentionCount: attentionSources.count,
            allSessionsTransferred: allComplete
        )
    }
}
