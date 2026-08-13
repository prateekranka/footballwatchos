# Primary Venue GPS Survey Protocol

Status: protocol specified (ticket 03); physical evidence not yet captured
Scope: personal, Watch-first outdoor soccer recorder; Apple Watch Series 8 + Garmin Forerunner 35.
Sources: [ticket 03](../issues/03-capture-primary-venue-gps-evidence.md), [decisions](../decisions.md), [session-data findings](../evidence/session-data-findings.md)

## Purpose

One repeatable single-session survey at the named primary Venue produces the
evidence ticket 04 needs: fix coverage, drift, distance disagreement, route
stability, and the effect of surrounding buildings. The Garmin Forerunner 35 is
a comparison reference, never ground truth; measured course dimensions are the
primary truth for distance.

## Preconditions

- Name the primary Venue first (the pitch used most Saturdays) and measure its
  dimensions from a map before the survey: perimeter, both touchlines, both goal
  lines, both diagonals, half-pitch length.
- Dry weather, ~45–60 minute slot, both devices charged. Watch starts at 100%
  and battery start/end % is recorded; Battery Health Maximum Capacity is noted.
- Low Power Mode off; no music, calls, or other apps during the survey.
- Garmin Forerunner 35 waits for GPS lock before the survey begins; the Watch
  app's football session is started from the centre spot.

## Course (fixed order, single session)

| # | Segment | Purpose |
|---|---|---|
| 1 | Stand still at centre spot, 3 min | drift baseline |
| 2 | Perimeter walk, lap 1 (clockwise) | total-course distance vs GPS |
| 3 | Near-side touchline walk (building side) | building-shadow split |
| 4 | Far-side touchline walk (open side) | open-sky split |
| 5 | Goal line walk (both ends) | short-leg accuracy |
| 6 | Two diagonal walks | diagonal distance accuracy |
| 7 | Figure-8 across half pitch, twice | turning behavior |
| 8 | 10 × half-pitch shuttles at jog | intermittent movement |
| 9 | 5 × half-pitch shuttles at sprint | high-speed GPS behavior |
| 10 | Perimeter walk, lap 2 (counter-clockwise) | route stability vs lap 1 |

The Watch app records one football session across the whole course. The Garmin
records the same period. Segment start times are noted so splits can be matched.

## Data sheet

| Field | Value |
|---|---|
| Venue name + measured dimensions | |
| Watch battery start/end %, battery health | |
| Watch app final distance (summary + Health) | |
| Garmin final distance and track export | |
| Garmin fix quality during the stand | |
| Observed drift (metres moved while standing) | |
| Any signal warnings from either device | |

## Analysis and sufficiency thresholds for ticket 04

- **Distance disagreement**: Watch vs Garmin vs measured course. > 10% vs the
  measured perimeter is a red flag; > 20% means distance-dependent spatial
  metrics are unreliable at this Venue.
- **Fix coverage**: fraction of expected survey time with track points. ≥ 90%
  supports spatial claims; below, degrade.
- **Drift**: > 15 m of apparent movement during the 3-minute stand means route
  evidence is too noisy for normalized-pitch claims.
- **Route stability**: lap 1 vs lap 2 overlay displacement (RMS). Stable laps
  support route shapes; wobble does not invalidate distance totals.
- **Building effect**: compare near-side vs far-side splits. A consistent
  near-side error ≥ 2× the far-side error names the building face for ticket 04.

## Notes

- The two 2025 walking GPX routes in the player's Health export are unrelated
  locations; this survey is the first Venue evidence.
- The current probe does not save `HKWorkoutRoute`; Watch-side analysis uses the
  session summary distance and the Health workout. Route-shape analysis uses the
  Garmin track. If route saving is added before the survey, include the Watch
  route in the same comparisons.
