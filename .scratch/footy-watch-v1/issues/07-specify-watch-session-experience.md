# Specify the Watch Football-Session Experience

Type: task
Status: resolved
Blocked by: none
Part of: [Personal Apple Watch Football Performance System](../map.md)

## Question

What complete state-level Watch experience and acceptance rules implement the confirmed Start countdown and haptic, single active screen, no auto-pause, protected Finish, background and reopen behavior, interruptions and permission failures, low-battery or sensor-quality warnings, original-recording preservation, and immediate saved-session summary without introducing live coaching or match structure?

## Resolution

- [Watch Football-Session Experience Specification](../specs/07-watch-session-experience.md)

## Comments

### 2026-08-13 — Specified

- Wrote the complete state-level specification with acceptance rules (states
  `authorizing`/`idle`/`countdown`/`starting`/`active`/`finishing`/`saved`/`failed`,
  requirements R1–R10, non-goals) in `specs/07-watch-session-experience.md`.
- The spec aligns with the confirmed decisions and with the existing probe's
  `WorkoutRecorder.phase` states; it adds the missing contract for battery
  warnings (≤20% pre-start, ≤10% during), sensor-quality warnings (≥5 min silent
  HR, ≥10 min flat distance), scene-phase reopen, and interruption sealing.
- The probe already implements interrupted-package audit/recovery, unexpected-end
  partial sealing, Hold-to-Finish, and the saved summary; deviations between
  probe and spec are listed in the spec.
