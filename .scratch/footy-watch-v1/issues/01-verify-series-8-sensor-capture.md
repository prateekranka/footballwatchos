# Verify Series 8 Sensor Capture

Type: prototype
Status: claimed
Assignee: Codex
Blocked by: none
Part of: [Personal Apple Watch Football Performance System](../map.md)

## Question

On the physical Apple Watch Series 8, which supported Core Motion capture path provides accelerometer and device-motion evidence during an active HealthKit soccer workout, and what measured sample rates, gaps, API constraints, energy cost, and thermal behavior determine the go/no-go capture configuration for later action-candidate research?

## Comments

### 2026-07-28 — Build attempt stopped at the required Advisor gate

- Confirmed the target as paired hardware `Watch6,15` running watchOS 26.5 and preserved the watchOS-first architecture: Watch records independently; iPhone is only the post-session companion.
- Xcode 26.6, watchOS SDK 26.5, Swift 6.3.3, and XcodeGen 2.45.3 are installed; App Creator’s doctor passed.
- The App Creator scaffold was not used because its available template is iOS-only and refuses this non-empty planning workspace. The intended route is an explicit watchOS + companion iOS XcodeGen configuration.
- No app source, Xcode project, generated build artifact, or executor work was created.
- The required Advisor returned `Runtime metadata has a malformed modelUsage value`; the claim was released so a fresh task can resume this ticket safely.

### 2026-07-28 — Compile-ready physical capture probe built (NOT_ADVISOR_APPROVED)

- The user explicitly authorized continuation as `NOT_ADVISOR_APPROVED` after the Advisor bridge failure. Ticket 1 was reclaimed by Codex.
- Created an explicit modern Watch application target plus subordinate iPhone companion. The Watch bundle is `com.prateekranka.footballperformance.watchapp`, declares independent operation, embeds the HealthKit entitlement and workout-processing background mode, and is embedded into the iPhone target through Xcode’s `Embed Watch Content` phase.
- The Watch flow now requests HealthKit access, runs a three-second countdown, starts an outdoor `.soccer` `HKWorkoutSession` with `HKLiveWorkoutBuilder`, shows elapsed time, live heart rate, and distance, requires a press-and-hold finish, saves the workout, and presents the capture summary.
- Motion diagnostics prefer `CMBatchedSensorManager` when both accelerometer and device-motion batching are supported. The app records each stream’s reported frequency, delivered samples, batches, and maximum timestamp gap. If batching is unavailable, it labels `CMMotionManager` as a 50 Hz foreground diagnostic fallback and makes no background-equivalence claim.
- XcodeGen 2.45.3 generated both targets. A generic watchOS 26.5 build succeeded for `arm64_32` and `arm64`; the generic iOS Simulator build also succeeded while compiling and embedding the Watch app. Both source sets additionally passed direct SDK type-checks.
- A dedicated 45 mm Series 8 watchOS 26.5 simulator accepted and launched the modern single-target bundle. The signed launch reached Apple’s Health Access review sheet; the evidence image is `evidence/watch-series8-signed-launch.png`. This proves packaging and launch only, not sensor behavior.
- The physical target is still confirmed as paired `Watch6,15` on watchOS 26.5, but `devicectl` reports its local-network connection as disconnected. No physical samples, delivered frequency, gap distribution, energy cost, or thermal behavior have been measured yet.
- Status remains `claimed`, not `resolved`. Resolution still requires a signed install and real Series 8 workout run with the on-Watch diagnostics recorded; therefore Tickets 02 and 09 remain blocked.

### 2026-07-28 — Provisional 90-minute battery planning hypothesis

- This is a planning estimate, not physical-device evidence: budget roughly **20–30 battery percentage points** for a 90-minute session on a healthy Series 8 battery. If Battery Health Maximum Capacity is near 80%, plan closer to **25–38 points**.
- Outdoor built-in GPS and high-frequency workout heart-rate capture are expected to be the main loads. This GPS-only Series 8 uses its own GPS during the workout even when an iPhone is nearby; no music, LTE/networking, or active sync should reduce avoidable load.
- The batched Core Motion path remains the intended capture path. The 50 Hz foreground `CMMotionManager` fallback could push total drain beyond 30%, so capture path and battery cost are part of this ticket’s physical go/no-go evidence.
- Use **60% starting charge** only as a provisional operating floor. For the first real field run, start at 100% and record: start/end charge, Battery Health Maximum Capacity, selected capture path, delivered sample rates and gaps, temperature or thermal behavior, display settings, and Low Power Mode state.
- Official anchors: [Apple Watch battery testing and full-GPS/heart-rate workout assumptions](https://www.apple.com/sg/watch/battery/), [Apple Watch calibration guidance and the Series 8 built-in GPS note](https://support.apple.com/en-asia/105048), and [HealthKit running workout sessions](https://developer.apple.com/documentation/HealthKit/running-workout-sessions).
- Status remains `claimed`; this hypothesis does not unblock Tickets 02 or 09 and must be replaced by measured Series 8 evidence before resolution.
