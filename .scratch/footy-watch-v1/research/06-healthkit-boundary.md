# HealthKit Ownership and Deletion Boundary

Status: research recommendation, not device proof
Scope: personal, Watch-first outdoor soccer recorder; watchOS/iOS 26; Swift 6.

## Decision

Treat a Football Session as two deliberately separate stores:

1. **App-private session data** — raw motion and GPS evidence, derived series and
   reports, venue data, notes, sync state, and the small HealthKit locator ledger.
   The app can always delete these records without calling HealthKit.
2. **Optional app-created HealthKit records** — exactly one `HKWorkout` configured
   as `.soccer` and, when available, exactly one `HKWorkoutRoute` created for that
   session. The user may explicitly choose to remove these two records from
   HealthKit, but that is a separate, confirmed operation.

The app must never delete a HealthKit object merely because it overlaps a session's
time range, has the soccer activity type, came from an Apple Watch, or is associated
with a workout. HealthKit permits an app to delete only objects that it saved, but
that platform restriction is a floor, not sufficient product ownership evidence.
[Apple's `deleteObjects` contract](https://developer.apple.com/documentation/healthkit/hkhealthstore/deleteobjects%28of%3Apredicate%3Awithcompletion%3A)
and the local [HealthKit SDK header](/Applications/Xcode.app/Contents/Developer/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKHealthStore.h:171)
both state that limit.

## Ground rules from Apple sources

- A live workout builder creates an `HKWorkout` during an active
  `HKWorkoutSession`; ending collection and then `finishWorkout` creates and saves
  the workout. The finish completion can report a successful finish with no workout
  object while the device is locked, so `nil` is not permission to create a second
  workout. [Apple: `HKLiveWorkoutBuilder`](https://developer.apple.com/documentation/healthkit/hkliveworkoutbuilder),
  [Apple: `finishWorkout`](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder/finishworkout%28completion%3A%29),
  [SDK header](/Applications/Xcode.app/Contents/Developer/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKWorkoutBuilder.h:248).
- `HKLiveWorkoutDataSource` automatically feeds the builder. Its supported types
  depend on the platform, settings, and workout configuration; the documented
  possible set includes heart rate, active energy, and walking/running distance.
  Therefore the UI may request those metrics but must not promise that all three
  will arrive for `.soccer` until proved on the Series 8. [Apple:
  `typesToCollect`](https://developer.apple.com/documentation/healthkit/hkliveworkoutdatasource/typestocollect).
- Apple documents `HKWorkoutRoute` as a separate series sample. Route creation
  needs both HealthKit and Core Location permission; it must be associated with a
  saved workout and cannot later be moved to another workout. [Apple: *Creating a
  workout route*](https://developer.apple.com/documentation/healthkit/creating-a-workout-route),
  [Apple: `HKWorkoutRouteBuilder`](https://developer.apple.com/documentation/healthkit/hkworkoutroutebuilder).
- HealthKit assigns each object a UUID and records its saving app/device as the
  source revision. The UUID identifies one stored object; source provenance is set
  when the object is saved and is available after it is retrieved. [Apple:
  `HKObject.uuid`](https://developer.apple.com/documentation/healthkit/hkobject/uuid),
  [Apple: `source`](https://developer.apple.com/documentation/healthkit/hkobject/source),
  [Apple: *About HealthKit*](https://developer.apple.com/documentation/healthkit/about-the-healthkit-framework).
- The app can add custom metadata, and Apple provides `HKMetadataKeyExternalUUID`
  for a source-defined identifier. That key's uniqueness is **not** enforced, so it
  is a reconciliation marker, not a database constraint. Do not use
  `HKMetadataKeySyncIdentifier` for these locally-created workouts: a higher sync
  version replaces an existing object and carries it into the old object's workout
  or correlation associations. [Apple: metadata](https://developer.apple.com/documentation/healthkit/hkobject/metadata),
  [Apple: external UUID](https://developer.apple.com/documentation/healthkit/hkmetadatakeyexternaluuid),
  [SDK metadata header](/Applications/Xcode.app/Contents/Developer/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKMetadata.h:131).

## Ownership matrix

| Asset | System of record and owner | May be read | Deletion rule |
| --- | --- | --- | --- |
| `FootballSession`, per-second/interval aggregates, original raw motion and GPS, venue link, notes, export, derived action candidates | App-private storage; `sessionID` is canonical | App only; export is an explicit copy | Delete immediately for **Delete private session**. This operation makes no HealthKit call. |
| Locator ledger: `sessionID`, HealthKit-store scope, workout/route UUIDs, external marker, save/deletion state | App-private storage, no health values | App only | Delete with private session **only after** a successful optional HealthKit deletion; otherwise retain a minimal deletion tombstone. |
| `HKWorkout` configured `.soccer` | HealthKit; created by this app's live builder | App only with requested read access; user/other Health apps under their rules | Optional, confirmed deletion only when the exact recorded UUID, app source, and session marker all match. Never delete a retrieved/imported workout. |
| `HKWorkoutRoute` created for that workout | HealthKit; created by this app's route builder | App only with requested route read access | Optional, confirmed deletion only when the exact route locator validates. Delete it explicitly; do not assume deleting its workout cascades. |
| Heart-rate, active-energy, and distance samples/statistics supplied through `HKLiveWorkoutDataSource` | HealthKit-managed workout data; provenance and association must be inspected on device | Live builder statistics and later queries when permission allows | **Never enumerate and delete quantity samples as part of session deletion.** They are not an app-private data store, and Apple does not document a workout-delete cascade suitable for this safety guarantee. |
| Existing Apple Workout, another app's workout/route, a manually entered item, or imported historical HealthKit object | Foreign HealthKit data | Only if the user grants read access | Read-only import/reference. Store its foreign UUID and source as a link if needed; never delete or “clean up” it. |
| HealthKit record from an older install that lacks a current private ledger entry | HealthKit, even if it has this bundle's source/marker | Candidate may be displayed after a user asks to review it | Never auto-delete on reinstall or first launch. A user may select a validated, itemized candidate in a separate HealthKit cleanup flow. |

The local SDK declares `.soccer`, `HKWorkoutTypeIdentifier`, and
`HKWorkoutRouteTypeIdentifier` for watchOS, and defines the three quantity
identifiers used by this plan. [Workout type header](/Applications/Xcode.app/Contents/Developer/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKWorkout.h:20),
[type-identifier header](/Applications/Xcode.app/Contents/Developer/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKTypeIdentifiers.h:33).

## Authorization matrix

Request the smallest useful sets before recording, explain the independent reasons
in the usage descriptions, and keep location permission separate from HealthKit.
Apple’s route guide specifically requires both read and share authorization for
`HKWorkout` and `HKWorkoutRoute`, plus Core Location authorization.
[Apple: route permissions](https://developer.apple.com/documentation/healthkit/creating-a-workout-route).
For the live quantities, Apple’s workout-session sample requests sharing only for
the workout type and requests read access for heart rate, active energy, and
walking/running distance; this is the model used below.
[Apple WWDC21 workout sample](https://developer.apple.com/videos/play/wwdc2021/10009/?time=1662).

| Need | `toShare` | `read` | If unavailable |
| --- | --- | --- | --- |
| Save and later identify the app's soccer workout | `HKObjectType.workoutType()` | `HKObjectType.workoutType()` | Do not advertise a HealthKit-saved recording. If sharing is denied, block the HealthKit workout path; a separate private-only capture mode would need its own explicit product decision. |
| Save, associate, later display, or delete the route | `HKSeriesType.workoutRoute()` | `HKSeriesType.workoutRoute()` | Save the workout without a route when possible; mark route/spatial evidence unavailable and retain private GPS only under the app's data policy. |
| Live/post-save heart rate | none | `.heartRate` | Render “Heart rate unavailable” rather than “permission denied” or zero. |
| Live/post-save active energy | none | `.activeEnergyBurned` | Omit calories/energy claims; do not synthesize a HealthKit active-energy sample. |
| Live/post-save distance | none | `.distanceWalkingRunning` | Omit that HealthKit metric; private GPS-derived distance is separately labelled and may have its own quality status. |
| GPS route | none in HealthKit; route sharing above | route read above | Also require Core Location authorization. If location is denied or route insertion fails, preserve the saved workout but suppress route/heat-map claims. |
| Delete an app-created workout or route | corresponding object type | corresponding type for validation/querying | Leave a minimal pending-deletion tombstone and state that HealthKit deletion was not completed. Do not treat an empty query as proof that it is gone. |

`requestAuthorization` completion means the permission sheet completed, **not** that
the person granted access. `authorizationStatus(for:)` is a sharing/write status;
HealthKit intentionally does not reveal read denial, instead returning no foreign
data (while still showing data the app wrote). `statusForAuthorizationRequest`
answers only whether the system would prompt again, not whether read permission was
granted. [Apple: `HKAuthorizationStatus`](https://developer.apple.com/documentation/healthkit/hkauthorizationstatus),
[Apple: request-status enum](https://developer.apple.com/documentation/healthkit/hkauthorizationrequeststatus),
[SDK authorization contract](/Applications/Xcode.app/Contents/Developer/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKHealthStore.h:64).

## Save and import identifiers

Create a cryptographically random, app-private `sessionID` before starting the
countdown. It is the only cross-store/cross-device identity. HealthKit UUIDs are
locators, not the canonical session key: Apple documents separate HealthKit stores
for iPhone and Apple Watch, so do not assume a UUID captured on one is a universal
mirror locator on the other. [Apple: HealthKit architecture](https://developer.apple.com/documentation/healthkit/about-the-healthkit-framework).

Persist this ledger before and after every irreversible operation:

| Field | Purpose |
| --- | --- |
| `sessionID` | Stable primary key for private storage, Watch-to-iPhone sync, and exports. |
| `healthStoreScope` | Records which store produced each locator; do not assume Watch and phone object UUIDs are interchangeable. |
| `workoutUUID`, `routeUUID` | Exact deletion/read locators, written only after the respective save/reconciliation returns the object. |
| `externalID` | `footy-watch-v1:<sessionID>` stored as `HKMetadataKeyExternalUUID` on both created objects. It helps reconciliation but cannot enforce uniqueness. |
| namespaced marker and schema | For example, `com.prateekranka.footballwatchos.session-id` and `.schema = 1`, also placed on both objects. A custom key is allowed by HealthKit. |
| source expectation | The app's exact bundle identifier plus the source revision observed after retrieval. It is a validation factor, not an identifier. |
| `saveState` / `deletionState` | `prepared`, `workoutSaved`, `routeSaved`, `complete`, `deletePending`, or `deleted`; supports idempotent recovery without duplicate saves. |

**Write path.** Add the two session markers to the workout builder before finishing.
Use an outdoor `HKWorkoutConfiguration` with activity type `.soccer`, an
`HKWorkoutSession`, `HKLiveWorkoutBuilder`, and its data source; start collection,
then end collection and call `finishWorkout` once. Apple says the builder saves the
workout at finish. Persist the returned workout UUID and retrieve it again before
trusting source provenance. [Apple: workout builders](https://developer.apple.com/documentation/healthkit/hkworkoutbuilder),
[Apple: sources](https://developer.apple.com/documentation/healthkit/hkobject/source).

**Route path.** Prefer the live/workout builder's
`seriesBuilder(for: HKSeriesType.workoutRoute())`, add the same route metadata, and
insert filtered `CLLocation` batches. The current SDK header says a series builder
obtained from a workout builder is associated when the workout builder finishes, and
that its route builder must not also receive an explicit `finishRoute` call. If the
implementation instead uses a standalone `HKWorkoutRouteBuilder`, first save the
workout, then call `finishRoute(with:metadata:)` exactly once. Do not mix the two
completion models. [Apple: route guide](https://developer.apple.com/documentation/healthkit/creating-a-workout-route),
[SDK workout-builder association](/Applications/Xcode.app/Contents/Developer/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKWorkoutBuilder.h:279),
[SDK route-builder contract](/Applications/Xcode.app/Contents/Developer/Platforms/WatchSimulator.platform/Developer/SDKs/WatchSimulator.sdk/System/Library/Frameworks/HealthKit.framework/Headers/HKWorkoutRouteBuilder.h:82).

After a route is saved, record its returned UUID (standalone builder) or query the
route type by association to the exact workout and validate the source and both
metadata markers (builder-owned route). Apple supplies predicates for objects from a
source and for objects associated with a workout; neither is an authorization to
delete a broad result set. [Apple: source predicate](https://developer.apple.com/documentation/healthkit/hkquery/predicateforobjects%28from%3A%29-7j3p2),
[Apple: workout-association predicate](https://developer.apple.com/documentation/healthkit/hkquery/predicateforobjects%28from%3A%29-89b4t).

**Import path.** An imported HealthKit workout always remains foreign unless its
UUID is already present in this ledger and all provenance checks pass. Its import
record stores `foreignWorkoutUUID`, `sourceRevision`, and original dates separately
from `sessionID`; it carries no deletion entitlement. Never turn a foreign imported
workout into a new app-created `HKWorkout` merely to attach a Football Session.

## Exact deletion algorithm

There are two intentionally different commands:

- **Delete private Football Session** — erase the private session, raw evidence,
  derived data, notes, and normal locator ledger. It performs zero HealthKit writes
  or deletions.
- **Delete private Football Session and its HealthKit Workout/Route** — present the
  exact workout and route details plus a second confirmation, then apply the
  algorithm below. This is the only command allowed to mutate HealthKit.

For the second command:

1. Load the one private ledger record by `sessionID`. If it has no `workoutUUID`, do
   not discover candidates by date, soccer type, or source; delete the private data
   only and report that no linked HealthKit object is known.
2. Place a minimal `deletePending` tombstone containing the session and exact
   locators before any HealthKit call. It has no raw GPS, motion, or health values.
3. Fetch each stored UUID using an exact UUID predicate. For every returned object,
   require: expected object type; UUID equality; the exact namespaced session marker
   and external marker; and the expected source revision/bundle. For the workout,
   also require `.soccer`. If any check fails, make no HealthKit mutation and flag
   the ledger for user review.
4. If an app-created route locator validates, delete that **exact route object**
   first. If it is already absent, record an idempotent route-not-found result; do
   not substitute a date/source lookup. Do not rely on an undocumented route/workout
   cascade.
5. Delete the one validated `HKWorkout`. Do not delete associated heart-rate,
   distance, or active-energy samples, and do not call `deleteObjects(of:predicate:)`
   with a source, date, type, or metadata-only predicate.
6. Treat a successful HealthKit delete completion as the result. Read visibility can
   be withheld, so a subsequent empty query is not stronger evidence. On success,
   erase the private session and tombstone. On any failure or revoked sharing
   permission, retain the tombstone and show the remaining exact object(s) as
   pending; retry only after the user chooses to do so.

The UUID predicate is the narrow identifier Apple provides, while a source predicate
matches *all* objects created by that source. This distinction is why broad source,
date, and activity queries are prohibited in deletion code. [Apple: `HKQuery`
predicates](https://developer.apple.com/documentation/healthkit/hkquery),
[Apple: `deleteObjects` errors and atomicity](https://developer.apple.com/documentation/healthkit/hkhealthstore/deleteobjects%28of%3Apredicate%3Awithcompletion%3A).

For **Delete all app-owned data**, iterate only the private ledger and run the same
per-session operation. If the user selects private-only deletion, do not touch
HealthKit. If the user selects the optional HealthKit removal, retain the pending
set until every exact deletion succeeds. On reinstall, the private ledger may be
absent while prior HealthKit objects remain: preserve them by default and offer an
explicit, itemized review of custom-marker candidates instead of an automatic purge.

## Failure and degraded behavior

| Condition | Safe behavior |
| --- | --- |
| Workout share authorization denied/not determined | The HealthKit workout recorder cannot claim a saved Football Session. Explain the missing permission; do not silently replace it with a fake HealthKit save. |
| Read access denied or limited | Treat missing values as **unavailable**, not zero and not proof of denial. The app cannot reliably infer read authorization. Keep non-health private capture separate. |
| Live data source omits a requested type | Show the other metrics; omit that field and post-session claim. Do not manually manufacture HealthKit quantity samples to fill the gap. |
| Location/route sharing denied, no valid locations, or route completion fails | Preserve the successfully saved workout; mark route and spatial analysis unavailable. Never create a duplicate workout merely to retry a route. |
| Device locked during `finishWorkout` | Leave `workoutSavedPendingReconcile`; after unlock, locate only the object with the exact markers and source. Do not call `finishWorkout` or start a replacement session again. |
| Crash/relaunch between HealthKit save and private ledger write | Reconcile only against exact custom markers and source; show duplicates/conflicts for review. External UUID metadata cannot prove uniqueness on its own. |
| User revokes share authorization before deletion | Do not claim deletion. Keep the minimal tombstone and explain that HealthKit access must be restored to finish the explicit deletion. |
| Route/workout deletion partially succeeds | Keep a tombstone listing the remaining object; do not broaden the next retry. The ordinary private-only delete command remains available and makes no HealthKit changes. |
| Reinstall / new device | Do not use a source/date sweep to erase old HealthKit data. Reconstruct links only through user-reviewed exact markers; new saves use new local ledger locators and the stable external `sessionID`. |

## Implementation checklist

- [ ] Define one private `SessionHealthKitLocator` model with per-store workout and
      route UUIDs, external marker, schema, observed source revision, and state.
- [ ] Request only the matrix's HealthKit types and Core Location; include precise
      `NSHealthShareUsageDescription` and `NSHealthUpdateUsageDescription` text.
- [ ] Configure the Watch workout as outdoor `.soccer`; use `HKWorkoutSession` +
      `HKLiveWorkoutBuilder` + `HKLiveWorkoutDataSource`, not ad-hoc quantity
      samples for heart rate, distance, or active energy.
- [ ] Generate the private ID before collection; add both markers to workout and
      route before finalization; never use `HKMetadataKeySyncIdentifier` for this
      path.
- [ ] Make the save state machine single-flight. A retry reconciles first; it never
      starts another builder after a completion is ambiguous.
- [ ] Use either the workout-builder-owned route flow or standalone route-builder
      flow, never both. Store/query an exact route UUID after completion.
- [ ] Keep import code read-only with respect to HealthKit; a foreign link never
      enters the deletion ledger.
- [ ] Implement two visibly distinct deletion actions and exact-UUID validation.
      Prohibit `deleteObjects(of:predicate:)` in product deletion code unless a
      future reviewed design demonstrates equivalent per-object validation.
- [ ] Persist only a minimal tombstone for incomplete opt-in HealthKit deletion;
      show it in the data-lifecycle UI and make retry user initiated.
- [ ] Log non-sensitive save/deletion state and HealthKit error codes, not raw
      locations, heart rate, or route contents.

## Unresolved physical-device proof questions

These are release gates, not claims established by documentation:

1. On the actual Series 8 with `.soccer` and outdoor configuration, which of heart
   rate, active energy, and walking/running distance appear in
   `HKLiveWorkoutDataSource.typesToCollect`, arrive live, and persist into the
   saved workout?
2. Does the Watch build receive the requested HealthKit and Core Location prompts,
   and do denial/revocation states produce the exact degraded UI above without
   showing false zeroes?
3. Which source revision, device, custom metadata, and UUIDs are observed on the
   saved workout and route in the Watch and companion-phone stores? Are their UUIDs
   stable enough for the planned per-store ledger?
4. In the selected `HKLiveWorkoutBuilder.seriesBuilder(for:)` route flow, is the
   route finalized and associated exactly once at workout finish on watchOS 26? If
   a standalone builder is used instead, does its explicit finish create exactly one
   associated route?
5. With a known app workout and route, does deleting the route then the workout
   leave either unexpected orphan, and does deleting the workout alone ever alter
   the route? Apple documents association, but this research found no deletion
   cascade contract to rely on.
6. Does the exact deletion flow leave unrelated Apple Workout and another app's
   soccer workout/route untouched when their dates overlap? Test both a normal
   deletion and an interrupted/retry deletion.
7. What occurs if the Watch is locked at `finishWorkout`, the app is terminated
   after a save but before its ledger write, sharing is revoked before deletion, or
   the app is reinstalled? Each case must demonstrate no duplicate save and no
   automatic HealthKit purge.

## Primary sources used

All web sources below are Apple Developer documentation; the additional primary
source was the installed Xcode WatchSimulator HealthKit SDK headers, linked inline
above. No device run, simulator run, or inferred deletion behavior is treated as
proof in this note.

- [Apple — Creating a workout route](https://developer.apple.com/documentation/healthkit/creating-a-workout-route)
- [Apple — `HKHealthStore` deletion API](https://developer.apple.com/documentation/healthkit/hkhealthstore/deleteobjects%28of%3Apredicate%3Awithcompletion%3A)
- [Apple — Authorization privacy semantics](https://developer.apple.com/documentation/healthkit/hkauthorizationstatus)
- [Apple — `HKLiveWorkoutDataSource.typesToCollect`](https://developer.apple.com/documentation/healthkit/hkliveworkoutdatasource/typestocollect)
- [Apple — Object UUID, source, and metadata](https://developer.apple.com/documentation/healthkit/about-the-healthkit-framework)
