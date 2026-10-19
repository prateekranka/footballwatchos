# Build and test

- Do not use FlowDeck on this machine — it is license-blocked. Use xcodebuild directly.
- iOS tests:
  `xcodebuild test -project FootballPerformance.xcodeproj -scheme FootballPerformanceTests -destination 'platform=iOS Simulator,id=CD369CF5-53C5-4EB2-9FC4-164D2716AAAC'`
- watchOS tests:
  `xcodebuild test -project FootballPerformance.xcodeproj -scheme FootballPerformanceWatchTests -destination 'platform=watchOS Simulator,id=BD726DC2-42A8-42C6-80E6-064BC09D7288'`
- E2E journeys (XCUITest, the main way to test features):
  `xcodebuild test -project FootballPerformance.xcodeproj -scheme FootballPerformanceE2E -destination 'platform=iOS Simulator,id=CD369CF5-53C5-4EB2-9FC4-164D2716AAAC' -resultBundlePath build/E2E.xcresult`
- CI (`.github/workflows/ios-ci.yml`) runs unit tests, E2E journeys and screenshots on a macOS runner for `claude/**` branches, uploads the result bundles, and pushes screenshots plus logs to the `ci-shots` branch.

# Testing rules

- Never write unit tests after writing the code.
- Prefer end-to-end (E2E) tests as the main way to test. Use them to check that complex features work.
- Make E2E tests produce an artifact that can be checked and reproduced.
- If you need to test a system in isolation, first list all the ways it could fail. Then write the code.
- For complex features, use realistic E2E scenarios with medium or high complexity. Don't test only the simplest successful case.
- Avoid tautological tests that only confirm what the code already says.
- Avoid tests that only detect whether code changed.
- For bug fixes, add a regression test only when existing behavior tests leave a real gap.

## How this applies here

- E2E journeys live in `Tests/E2E` and launch the real app with deterministic QA fixtures:
  `-FP_UI_QA YES -onboardingCompleted YES -FP_QA_SCENARIO <demo|worst|empty|one|many|coach> -FP_QA_TAB <sessions|progress|settings>`.
  Fixture dates are relative to launch time, so every run sees the same history. Add a fixture scenario in `QASessionFixtures.swift` when a feature needs a new realistic history.
- Each journey file opens with the list of ways the feature can fail and which journey covers each. Write that list before the code.
- Every journey attaches named screenshots (`XCTAttachment`, `.keepAlways`). The `.xcresult` bundle is the artifact; CI exports its attachments to `ci-shots`.
- Assert on values a player would see (quoted minutes, paces, percentages computed from the fixture), not on implementation details or copied constants.
- `Tests/*.e2e.ts` is the agent-driven `@e2e-dev/mobile` suite for local exploratory runs; it needs the local simulator and is not run in CI.
