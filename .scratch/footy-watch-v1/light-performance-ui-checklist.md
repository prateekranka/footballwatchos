# Light Performance UI — implementation checklist

Branch: `feat/light-performance-ui` (base: origin/feat/r2-upload @ 88b83a0).
References: light-mode iPhone concept + Apple Watch OLED flow (approved direction).

## Ground rules (from repo docs + task)

- Never show a missing metric as 0. Use "—"/"Not recorded"/"Unavailable".
- No venue, no sprints/actions naming for wrist motion, no baseline % before baseline is valid.
- Observation = factual, at most one per screen, suppressed when evidence is thin.
- Do not decode whole packages for list rows: bounded scan + digest-keyed sidecar cache.
- Preserve: R2 outbox, imports, receipts, exact export, tombstones, deletion, Watch recovery.
- Swift 6 strict concurrency; no unsafe annotations; analysis off views and off main actor.
- Reduce Motion / Dynamic Type / VoiceOver / increased contrast supported.

## Milestones

1. [ ] chore(ui): adaptive design system + RootTabView (Sessions/Progress/Settings)
2. [ ] feat(ios): Sessions screen — header, compact sync pill + sync sheet, latest card,
       recent rows, See all, empty/degraded states; remove UUID-as-title rows
3. [ ] feat(ios): Session Overview (hero chart, observation, 4 drill-ins incl. quality +
       details + export + delete) and Progress (measure + range pickers, trend,
       Personal Baseline, observation)
4. [ ] feat(watch): Start, Countdown (circular, numeric transition), Active (no scroll,
       diagnostics demoted), Hold to Finish (fill + accessibility action), Saved
       (Saved on Watch vs transfer state), Details
5. [ ] test(ui): fingerprint binning, chart prep, baseline eligibility/exclusion,
       observation suppression, row formatting, hold-to-finish logic, sync presentation
6. [ ] fix(ui): simulator QA — small/large iPhone, light/dark, AX sizes, Watch sizes;
       screenshot review; regression fixes

## Key new types

- `SessionFingerprintV1` (Shared): deterministic HR bins, gap-aware, capped input.
- `SessionObservationEngineV1` (Shared): busiest-stretch selection + suppression rules.
- `BaselineEngineV1` (Shared): distance-per-minute, eligibility, prior-session pool.
- `ChartPreparationV1` (Shared): bounded, gap-aware chart series from snapshots.
- `SessionPreviewCache` (iOS actor): bounded package scan + digest-keyed sidecar cache.
- `SessionsHomeView`, `SessionSyncSheet`, `SessionOverviewScreen` + 4 drill-ins,
  `ProgressHomeView`, `SettingsHomeView`, `RootTabView`, `PerformanceTheme`.

## Honest-state map

- Interrupted → amber "Interrupted" tag + reason in Overview quality report.
- Missing HR/motion → "No readings recorded" blocks, not zeros; fingerprint hidden.
- Pre-baseline → "Building your baseline — N of 3 valid sessions" (neutral).
- R2 unavailable → local-safe copy; retry in Settings > Sync.

## Verification

- `xcodegen generate`; discover simulator destinations (do not reuse stale UUIDs).
- Build `FootballPerformance` + `FootballPerformanceWatch`; run both test targets.
- Simulator screenshots: iPhone SE/Pro Max light+dark, AX size, Watch 41/49mm states.
- Physical-device gates reported separately (Series 8, 90-min, battery, transfers, R2).
