# Watch-first offline sync and storage architecture

**Final v1 foundation decision:** make the Watch the recorder and initial system
of record, with a file-backed **Outbox** on the Watch. Seal each finished
Football Session into one versioned, checksummed, append-only `.footysession`
package; send it with `WCSession.transferFile`; import it idempotently on the
iPhone into a local raw-file vault plus an atomically written JSON index; and
retain the Watch copy until the Watch receives a durable, application-level
import receipt from the iPhone. This is deliberately **at-least-once transport
plus idempotent local import**, rather than claiming an end-to-end exactly-once
facility that Watch Connectivity does not document.

The multi-artifact manifest and SwiftData catalog discussed below remain a
future scaling option, not the selected foundation. One immutable package keeps
the first implementation smaller while preserving raw frames, strict version
validation, SHA-256 integrity, torn-tail recovery, exact-byte export, and a
clear migration boundary if physical sessions outgrow the measured transport
envelope.

This suits a personal Series 8 recorder that may spend a 90-minute session
without its iPhone: recording and sealing require no connectivity; sync may
happen later. It uses no account, app server, CloudKit processing, or cloud
storage. The iPhone is the local report/analysis owner after a verified import,
while the Watch remains independently useful even if the companion app is not
installed.

All current Apple sources below describe the Watch Connectivity API generally;
they are not a claim of real-device proof on the stated iOS/watchOS 26 targets.

## Why this transport

