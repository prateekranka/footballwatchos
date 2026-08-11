# Define the HealthKit Ownership and Deletion Boundary

Type: research
Status: resolved
Blocked by: none
Part of: [Personal Apple Watch Football Performance System](../map.md)

## Question

What exact HealthKit read, write, source-attribution, association, and deletion rules let the system save soccer workouts and use heart rate, distance, active energy, and route evidence while guaranteeing that deleting a Football Session or all app-owned data never mutates unrelated HealthKit records?

## Resolution

HealthKit belongs exclusively to the Watch recording target. The Watch requests
the minimum workout/read permissions required for an outdoor soccer workout and
live heart-rate/distance evidence. One private session UUID is generated before
capture and stored in both the package envelope and app-specific HealthKit
metadata. Missing read results remain unavailable; they are never interpreted
as zero or proof that access was denied.

The iPhone companion does not import HealthKit and never queries, writes, or
deletes HealthKit objects. Its ordinary **Delete iPhone copy** command removes
only the app's private package, report/index entry, and durable receipt after
writing a local tombstone. It cannot affect the Watch copy or any HealthKit
record.

Any future opt-in HealthKit deletion is a separate, explicitly confirmed
operation. It may act only on exact workout/route UUIDs recorded in the private
ledger after validating type, app metadata, session UUID, and source. Broad
date, source, activity-type, or metadata-only deletion is prohibited. Foreign
or merely discovered HealthKit records never acquire deletion authority.

## Evidence

- [Primary-source HealthKit boundary research](../research/06-healthkit-boundary.md)
- `Sources/Watch/WorkoutRecorder.swift`
- `Sources/iOS/Storage/FileSessionRepository.swift`
- Static source audit: iPhone sources contain no `import HealthKit`
- Static source audit: current product sources contain no HealthKit deletion API

Exact route association, locked-device save reconciliation, authorization edge
cases, and any future opt-in HealthKit deletion still require physical-device
proof before that optional behavior can ship.
