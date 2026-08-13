# Session Data Findings (Apple Health Export, Aug 2026)

Source: `export.zip` Apple Health export provided by the player, containing
`export.xml` (281 MB) and two 2025 workout-route GPX files.

## What the export contains

- 22 workouts labelled `HKWorkoutActivityTypeSoccer`.
- 16 are real Football Sessions recorded by `Bobby's Watch` (native Workout app,
  not this product), weekly on Saturdays from 2026-01-26 through 2026-08-08.
  The 2026-01-26 session was a Monday; all others are Saturdays.
- 6 are `Football Performance`-source recordings (2026-08-09 / 2026-08-10, 0.3 to
  5.0 minutes, near-zero stats). These are the player's own test sessions of the
  in-development recorder. They confirm the recorder saves a HealthKit workout,
  but no distance/route and negligible energy in short tests.
- The two GPX route files are dated 2025 and do not correspond to any soccer
  workout, so no soccer GPS route data exists in this export.

## Observed ranges (16 real sessions)

| Observation | Range | Mean | Last session (2026-08-08) |
|---|---|---|---|
| Duration | 53.8–98.4 min | ~77 min | 68.4 min |
| Distance | 1.89–3.78 km | 2.68 km | 3.07 km |
| Average heart rate | 115–190 bpm | 169 bpm | 190 bpm |
| Max heart rate | 158–210 bpm | — | 210 bpm |
| Active energy | 221–679 kcal | 453 kcal | 574 kcal |
| Active energy rate | 3.5–9.8 kcal/min | ~6.2 kcal/min | 8.4 kcal/min |

Age-predicted max heart rate (220 − 35) = 185 bpm. Mean session average heart
rate sits at ~91% of that predicted maximum.

## Heart-rate capture quality

Sample counts per session vary from 3 to 615. Early sessions (Jan–Mar) show
3–36 samples (sensor dropout). Even the best-covered sessions sample roughly one
beat per 8–12 seconds, not the one-per-few-seconds expected in workout mode.
Peak readings above ~200 bpm are likely inflated by optical-sensor motion
artifact (wrist flexion, ball contact). Interpretation: heart rate is genuinely
high and near-maximal, but the peaks are noisy and several sessions' averages are
built on sparse data.

## Distance capture quality

Average "speed" computed as distance/duration is 1.4–2.7 km/h, which is not
physical for football. The venue is 6/7-a-side and surrounded by buildings
(see decisions.md), so GPS undercounts. Distance numbers here are lower bounds.

## Implications for roadmap tickets

- 01 (Series 8 sensor capture) / 03–04 (primary-venue GPS evidence): this export
  is evidence that, at the player's venue, GPS distance is unreliable and optical
  heart rate is sparse during play. It does not replace the required on-device
  proof, but it names the two weakest sensors and confirms the Garmin Forerunner
  comparison (decisions.md) as the right evidence channel.
- 08 (physical metrics): sprint and speed efforts derived from GPS at this venue
  will be unreliable; personalized thresholds must absorb that noise, and
  motion-derived bursts are the more credible source for sprint/high-intensity work.
- 13 (Estimated-action R&D gate): the raw motion needed for passes/shots/carries
  is exactly the signal that matters here, because GPS and optical HR are the
  degraded channels.
- 14 (foundation proof gates): HR dropout and GPS undercount are concrete
  degradation states the proofs must cover.

## Comparison to pre-export baseline

The pre-export research baseline estimated a sedentary 35-year-old recreational
player at ~3–4 km distance and ~155–168 bpm average heart rate. Actuals: ~2.7 km
(lower, GPS-limited) and ~169 bpm mean (higher, near-maximal effort). The
distance shortfall is primarily sensor undercount, not lower work rate; the
heart-rate excess reflects a weekly-only player working near the ceiling.
No conditioning trend is visible across the 7-month series; the series is too
short and too noisy to read improvement.
