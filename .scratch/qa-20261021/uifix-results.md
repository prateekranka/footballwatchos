# UI fixes — 21 October 2026

All edits are in the requested worktree on `claude/qa-20261021`. No commit, push, other checkout edit, or simulator state change was made. The ignored `SessionStoreCredentials.swift` placeholder was not edited.

## Task status

| Task | Status | Files and behavior |
| --- | --- | --- |
| A | Source complete | `Tests/WatchUI/WatchUITests.swift`, `Tests/WatchUI/README.md`, `project.yml`, `Sources/Watch/WatchRootView.swift`, `AGENTS.md`. Hand-merged the target, scheme, and every accessibility identifier from the patch. Kept the iPhone E2E target and prior Watch safety changes. Scenario b requires an unobserved-distance dash. |
| B | Complete | `Sources/iOS/Sync/SessionPushOutbox.swift`: removed the upload closure and initializer argument. Retained the single-flight guard and removal by session ID in success and missing-session paths. |
| C | Source complete; runtime unverified | `Sources/Watch/WatchRootView.swift`: compact icon/title row, then Start, type picker, intro, and recovery. Start no longer follows the large hero, multi-line intro, and picker. |
| D1 | Source complete; runtime unverified | `Sources/iOS/Reports/SessionOverviewScreen.swift`: Interrupted and the recorded reason are inside the hero. Removed the redundant status below the hero. |
| D2 | Source complete; runtime unverified | `Sources/iOS/DesignSystem/PerformanceTheme.swift`: 16-point metric gaps with baseline alignment; accessibility sizes remain vertical. |
| D3 | Source complete; runtime unverified | `Sources/iOS/Reports/PhoneSessionLibraryModel.swift`, `Sources/iOS/Reports/SessionsHomeView.swift`, `Sources/iOS/RootTabView.swift`: explicit first-load completion, Loading sessions until completion, QA fixture generation also remains loading. Root owns the initial refresh and preview preparation; scene activation refresh waits for that first load. |
| D4 | Source complete; runtime unverified | `SessionsHomeView.swift`, `PerformanceComponents.swift`: stack week heading/streak and stats at accessibility sizes, allow captions to wrap, suppress chart axis labels at those sizes while retaining the chart accessibility summary. |
| E | Partial | `Tests/E2E/SessionActionsE2ETests.swift`: four journeys, opening failure list, named screenshots and accessibility trees, visible values, and geometry assertions. Loading journey omitted for the reason below. Runtime execution and share-sheet diagnosis remain blocked. |

## Verification

- PASS: `xcodegen generate`; generated the project and Watch scheme successfully.
- PASS: Swift syntax parsing for the eight changed app files and both new UI test files.
- PASS: Swift 6 type checking of all three iPhone E2E files against the iPhone Simulator SDK.
- PASS: Swift 6 type checking of Watch UI tests against the Watch Simulator SDK.
- PASS: `git diff --check`; all Watch identifiers from the patch are present; both generated UI test schemes have parallel testing disabled.
- BLOCKED: full app type checking. Apple's SwiftUI macro executable fails with `sandbox-exec: sandbox_apply: Operation not permitted`, followed by malformed macro responses. Secondary State-property diagnostics are not evidence of app defects.
- BLOCKED: both exact-UDID simulator preflights. CoreSimulator reports `connection became invalid`, `Connection refused`, and `could not query simulator devices`. Disk preflight passed. The mandatory Xcode gate stopped both requested `xcodebuild test` commands before execution.
- No old `E2E-uifix.xcresult` or `WatchUI-uifix.xcresult` existed. No fresh bundle or PNG was produced. No older run is reported as proof of these changes.

Logs are in `uifix-proof/20261021T122608Z.CEcUhA/` beside this report. `xcodegen.stdout`, `syntax.stderr`, `iphone-tests-typecheck.stderr`, `watch-tests-typecheck.stderr`, `iphone-preflight.stderr`, and `watch-preflight.stderr` provide the relevant evidence.

## Every journey and scenario

All entries below are **BLOCKED / NOT RUN** in this session. None has a fresh runtime pass or failure result.

| iPhone journey | Status |
| --- | --- |
| Coaching: load spike through session takeaways | BLOCKED |
| Age setting recalculates heart-rate zones | BLOCKED |
| Manual log counts as load without sensor insights | BLOCKED |
| Empty history guidance without coaching | BLOCKED |
| Degraded history keeps coaching bound to recorded evidence | BLOCKED |
| Export dismissal from the session menu and Details; Progress usable afterward | BLOCKED |
| Delete cancellation, explicit confirmation, Sessions count update, Progress 4 to 3 | BLOCKED |
| Interrupted hero, workout-ended reason, 40 min, 3.7 km, and separated metrics | BLOCKED |
| Accessibility XXXL full captions, stacked stats, and chart separation | BLOCKED |

| Watch scenario | Status |
| --- | --- |
| a. Idle Start fits and is hittable before scrolling | BLOCKED |
| b. Countdown, timer advance, and missing-metric dash | BLOCKED |
| c. Quick tap does not finish | BLOCKED |
| d. Long press saves and shows transfer status | BLOCKED |
| e. Diagnostics and saved Details open and return | BLOCKED |
| f. Kill, relaunch, explicit recovery, and Home | BLOCKED |
| g. Non-default session type, recording, and saving | BLOCKED |

## Open questions and risks

The share-sheet problem is still unclassified. Both paths use SwiftUI `ShareLink`; the prior manual report did not prove an app defect. The new journey uses the system Close/Cancel control, then navigates and checks the remaining session count. No speculative share-sheet code change was made.

The first-load state has no deterministic UI completion gate. The `many` fixture can take tens of seconds, but its duration depends on CPU and disk performance. Requiring the test runner to catch this transient state would create a timing-dependent test. No delay or test-only loader hook was added.

The Watch Start frame, XXXL rendering, and share-sheet control names still need runtime verification. Shared metric spacing also changes existing coaching and Progress cards. The Watch type picker now follows Start. Permission handling, physical Watch sensor behavior, and actual Watch-to-iPhone delivery are not established by source checks.

Once the runtime gate is available, use the two test commands in the user request. Remove only the two same-named result bundles before repeating. Export attachments into `uifix-shots/iphone` and `uifix-shots/watch` with:

```sh
xcrun xcresulttool export attachments --path .scratch/qa-20261021/E2E-uifix.xcresult --output-path .scratch/qa-20261021/uifix-shots/iphone
xcrun xcresulttool export attachments --path .scratch/qa-20261021/WatchUI-uifix.xcresult --output-path .scratch/qa-20261021/uifix-shots/watch
```
