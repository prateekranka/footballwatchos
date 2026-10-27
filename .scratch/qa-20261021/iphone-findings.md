# iPhone QA findings, 2026-10-21 (simulator 03BB1E41, app build claude/beautify-ui)

## Bugs (verified on screen)

### P2 Interrupted session is coached as complete
- Scenario: coach. Screen: Sessions > Recent > Fri, 9 Oct (5-a-side, 40 min).
- List row says "Interrupted". Detail header has no interrupted tag.
- Detail shows coaching as if complete: "WORK ON · INTENSITY, Only 0% of the session was above 80% of your max heart rate."
- The 40 min still count in week totals and in the load baseline (usual 55 min).
- Interrupted tag only appears in list row and in "Recording quality" row.
- Source: Analysis/PerformanceCoachV1.swift insights(for:age:) does not check lifecycle. Only BaselineEngineV1.isValidSession does.
- Screenshot: /var/folders/m7/7b9v0v0d67d4mc_kfvt7hmlw0000gn/T/simserver-IQ45MI/media/206062000-1792581836236.png

### P2 Sessions shows "No sessions yet" while 1,000 rows load
- Scenario: many. Launch, then wait.
- Empty state showed for about 30 seconds. App used 90 to 160 percent CPU during that time.
- Then the week hero and list appeared (3 sessions, 180 min, 144-week streak).
- Caveat: fixture load in simulator. Real data may differ.
- Screenshots: /var/folders/m7/7b9v0v0d67d4mc_kfvt7hmlw0000gn/T/simserver-IQ45MI/media/762578000-1792582898798.png and .../817184000-1792582904843.png

### P3 Sessions hero text clips and overlaps at largest text size
- Setting: accessibility-extra-extra-extra-large. Screen: Sessions.
- Stat labels cut to "ses..." and "dist...".
- Chart date labels (30 Aug, 13 Sep, 27 Sep, 11 Oct) collide with each other and with the 500/250/0 axis labels.
- Screenshots: /var/folders/m7/7b9v0v0d67d4mc_kfvt7hmlw0000gn/T/simserver-IQ45MI/media/683252000-1792582978706.png and .../651017000-1792582988675.png

### P3 Session hero: duration touches distance
- Screen: session detail, Tue 20 Oct (default text size).
- "45 min" and "4.2 km" have no gap between them.
- Screenshot: /var/folders/m7/7b9v0v0d67d4mc_kfvt7hmlw0000gn/T/simserver-IQ45MI/media/170309000-1792583024197.png

### Not confirmed: share sheet would not close
- Screen: session Details > "Share verified package".
- Sheet stayed open after tap on dimmed area, swipe down, and Escape key.
- Could be simulator input limit. Not proven as app bug.
- Screenshot: /var/folders/m7/7b9v0v0d67d4mc_kfvt7hmlw0000gn/T/simserver-IQ45MI/media/442214000-1792582783484.png

## Works (verified on screen or by arithmetic)
- Onboarding: pages 1 to 3 show. Continue and Get started complete. Completed state sticks after relaunch.
- Coach: week hero 2 sessions, 180 min, matches list (90 + 90).
- Load spike: 330 min last 7 days = 60 + 90 + 90 + 90 (manual log counted). Usual 55 = 220 / 4.
- Heart-rate baseline 142 = mean of 4 valid prior sessions. Interrupted session excluded from baseline.
- "19% above baseline": 169 / 142. Correct.
- Manual log (Thu 15 Oct): distance and heart rate show dashes. No zones, fade, or recovery tips. Correct.
- Session Wed 21 Oct: fade 110 to 70 m/min (-36%) matches tip. Peak 177 bpm.
- Add session: presets set the field. 990 typed gives "Enter a whole number from 1 to 240 minutes."
- Add session: saved 60 min. Week went from 2 to 3 sessions, 180 to 240 min. Load 330 to 390.
- Age: Not set shows "Estimated" and "Max 190 bpm estimated". Age 31 shows 186 bpm. Z3 threshold changed 133+ to 130+.
- Worst case: week 3 sessions, 241 min. Sun 18 Oct "1 min" shows dashes for distance and heart rate.
- Worst case: Tue 20 Oct 15 s session shows "—" for heart rate, "No heart-rate readings".
- Worst case: general football-fitness tip is labelled "General football-fitness guidance".
- One session: Progress shows 1 session, 45 min, 1 week streak.
- Many: All sessions list scrolls fast with no blank rows.
- Dark mode: All sessions and Progress look correct. No clipping seen.

## Not tested
- Settings age typed values (0, 15, 120, blank, letters). Stepper only allows 10 to 80.
- Demo and worst-case details beyond the summary.
- Session delete. Blocked by share sheet state.
- Add session: "each type" (only 5-a-side used).
- Large text on session detail and Progress.
- Dark mode on Sessions hero.
- Onboarding Back button (not verified).

## Harness notes
- Launch argument -onboardingCompleted NO overrides the saved value. Use defaults write to reset (done).
- Argent asked for boot-device force=true. Not done. Tree reads worked without it.
- Argent update 0.20.0 to 0.29.0 is available. Not applied.