Both targets must configure a `WCSession` delegate and activate their own
session. A transfer can be initiated only while its session is activated. When
only one counterpart is active, context updates and file transfers may be
delivered opportunistically in the background. [Apple: `WCSession` overview](https://developer.apple.com/documentation/watchconnectivity/wcsession)

| API | What Apple documents | v1 use / decision |
|---|---|---|
| `transferFile(_:metadata:)` | Asynchronous background file transfer; the system may throttle for performance/power; metadata must be property-list values; the sender gets a finish callback with an error if delivery fails. [Apple](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile%28_%3Ametadata%3A%29) | **Primary transport.** Send a sealed manifest and each raw chunk as an independent immutable file. Keep the source until the app-level import receipt arrives. |
| `transferUserInfo(_:)` | Queues property-list dictionaries in send order; transfer continues if the sending app is suspended; sender receives success/error completion. [Apple](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo%28_%3A%29) | **Control plane only.** Use for small `importReceipt`, `delete/suppression`, or retry-status envelopes—not raw GPS/motion. It is a useful durable acknowledgment channel, not proof that a file was imported. |
| `updateApplicationContext(_:)` | Carries only the latest state: each update overwrites the previous dictionary. [Apple](https://developer.apple.com/documentation/watchconnectivity/wcsession) | Optional, non-authoritative UI hint such as `pendingSessionCount` and latest completed session ID. Never use it for a queue, receipt, or raw data. |
| `sendMessage` / `sendMessageData` | Immediate only; the counterpart must be reachable, otherwise sending errors. Reachability means the counterpart is active/running, not merely paired. [Apple: reachability](https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable) | Optional foreground-only “Sync now” feedback or progress request. It must not gate recording, enqueueing, or recovery. |
| `transferCurrentComplicationUserInfo` | iOS-to-Watch complication transfer with a complication time budget. [Apple: `WCSession`](https://developer.apple.com/documentation/watchconnectivity/wcsession) | Do not use for session sync. |

Apple documents `payloadTooLarge` for both data dictionaries **and files**, but
does not publish a numeric maximum on these API pages. Therefore this design
must chunk raw data to a conservative, measured device limit and retain the
original artifacts for retry; no fixed size should be invented in v1.
[Apple: `payloadTooLarge`](https://developer.apple.com/documentation/watchconnectivity/wcerror/code/payloadtoolarge)

### Independent Watch implications

The Watch app starts recording without the iPhone. On an independent Watch app,
`isCompanionAppInstalled` is the documented way to determine whether the paired
iPhone has installed the companion. If it is absent, or the session is not
activated, retain the sealed Outbox and show “Waiting for iPhone companion”; do
not discard data or attempt an immediate-message fallback. [Apple: `companionAppInstalled`](https://developer.apple.com/documentation/watchconnectivity/wcsession/iscompanionappinstalled)

On iPhone, implement asynchronous activation and the inactive/deactivated
delegate methods, then reactivate after deactivation. Apple requires those iOS
methods for multiple-Watch switching and says new transfers cannot be initiated
while inactive/deactivated. A one-person product need not expose multi-Watch UX,
but it must not treat a switch as a successful sync. [Apple: `WCSessionDelegate`](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate)

Delegate callbacks run serially on a background thread. Keep their work
non-UI, serialized through a storage actor/queue, and explicitly hop to the
main actor only for UI updates. [Apple: `WCSessionDelegate`](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate)

## Recommended local layout

### Watch: Codable manifest + raw files (the durable Outbox)

Use the Watch app container’s Application Support directory:

```text
Application Support/
  FootyOutbox/
    <producerInstallationID>/<sessionID>/<revision>/
      manifest.json                 # atomic commit point
      summary.json                  # compact session summary
      route-0001.ndjson             # raw, immutable chunk
      motion-0001.bin               # raw, immutable chunk
      motion-0002.bin
      outbox-state.json             # attempts / receipt state, never source truth
```

`Codable` JSON makes the session self-describing, inspectable, and individually
exportable. Raw GPS and motion stay as files, not SwiftData blobs. This is a
design choice, not a claim that SwiftData cannot store data: SwiftData persists
models through a model container and supports configurable model storage.
[Apple: preserving model data](https://developer.apple.com/documentation/swiftdata/preserving-your-apps-model-data-across-launches)

Use SwiftData **only on the iPhone** for the queryable local catalog, derived
per-second/interval series, import ledger, report annotations, and deletion
tombstones. Keep full-resolution raw bytes in iPhone Application Support files
referenced by the catalog. This divides the workload cleanly: filesystem files
are the exportable/retryable evidence, while SwiftData supports charts and
queries. Configure the local store without a CloudKit container/entitlement;
Apple notes that automatic SwiftData iCloud sync depends on a CloudKit
entitlement. [Apple: SwiftData storage configuration](https://developer.apple.com/documentation/swiftdata/preserving-your-apps-model-data-across-launches)

### Why not a Watch SwiftData-only store?

It would add a schema/migration layer to a very small write-once Outbox while
making raw-file export and artifact-level retry less direct. It is reasonable
for the iPhone’s report/catalog domain, but a manifest plus immutable files is
the simpler crash-recovery contract on the recorder. This is an architectural
tradeoff, not an Apple-imposed limitation.

### Why not CloudKit, an app server, or one giant archive?

CloudKit/server storage violates the explicit local-only boundary. One archive
would re-send all raw data after a failure and cannot accommodate the
undocumented file-size ceiling. Chunked artifacts contain any retry to the
failed portion and permit future streaming export. That retry benefit is an
engineering inference; it requires physical-device validation.

## Transfer envelope and schema

Create a random `producerInstallationID` on first Watch launch and a random
`sessionID` at Start. A finished recording never mutates its `revision`; a
reprocess/export correction creates the next revision. Use CryptoKit SHA-256
over the actual bytes. CryptoKit’s SHA-256 type is the framework’s 256-bit
SHA-2 hash implementation. [Apple: `SHA256`](https://developer.apple.com/documentation/cryptokit/sha256)

The *same* minimal envelope appears in each file-transfer metadata dictionary
(which must contain property-list values) and in `manifest.json`; metadata lets
the iPhone stage an artifact that arrives before the manifest.

```json
{
  "schema": "com.prateekranka.footy.transfer.v1",
  "producerInstallationID": "UUID",
  "sessionID": "UUID",
  "revision": 1,
  "artifactID": "motion-0002",
  "kind": "rawMotion",
  "fileName": "motion-0002.bin",
  "byteCount": 123456,
  "sha256": "lowercase-hex",
  "manifestSHA256": "lowercase-hex-or-null",
  "createdAt": "2026-07-28T12:34:56Z"
}
```

`manifest.json` adds the canonical session summary, format versions, recording
start/end, all expected artifact IDs/byte counts/digests, the chunk sequence,
and `complete: true`. It is itself transferred as `kind: manifest`; it need not
arrive first. `outbox-state.json` contains only operational fields such as
attempt count, last error code, and receipt state, so it can be rebuilt without
changing source evidence.

**Deduplication key:**

```text
producerInstallationID/sessionID/revision/artifactID/sha256
```

The iPhone additionally treats `(producerInstallationID, sessionID, revision)`
as the logical session revision key. A duplicate key with a different digest is
corruption/conflict, not a replacement. SwiftData can enforce unique attributes
or compound uniqueness, but the importer must still compare the digest and
existence of the raw file before reporting success. [Apple: `Unique`](https://developer.apple.com/documentation/swiftdata/unique%28_%3A%29)

## Crash-safe recording, enqueue, and import

### 1. Seal locally on the Watch before any transfer

1. Stream samples into a new `*.partial` artifact. At a chunk boundary/final
   save, close it, call `FileHandle.synchronize()`, calculate its SHA-256, and
   publish it under its immutable final name. `synchronize()` writes in-memory
   data and attributes to permanent storage before returning. [Apple: `FileHandle.synchronize()`](https://developer.apple.com/documentation/foundation/filehandle/synchronize%28%29)
2. Write `manifest.json` only after every listed final artifact exists and its
   byte count/digest matches. Write its `Codable` data with `.atomic`; Apple
   documents this as write-to-auxiliary followed by replacement of the original.
   The manifest is the commit record. [Apple: atomic data write](https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic)
3. On next launch, ignore `*.partial`; delete/recover them only after checking
   there is no committed manifest that references them. A final artifact without
   a manifest is an uncommitted orphan. A manifest referencing a missing or bad
   artifact is a recoverable `sealFailed` session, never an enqueue candidate.

This ordering avoids describing a partially written session as complete. It is
the app’s crash-recovery protocol; Apple does not provide a transactional
WatchConnectivity-plus-filesystem API.

### 2. Enqueue only sealed artifacts

When `activationState == .activated` and the companion is installed, submit
each unacknowledged artifact with `transferFile(finalURL, metadata: envelope)`.
The URL must be readable by the sending app. Retain every file: file transfers
are background/asynchronous and Apple exposes outstanding transfers plus
completion with error. [Apple: `transferFile`](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile%28_%3Ametadata%3A%29)

Persist an Outbox attempt before/after queuing, but do **not** use an in-memory
`WCSessionFileTransfer` object as durable truth. On a finish callback with an
error, retain the immutable source, record the error, and retry later under an
explicit policy (next activation, foreground “Sync now”, and bounded backoff).
Apple expressly describes this callback as the place to respond to errors,
including trying later. [Apple: file-transfer completion](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session%28_%3Adidfinish%3Aerror%3A%29-6dtcu)

Treat `payloadTooLarge`, `insufficientSpace`, `fileAccessDenied`, malformed
metadata, and timeout/delivery failures as visible degraded states. Do not
silently split a sealed artifact after it has failed; create a new revision with
new valid chunks so the original remains exportable and auditable. Apple lists
the corresponding `WCError` cases, including `payloadTooLarge`,
`fileAccessDenied`, `insufficientSpace`, `deliveryFailed`, and
`transferTimedOut`. [Apple: `WCError`](https://developer.apple.com/documentation/watchconnectivity/wcerror)

### 3. Stage received files synchronously on iPhone

In `session(_:didReceive:)`, immediately move `file.fileURL` to
`Application Support/FootyIncoming/<deliveryUUID>.received`, then return.
Apple says the received file is temporary and **must be moved synchronously
before the delegate method returns**, otherwise the system deletes it. The
callback is on a background thread. [Apple: receiving a file](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session%28_%3Adidreceive%3A%29)

The callback does no charting and makes no success receipt. It merely preserves
the bytes and enqueues an importer. If the process dies after the move but
before a ledger write, the next launch scans `FootyIncoming`; this is why the
incoming directory is part of recovery, not a temporary cache.

### 4. Idempotent iPhone import and receipt

For each staged delivery, a single serialized importer:

1. validates the property-list envelope and file name, computes SHA-256, and
   rejects/quarantines any mismatch;
2. upserts an `IncomingArtifact` ledger row by the deduplication key;
3. copies/moves verified bytes into
   `Application Support/FootyRaw/<producer>/<session>/<revision>/<artifactID>`;
4. waits until the manifest and every declared artifact are present and digest
   valid (arrival order is not an application dependency);
5. in one `ModelContext.transaction`, inserts/updates the session catalog,
   artifact rows, derived-analysis work item, and an `ImportReceipt` record;
   SwiftData documents that the transaction writes the pending changes after
   its closure completes; and
6. only then removes the incoming staging file and sends a small
   `transferUserInfo` receipt containing the session revision, manifest digest,
   `status: imported`, and receipt ID.

[Apple: `ModelContext.transaction`](https://developer.apple.com/documentation/swiftdata/modelcontext/transaction%28block%3A%29)

Filesystem moves and a SwiftData save are not one documented cross-store
transaction. Recovery reconciles them: raw files without a committed ledger are
re-validated and imported; ledger rows without their required raw files mark
the session `incomplete` and prevent analysis/receipt; incoming files remain
until after the successful SwiftData transaction. The sender’s successful
`didFinish` callback means Watch Connectivity finished its transfer, **not**
that this import transaction committed. The explicit receipt closes that gap.

On receiving a matching receipt, the Watch writes `receiptConfirmed` into its
atomic Outbox state. Repeated file deliveries, repeated imports, and repeated
receipts are no-ops because all use the same keys/digests. Keep receipt sending
idempotent as well: `transferUserInfo` is queue-based, not a remote database
commit.

## State machines

```text
WATCH
Recording
  -> Finalizing -> SealedLocal -> Enqueued -> AwaitingTransfer
  -> AwaitingImportReceipt -> ReceiptConfirmed -> EligibleForWatchDeletion

Finalizing/SealedLocal -> SealFailed (keep evidence, show action)
AwaitingTransfer -> RetryPending (error or no progress) -> Enqueued
Any pre-receipt state -> RetainedOffline (no companion / disconnected)

iPHONE
didReceive file -> StagedIncoming -> Verified -> ImportCommitted
  -> ReceiptQueued -> ReceiptDeliveredOrQueued

Verified -> Quarantined (schema, digest, or manifest mismatch)
ImportCommitted -> Incomplete (required artifact missing) -> Verified
```

The transport is allowed to deliver late or more than once; the only irreversible
local transition is `ImportCommitted`, which is keyed and validated. Use
`sessionReachabilityDidChange` only to improve foreground behavior; Apple says
to consult `isReachable` there and optionally choose immediate messages, not to
declare a background transfer failed. [Apple: reachability change](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/sessionreachabilitydidchange%28_%3A%29)

## Deletion and export boundary

* **Before the matching import receipt:** the Watch Outbox is the only complete
  source and cannot be automatically deleted. The user may explicitly discard
  it, after being told that the iPhone has not verified an import; cancel any
  known outstanding transfer first. `WCSessionFileTransfer` exposes `cancel()`,
  but cancellation is not a substitute for the app’s receipt protocol.
  [Apple: `WCSessionFileTransfer`](https://developer.apple.com/documentation/watchconnectivity/wcsessionfiletransfer)
* **After receipt:** retain a Watch copy under a clear user retention choice
  (for example, “keep until 3 verified iPhone sessions” or “delete now”). There
  is no automatic deletion merely because the framework reports transfer
  completion.
* **Export:** export from the iPhone raw vault as a manifest plus original raw
  chunks (and separately a derived CSV/JSON report). Export creates a user
  selected copy; it does not alter the Outbox, catalog, or HealthKit.
* **Delete from iPhone:** delete this session’s SwiftData catalog rows,
  derived data, and raw-vault directory together; retain a local deletion
  tombstone/suppression keyed by the session revision so delayed duplicates do
  not silently resurrect it. Clearing that tombstone is an explicit “import
  again from Watch” action.
* **Delete from Watch:** delete only the selected Outbox session, never the
  iPhone copy. **Delete everywhere** is two explicit local operations; a queued
  cross-device notification may be delayed, so each UI must show its own
  completed scope. App-owned deletion must not delete unrelated HealthKit
  samples.

## Implementation checklist

- [ ] Define `SessionManifest`, `ArtifactDescriptor`, `TransferEnvelope`,
  `OutboxState`, `ImportReceipt`, and `DeletionTombstone` as versioned Codable
  types; validate unknown versions rather than guessing.
- [ ] Implement the Watch writer/sealer and startup audit before recording UI
  claims that a save completed.
- [ ] Activate `WCSession` early on both targets, implement activation,
  reachability, file receive, file finish, user-info receive, and iOS
  inactive/deactivated callbacks.
- [ ] Implement Watch Outbox enumeration, explicit retry scheduling, error
  states, and no-companion UI; do not rely on `isReachable` for background sync.
- [ ] Implement iPhone synchronous `didReceive` staging, then a serialized
  importer/reconciler that is safe to run at launch and after each delivery.
- [ ] Put a unique constraint/index on the artifact dedup key and session
  revision key, but also verify disk bytes/digests before treating a row as
  imported. [Apple: SwiftData unique constraints](https://developer.apple.com/documentation/swiftdata/unique%28_%3A%29)
- [ ] Keep raw artifacts out of SwiftData blobs; store only paths, size,
  digest, lifecycle state, and derived chart data in the catalog.
- [ ] Build user-facing per-session states: `On Watch`, `Waiting for iPhone`,
  `Syncing`, `Imported`, `Needs attention`, and distinct Watch/iPhone deletion
  scopes.
- [ ] Set an empirical chunk-size policy only after device measurements; expose
  an internal diagnostic with artifact sizes, WC errors, retry count, and
  receipt latency—never raw location/motion content in normal logs.

## Open physical-device proof questions

No physical-device proof was performed for this research. Before committing to
the UX or a chunk-size default, prove these on the actual Series 8 and paired
iPhone:

1. Record three 90-minute offline sessions, then re-pair/reconnect and verify
   every manifest hash, artifact digest, and report reopen.
2. Measure the largest reliable GPS/motion artifact and total session payload;
   intentionally cross it to observe `payloadTooLarge`/timeout behavior and
   choose a measured chunk margin.
3. Test iPhone locked, both apps backgrounded/terminated, Bluetooth out of
   range, Wi-Fi changes, watch/phone reboot, and companion-app uninstalled then
   installed. Confirm the Watch never deletes before a matching receipt.
4. Force termination at every filesystem/SwiftData boundary: partial raw write,
   after manifest write, after incoming file move, after raw-vault write, and
   after catalog commit but before receipt.
5. Test low iPhone storage, malformed metadata, unreadable source file,
   duplicate transfer, missing chunk, different-digest duplicate, and receipt
   duplication/loss.
6. If the paired phone can switch Watches, exercise iOS inactive/deactivated
   activation flow and ensure the per-session producer key prevents collision.
7. Test full-resolution export from both a receipt-confirmed session and a
   Watch-only session, followed by each deletion scope.

Apple explicitly warns that Simulator does not support `transferFile` and
`transferUserInfo` testing; paired physical devices are required for those
transport proofs. [Apple: `transferFile`](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile%28_%3Ametadata%3A%29) [Apple: `transferUserInfo`](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo%28_%3A%29)
