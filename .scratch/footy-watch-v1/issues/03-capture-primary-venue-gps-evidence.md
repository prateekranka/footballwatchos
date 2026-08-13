# Capture the Primary Venue GPS Evidence

Type: task
Status: open
Blocked by: none
Part of: [Personal Apple Watch Football Performance System](../map.md)

## Question

What repeatable single-session survey protocol and captured Apple Watch Series 8 plus Garmin Forerunner 35 reference evidence at the user’s named primary Venue are sufficient to measure fix coverage, drift, distance disagreement, route stability, and the effect of surrounding buildings without treating Garmin as ground truth?

## Comments

### 2026-08-13 — Survey protocol specified; awaiting the physical survey

- Wrote the repeatable single-session protocol, data sheet, and sufficiency
  thresholds in `research/03-primary-venue-gps-survey.md`: 10 fixed segments
  (stand drift baseline, two perimeter laps, touchline/goal-line/diagonal
  walks, figure-8, jog and sprint shuttles), Watch app + Garmin recording one
  continuous session, measured course dimensions as primary truth for distance.
- Thresholds for ticket 04: >10% distance disagreement red flag, ≥90% fix
  coverage, ≤15 m stand drift, stable lap overlay, building-side split error
  ≤2× open-side.
- Precondition: the player names the primary Venue and measures its dimensions
  from a map before the survey. The player's Health-export walking GPX files
  are unrelated locations and provide no prior Venue evidence.
- Status stays `open`: the protocol exists, the captured evidence does not.
