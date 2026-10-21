# Watch UI automation results — 21 October 2026

Xcode 27.1 (27A9269) supports the Watch simulator XCUITest target. The app and UI test bundle built and ran on Apple Watch Series 12 (42mm), watchOS 27.0, UDID `3BE5CDAE-63E6-48BF-A1F1-DD9DEE7E339C`. DerivedData was `/tmp/fp-watch-ui-dd`.

Latest outcome per scenario: **5 passed, 2 app failures**. No app layout, visible copy, recording state logic, or hold logic was changed. Both DEBUG automation hooks were disabled during the UI tests.

| Scenario | Result | Observed behavior |
| --- | --- | --- |
| a. Idle | FAIL — app | `Start Football` exists but is not hittable before scrolling. Its frame is `(13, 255, 161, 48)` in a `(0, 0, 187, 223)` screen. The entire control is below the initial screen. Scrolling makes it reachable. |
| b. Start and metrics | FAIL — app metric | Start opens the countdown and reaches Recording. Elapsed time advances. The initial visible metrics are `— BPM` and `0.00 KM`, with `Motion unavailable`. Exact accessibility labels: `HEART, —, BPM` and `DISTANCE, 0.00, KM`. Distance fails the missing-metric dash rule. |
| c. Quick tap | PASS | A quick Hold to Finish tap leaves Recording visible. Elapsed time continues to advance; Saved is absent. |
| d. Hold | PASS | `press(forDuration: 2.5)` saves the session. The summary shows `Saved on Watch`, `Waiting for iPhone`, and `Health workout saved`. |
| e. Navigation | PASS on focused retry | The ellipsis opens `Motion Diagnostics` directly. Back returns to Recording. Saved `Details` opens and Back returns to the saved summary. |
| f. Kill and recover | PASS | The timer showed `Elapsed 0 minutes 10 seconds` before termination. Relaunch returns to idle; it does not resume Recording and shows no recovery alert. After scrolling, Session Recovery has an orange badge. Recover Sessions completes and Home returns to idle. |
| g. Non-default type | PASS | The picker initially shows `Football`. Selecting `5-a-side` returns to a picker labeled `Session type, 5-a-side`. That session starts and saves with `Saved on Watch` and `Waiting for iPhone`. |

The latest recovery run changed `Needs recovery, 1` to `Needs recovery, 0`, `Recovered, 3/4` to `Recovered, 4/4`, and `Waiting for iPhone, 3` to `Waiting for iPhone, 4`. The killed session's log entry was `Recovered · 9 s Wed, Oct 21 at 17:09`. Its message included `Recovered Wed, Oct 21 at 17:09 · 9 s.` The earlier complete run recovered its killed session as 10 seconds. These counts include pre-existing sessions; recovery was performed through the app and no simulator data was erased.

The recovery message also listed the existing recovered sessions. The full text and accessibility trees are retained in the exported attachments. There was no completed iPhone import: the latest recovery screen showed `Imported, 0` and `Transferred 0 of 4 to iPhone`.

## App bugs

- Start is below the initial visible area on the requested 42mm screen.
- Missing distance displays `0.00 KM` rather than a dash. The recorder initializes distance to zero and retains it when no distance quantity arrives; the Watch formatter always renders a number.

## Test harness limits

- First complete run: **5 passed / 2 failed / 0 skipped**, [watch-suite.xcresult](watch-ui-evidence/watch-suite.xcresult).
- Screenshot verification run: **4 passed / 3 failed / 0 skipped**, [watch-final.xcresult](watch-ui-evidence/watch-final.xcresult). The additional failure was scenario e during launch: `Failed to get matching snapshots: Error getting main window kAXErrorServerNotFound`. It occurred before navigation, then hit the test time allowance. Xcode restarted the runner and continued.
- Scenario e with the final test code passed in an isolated retry: **1 passed / 0 failed**, [navigation-retry.xcresult](watch-ui-evidence/navigation-retry.xcresult). The retry build reported no warnings. This resolves the navigation observation but does not establish that the simulator accessibility failure cannot recur.
- The first two focused runs exceeded the connector's 300-second response limit. Their completed xcresults retained the genuine Start failure. A connector timeout was not counted as an app bug.
- No fresh Health or motion permission sheet appeared. The interruption monitor and Watch SpringBoard handling were added, but this run did not exercise that path.
- The saved summary does not display session type. The test proves picker selection followed by recording and saving; it does not inspect the stored package's type field.
- Xcode's result metadata incorrectly uses the paired iPhone name in `deviceName`. The exact Watch UDID, `modelName: Apple Watch Series 12`, and `platform: watchOS Simulator` identify the tested target.

## Evidence

All successful step captures retain PNG screenshots and matching accessibility trees. The latest per-scenario runs have 47 screenshot attachments: 37 from the verification run and 10 from the navigation retry. Original exports and manifests are in [watch-ui-shots](watch-ui-shots/). Named PNGs at that directory's top level use the latest available capture for each step.

Key images: [idle](watch-ui-shots/a-idle-without-scrolling.png), [active metrics](watch-ui-shots/b-first-active-metrics.png), [saved](watch-ui-shots/d-saved-summary.png), [diagnostics](watch-ui-shots/e-options-motion-diagnostics.png), [details](watch-ui-shots/e-saved-details.png), [relaunch](watch-ui-shots/f-relaunch-first-screen.png), [recovery completed](watch-ui-shots/f-recovery-completed.png), [type choices](watch-ui-shots/g-session-type-choices.png), [5-a-side selected](watch-ui-shots/g-non-default-selected.png).

Machine-readable outcomes, observations, attachment counts, source hashes, and command output are in [watch-ui-evidence](watch-ui-evidence/). The run procedure is in [Tests/WatchUI/README.md](../../Tests/WatchUI/README.md).

Changed source files: `project.yml`, `Sources/Watch/WatchRootView.swift`, and new `Tests/WatchUI/WatchUITests.swift` and `Tests/WatchUI/README.md`. The ignored Xcode project was regenerated. New QA artifacts are confined to this directory. `SessionStoreCredentials.swift` was not edited. No commit, push, or other checkout edit was performed.
