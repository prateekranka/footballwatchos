# Watch Football-Session Experience Specification

Status: specified for implementation (ticket 07)
Scope: personal, Watch-first outdoor soccer recorder; watchOS 26; Swift 6; Apple Watch Series 8.
Sources: [confirmed decisions](../decisions.md), [ticket 07](../issues/07-specify-watch-session-experience.md)

## States

The Watch app is a single state machine rendered by one root view. States:

| State | Meaning | Exit conditions |
|---|---|---|
| `authorizing` | Requesting HealthKit authorization on first launch | success → `idle`; denied/error → `failed` |
| `idle` | Ready to record; shows Start control, plus recovery notices from launch-time package audit | Start pressed → `countdown` |
| `countdown` | 3-2-1 visible countdown, cancellable | completes → `starting`; cancel → `idle` |
| `starting` | Workout session + builder are opening | opened → `active`; error → `failed` |
| `active` | Recording; single live screen | Hold-to-Finish → `finishing`; system ends session → `finishing` (partial seal) |
| `finishing` | Sealing package, saving HealthKit workout, draining motion | success → `saved`; storage error → `failed` |
| `saved` | Immediate summary + sync/Health outcome | Done → `idle` |
| `failed` | Terminal problem for this attempt | Try Again → `idle` |

At every launch the recorder audits interrupted package files (recover, quarantine,
or report) and surfaces the result as a recovery notice on `idle`. The states are
the contract; the current probe's `WorkoutRecorder.phase` already mirrors this.

## Requirements and acceptance rules

### R1 — Start

1. `idle` shows exactly one large primary control: "Start Football".
2. Pressing it begins a visible 3-2-1 countdown with a Cancel control. The
   countdown is the only path into `starting`; no tap can start instantly.
3. When the workout actually opens, the watch plays a single `.start` haptic.
   Acceptance: press → countdown → haptic at open; cancel during countdown
   returns to `idle` with no workout or haptic.
4. Starting requires HealthKit workout authorization. Without it, `failed` with a
   retry that re-requests authorization.

### R2 — Active screen

1. Exactly one recording screen: "RECORDING" marker, elapsed time, current heart
   rate, and distance. No pages, no scrolling requirement to see elapsed.
2. Missing values render as "—" or "No reading", never as zero or a fabricated
   number. Acceptance: disable the HR feed for a minute; the tile shows "—".
3. The screen contains the Hold-to-Finish control at all times.
4. The R&D motion-diagnostics card is allowed on this screen only while ticket 01
   remains unresolved; the shipped build removes it from `active` and keeps it,
   if at all, only on `saved`.

### R3 — No auto-pause, no match structure

1. The recorder never calls pause; a running session is never paused by the app.
   Acceptance: wrist-down, stillness, and arm behind the body do not change
   elapsed accumulation.
2. No halves, scoring, substitutions, match clock, or role input exists on the
   Watch. No live coaching text, goals, or performance commentary.

### R4 — Protected Finish

1. Finish is deliberate: press-and-hold (hold duration ≥ 1.0 s) with a visible
   press state, followed by a save confirmation ("Saved on Watch") screen.
2. A brief tap, a swipe, or the Crown must not end a session. Acceptance: tap the
   Finish control repeatedly for < hold duration; the session remains `active`.
3. Finishing is single-shot: once started, a second hold is ignored.

### R5 — Background and reopen

1. Foreground loss (wrist-down, another app, notification) never ends recording;
   the HealthKit workout session keeps the app alive as an active workout.
2. Reopening the app during a live session returns directly to `active` with the
   correct elapsed time. Acceptance: background for 10 minutes; reopen shows
   elapsed ≈ time since start, not restarted.
3. Scene-phase changes are logged only; they do not mutate state.

### R6 — Interruptions and unexpected ends

1. If the system ends the workout while `active` (user-initiated system stop,
   crash of the session), the recorder seals a partial package with a quality
   error ("The workout ended before Finish was held."), moves to `saved` (not
   `failed`), and the summary displays the quality warning.
2. If the app is terminated mid-session, the partial package survives on disk.
   Next launch audits it: readable → recovered and reported on `idle`;
   unreadable → quarantined and reported. The original bytes are never deleted
   silently.
3. HealthKit save failure after a successful finish must not discard the
   package: the summary shows the Health outcome ("Health workout was not
   saved") while the session itself is intact and syncable.

### R7 — Sensor-quality warnings

1. If heart rate produces no sample for ≥ 5 continuous minutes while `active`,
   show a non-blocking warning on the active screen and attach a
   `captureQualityError` to the summary. The session continues.
2. If distance stops advancing while GPS is expected (≥ 10 minutes flat while the
   player is known-moving), apply the same warning treatment.
3. Motion-stream errors appear in the diagnostics card and the summary, never as
   silent data. Warnings are factual ("No heart-rate reading for the last 5
   minutes"), never interpretive ("You are unfit").

### R8 — Battery

1. Before start, battery ≤ 20% shows an orange warning on `idle`; the start
   control remains enabled. Acceptance: start at 15%; recording proceeds and the
   warning persists into `active`.
2. During `active`, crossing ≤ 10% adds a non-blocking banner. Recording never
   stops itself for battery; sealing on low battery is the recorder's job, not
   the user's.

### R9 — Original-recording preservation

1. The Watch never trims, edits, or rewrites a saved package. Trim, if ever
   offered, is an iPhone-side suggestion requiring user confirmation.
2. "Done" on `saved` only resets in-memory state; the package remains in the
   outbox until the iPhone confirms import.

### R10 — Immediate saved summary

1. `saved` shows: duration, distance, average heart rate (or "No reading"),
   HealthKit save outcome, sync status (waiting / imported / needs attention),
   any capture-quality warnings, and the Done control.
2. The summary renders from the sealed package, not from live streams, so the
   numbers match what sync will deliver. Acceptance: finish, compare summary
   distance to the synced package; identical.

## Non-goals

Live coaching, haptics beyond recording lifecycle, RPE input on the Watch,
halves/subs/scores, auto-pause, trim on the Watch, streak or goal messaging,
cloud processing.
