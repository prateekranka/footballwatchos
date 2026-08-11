# Select the Watch-to-iPhone Sync and Storage Architecture

Type: research
Status: resolved
Blocked by: none
Part of: [Personal Apple Watch Football Performance System](../map.md)

## Question

Which single Watch-to-iPhone transfer and storage architecture satisfies fully offline Watch recording, delayed and retryable sync, local iPhone analysis, private app storage with an explicitly bounded iCloud role, raw R&D retention, full-resolution export, crash recovery, and no application server—and why are the rejected alternatives inferior?

## Resolution

Use a Watch-owned, file-backed outbox containing one immutable, checksummed
`.footysession` package per completed session. Recording and sealing are fully
offline. When WatchConnectivity is activated and the companion is installed,
the Watch submits the retained package with `transferFile`; reachability never
gates recording or enqueueing.

The iPhone synchronously moves the temporary delivery into its own incoming
directory, validates the package version, byte count, canonical session UUID,
completion frame, and SHA-256 digest, then performs an idempotent import into a
private file vault with an atomically written JSON index. Duplicate bytes are a
no-op; conflicting bytes for the same session UUID are quarantined. Startup
reconciliation repairs the index and resumes staged imports.

Framework delivery completion is not import proof. Only a durable iPhone
receipt matching both session UUID and digest changes the Watch state to
Imported. The Watch retains its package until an explicit later deletion.
iPhone deletion writes a tombstone first so delayed duplicate delivery cannot
silently resurrect the local copy. Export shares the exact validated package
bytes.

No account, app server, CloudKit, iCloud container, SwiftData dependency, or
network service is part of v1. Immediate messaging, latest-value application
context, cloud databases, and an iPhone-first recorder were rejected because
they weaken delayed/offline delivery, evidence retention, or the confirmed
Watch-first boundary.

## Evidence

- [Primary-source architecture research](../research/05-sync-storage-architecture.md)
- `Sources/Shared/SessionFoundation/FootySessionPackageV1.swift`
- `Sources/Shared/SessionFoundation/SessionTransferV1.swift`
- `Sources/Watch/Sync/WatchTransferOutbox.swift`
- `Sources/Watch/Sync/WatchSyncCoordinator.swift`
- `Sources/iOS/Storage/FileSessionRepository.swift`
- `Sources/iOS/Sync/PhoneWatchConnectivityCoordinator.swift`
- Focused package/import tests: 14 passed
- Focused Watch receipt-state tests: 2 passed

Real paired-device transfer timing and retry behavior remain physical proof
work under the foundation gates; they do not reopen this architecture decision.
