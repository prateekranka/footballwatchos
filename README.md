# Football Performance

A watchOS-first personal football recorder for Apple Watch Series 8, with a
subordinate iPhone companion for post-session sync and analysis.

## Current slice

The Watch app is the only recorder. The current foundation:

- start an outdoor HealthKit soccer workout after a three-second countdown;
- keep live elapsed time, heart rate, and distance visible;
- capture device-motion diagnostics using `CMBatchedSensorManager` when the
  hardware supports it;
- label a `CMMotionManager` stream as a foreground diagnostic fallback when
  batched delivery is unavailable;
- append HealthKit and motion observations to a checksummed, recoverable
  `.footysession` package while the workout is active;
- finish through a guarded press-and-hold action, seal the local package, and
  retain it in a file-backed Watch outbox;
- transfer sealed packages opportunistically with WatchConnectivity while
  distinguishing transport completion from a durable iPhone import receipt.

The iPhone companion stages incoming files synchronously, validates and imports
them idempotently into a local file vault, persists receipts and deletion
tombstones, and presents a session library with factual heart-rate or distance
charts. It can share the exact stored package and delete only its private local
copy. It never records a Football Session and makes no HealthKit calls.

## Generate the project

Requirements:

- Xcode 26.6 or newer
- XcodeGen 2.45.3 or newer

```sh
xcodegen generate
open FootballPerformance.xcodeproj
```

The generated project has two explicit application targets:

- `FootballPerformanceWatch` — independent watchOS app and primary product
- `FootballPerformance` — iOS companion that embeds the Watch app

It also has focused iOS and watchOS test targets for the durable package/import
contract and Watch receipt state machine.

## Device proof still required

A simulator or generic SDK build cannot answer Ticket 1. Resolving that ticket
requires physical Series 8 sessions during active soccer workouts, recording
the selected Core Motion path, delivered frequency, sample gaps, GPS/heart-rate
coverage, battery drain, and thermal behavior. Paired-device transfer and
app-level receipt behavior also remain physical proof gates. Simulator tests and
SDK builds do not establish those claims.

## Product constraints

- normal recording must work without an iPhone or network connection;
- there is no account, server, cloud processing, CloudKit, or iPhone HealthKit
  access;
- WatchConnectivity is delayed transport only; recording and local save do not
  depend on it;
- `Estimated Actions` are not implemented or implied by raw motion collection;
- HealthKit and motion permissions are requested only on the Watch.

The staged roadmap and ticket source of truth live in
`.scratch/footy-watch-v1/`.
