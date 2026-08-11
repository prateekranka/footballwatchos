# Confirmed Batch-Grilling Decisions

These decisions were confirmed before the Wayfinder map was charted. Tickets may investigate facts and specify behavior within these boundaries, but they must not silently reopen them.

## Player and use

- The product is for one person: a left-footed RB/LB who wears an Apple Watch Series 8 on the left wrist.
- Sessions are mostly outdoor 6/7-a-side football at two or three venues surrounded by buildings.
- A typical Football Session lasts 90 minutes, currently once per week and potentially twice per week.
- The initial product is a personal development build only.

## Recording experience

- The Apple Watch app is the primary product. It independently records Football Sessions on Series 8 using HealthKit, GPS, heart rate, and motion evidence.
- The iPhone app is a companion for post-session syncing, charts, and analysis; it must not replace or defer the Watch recording target.
- Apple Watch records the entire Football Session without an iPhone or network connection.
- Starting requires one large Start Football control, a three-second countdown, and a confirmation haptic.
- The active screen shows recording status, elapsed time, current heart rate, and distance.
- Recording never auto-pauses and does not model halves, scoring, substitutions, or match structure.
- v1 has no live coaching. Haptics are limited to recording lifecycle and critical recording problems.
- Finish is a deliberate two-step, press-and-hold action followed by clear save confirmation.
- Foreground loss must not end recording; reopening returns to the active Football Session whenever watchOS permits.
- The original recording is preserved. iPhone may suggest a likely trim, but only the user confirms it.

## Analysis experience

- Apple Watch shows a small immediate saved-session summary; iPhone owns the deep report after sync.
- Reports are chart-first, centered on a synchronized timeline of heart rate, speed, intensity, high-intensity intervals, and Estimated Actions.
- Supporting views include route and normalized pitch heat map when evidence permits, heart-rate zones, speed and effort distributions, work/recovery intervals, Estimated Action timeline, and a summary table.
- Reports may include one or two factual statements linked to supporting charts, not an opaque overall score or generated coaching narrative.
- App charts use processed per-second or interval data. Full-resolution evidence remains available through export for R&D.
- The first three Valid Sessions establish the Personal Baseline. Later comparisons use the previous four Valid Sessions and optionally one selected session.
- Before a baseline exists, reports show neutral absolute measurements without better/worse language.
- Optional post-session input is perceived exertion from 1–10, a short note, and an RB/LB correction; Fullback is the default role.
- No streaks or twice-weekly goal tracking appear in v1.

## Physical performance scope

- The physical report covers distance, heart-rate zones and load, speed and sprint efforts, high-intensity work, work/rest and recovery patterns, route and spatial distribution when reliable, time intervals, late-session drop-off, trends, and calories.
- Sprint and high-intensity thresholds are personalized while raw values remain inspectable.
- Performance is compared only with the player’s own history, not generic position or population norms.
- The product reports observable performance evidence and makes no readiness, injury-risk, medical, or safe-to-play claims.

## Estimated football actions

- The conditional detector targets only probable passes, probable shots or powerful kicks, and dribble/carry bursts.
- These results are always named Estimated Actions and carry a quality indicator.
- Approximate automatic estimates are acceptable, but a feature stays hidden until it reaches at least 80% precision across three unseen real sessions; recall is measured separately.
- Low-quality evidence suppresses the affected Estimated Actions instead of producing confident-looking numbers.
- Pass completion, shot outcome, exact touch counts, possession time, tackles, and interceptions are excluded because the Watch cannot observe the required ball or player state.
- Estimated Actions are essential to the longer product direction but may be absent from the first usable foundation milestone.

## Calibration and evidence

- The detector is personalized for this player in v1.
- A Calibration Session includes ordinary walking/running negatives, passes of different strengths, powerful kicks/shots, dribble/carry sequences, sprints, and direction changes while the Watch is worn normally.
- Temporary stationary sideline video may provide ground truth for roughly five to ten sessions.
- An internal candidate-review workflow should minimize labelling time; it is not part of the shipped product.
- Local Mac analysis and model training are allowed for R&D, but normal use never depends on the Mac.
- Validation video is deleted after its labels are checked.
- Garmin Forerunner 35 may be worn during R&D as comparison evidence for GPS, distance, pace, and heart rate, but Garmin import is not a product feature.

## Venue and signal quality

- iPhone lets the user draw or adjust a Venue over a map, then recognizes and reuses it.
- Venue setup improves spatial analysis but never blocks recording.
- Unknown venues or poor GPS preserve the Football Session, show evidence quality, and omit normalized spatial claims when necessary.
- Weather is out of scope.

## Data, privacy, and lifecycle

- HealthKit and private device storage hold normal-use data; private iCloud storage may be used only within the selected no-server architecture.
- Raw GPS and motion evidence may be retained privately during detector R&D.
- Health or motion data is not uploaded to an application server in v1.
- A Football Session, raw calibration evidence, and all app-owned data can be exported or deleted independently.
- Deleting app-owned data must not alter unrelated HealthKit records.

## Delivery and proof boundaries

- Delivery is sequenced as dependable recorder, physical report, calibration/ground-truth capability, then conditional Estimated Actions.
- The foundation must prove three consecutive real 90-minute sessions without data loss, offline recording without the iPhone, successful sync and reopen, measured GPS/heart-rate/motion coverage, measured battery drain, and honest degraded states.
- Garmin comparisons are evidence, not truth by assumption.
- No numeric battery threshold is assumed before physical measurement on the Series 8.
