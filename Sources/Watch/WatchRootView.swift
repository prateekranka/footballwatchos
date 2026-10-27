import SwiftUI

private enum WatchTheme {
    static let accent = Color(red: 0.22, green: 0.72, blue: 0.42)
    static let onAccent = Color(red: 8.0 / 255, green: 36.0 / 255, blue: 18.0 / 255)
    static let highlight = Color(red: 0.80, green: 1.00, blue: 0.40)
    static let heart = Color(red: 1.00, green: 0.42, blue: 0.42)
    static let movement = Color(red: 0.30, green: 0.72, blue: 1.00)
    static let warning = Color(red: 1.00, green: 0.76, blue: 0.28)
    static let pitch = Color(red: 11.0 / 255, green: 58.0 / 255, blue: 34.0 / 255)
    static let muted = Color(red: 156.0 / 255, green: 201.0 / 255, blue: 174.0 / 255)

    static func zoneColor(_ zone: WatchEffortZone) -> Color {
        switch zone {
        case .easy: Color(red: 0.55, green: 0.66, blue: 0.75)
        case .light: movement
        case .moderate: accent
        case .hard: Color(red: 0.96, green: 0.55, blue: 0.10)
        case .max: heart
        }
    }
}

enum WatchEffortZone: Int, CaseIterable {
    case easy = 1, light, moderate, hard, max

    static let fallbackMaximumHeartRate: Double = 190

    /// Set from the player's age on the iPhone; 190 until the iPhone sends one.
    static var playerMaximumHeartRate: Double {
        let stored = UserDefaults.standard.double(forKey: PlayerProfileContextV1.maximumHeartRateKey)
        return stored > 0 ? stored : fallbackMaximumHeartRate
    }

    static func current(
        heartRate: Double?,
        maximumHeartRate: Double = playerMaximumHeartRate
    ) -> WatchEffortZone? {
        guard let heartRate, heartRate.isFinite, heartRate > 0,
              maximumHeartRate.isFinite, maximumHeartRate > 0 else { return nil }
        switch heartRate / maximumHeartRate {
        case ..<0.6: return .easy
        case ..<0.7: return .light
        case ..<0.8: return .moderate
        case ..<0.9: return .hard
        default: return .max
        }
    }

    var name: String {
        switch self {
        case .easy: "Easy"
        case .light: "Light"
        case .moderate: "Moderate"
        case .hard: "Hard"
        case .max: "Max"
        }
    }

    var label: String { "Zone \(rawValue) · \(name)" }
}

private struct WatchCapsuleStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .foregroundStyle(primary ? WatchTheme.onAccent : WatchTheme.muted)
            .background(primary ? WatchTheme.accent : WatchTheme.pitch, in: Capsule())
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

private struct WatchDetailRow: View {
    let title: String
    let value: String
    var tint: Color = .white
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        layout {
            Text(title)
                .font(.caption)
                .foregroundStyle(WatchTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
            Text(value)
                .font(.system(.body, design: .rounded).bold())
                .monospacedDigit()
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(WatchTheme.pitch, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct WatchMotionPresentation {
    let label: String
    let tint: Color
    let symbol: String

    init(snapshot: MotionCaptureSnapshot) {
        let hasStreamError = snapshot.accelerometer.lastError != nil
            || snapshot.deviceMotion.lastError != nil
        let maximumGap = max(snapshot.accelerometer.maxGap, snapshot.deviceMotion.maxGap)
        let degraded = hasStreamError || maximumGap >= 5
        let unavailable: Bool
        if case .unavailable = snapshot.source { unavailable = true } else { unavailable = false }
        let hasSamples = snapshot.accelerometer.sampleCount > 0 || snapshot.deviceMotion.sampleCount > 0
        label = unavailable ? "Motion unavailable"
            : degraded ? "Motion degraded"
            : hasSamples ? "Motion OK" : "Waiting for motion"
        tint = unavailable || degraded ? WatchTheme.warning
            : hasSamples ? WatchTheme.accent : WatchTheme.muted
        symbol = unavailable || degraded ? "exclamationmark.circle.fill"
            : hasSamples ? "waveform.path" : "circle.dotted"
    }
}

/// How long the finish gesture must be held. Matches the default of
/// `HoldToFinishModel` and the long-press `minimumDuration`.
private let holdToFinishDuration: TimeInterval = 1.25

struct WatchRootView: View {
    @ObservedObject var recorder: WorkoutRecorder
    @ObservedObject var motionCapture: MotionCaptureController

    var body: some View {
        NavigationStack {
            Group {
                switch recorder.phase {
                case .authorizing:
                    ProgressView("Preparing Health")

                case .idle:
                    StartFootballView(recorder: recorder)

                case .countdown(let value):
                    CountdownView(value: value, cancel: recorder.cancelCountdown)

                case .starting:
                    ProgressView("Starting workout")

                case .active:
                    ActiveFootballView(
                        recorder: recorder,
                        motionCapture: motionCapture
                    )

                case .finishing:
                    ProgressView("Saving session")

                case .saved(let summary):
                    SavedSessionView(
                        summary: summary,
                        syncCoordinator: recorder.syncCoordinator,
                        recordAnother: recorder.resetAfterResult
                    )

                case .failed(let message):
                    FailureView(
                        message: message,
                        retry: recorder.retryAfterFailure
                    )
                }
            }
            .background(Color.black)
            .task {
                recorder.prepare()
            }
        }
        .tint(WatchTheme.accent)
    }
}

// MARK: - Start

private struct StartFootballView: View {
    @ObservedObject var recorder: WorkoutRecorder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("FOOTBALL")
                        .font(.caption2)
                        .tracking(1.5)
                        .foregroundStyle(WatchTheme.highlight)
                    Text("Ready")
                        .font(.title2.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                Button(action: recorder.startCountdown) {
                    Label("Kick off", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(WatchCapsuleStyle(primary: true))
                .accessibilityHint("Starts after a three second countdown")
                .accessibilityIdentifier("watch.start")

                NavigationLink {
                    WatchSessionTypePicker(selection: $recorder.selectedSessionType)
                } label: {
                    HStack {
                        Text(recorder.selectedSessionType.title)
                            .font(.body)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption2.bold())
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(WatchCapsuleStyle())
                .accessibilityLabel("Session type, \(recorder.selectedSessionType.title)")
                .accessibilityIdentifier("watch-session-type")

                NavigationLink {
                    RecoveryStatusView(recorder: recorder)
                } label: {
                    HStack {
                        Label("Session Recovery", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if recorder.recoveryAggregate?.attentionRequired == true {
                            Circle()
                                .fill(WatchTheme.warning)
                                .frame(width: 8, height: 8)
                                .accessibilityLabel("Recovery or transfer work remains")
                                .accessibilityIdentifier("watch.recovery.attention")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(WatchCapsuleStyle())
                .accessibilityHint("Shows interrupted sessions and iPhone transfer status")
                .accessibilityIdentifier("watch.recovery.open")
            }
            .padding(.horizontal, 8)
        }
        .accessibilityIdentifier("watch.idle")
    }
}

private struct WatchSessionTypePicker: View {
    @Binding var selection: FootballSessionTypeV1
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(FootballSessionTypeV1.allCases) { type in
                    Button {
                        selection = type
                        dismiss()
                    } label: {
                        HStack {
                            Text(type.title)
                            Spacer(minLength: 4)
                            if selection == type {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(WatchTheme.highlight)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .buttonStyle(WatchCapsuleStyle())
                    .accessibilityAddTraits(selection == type ? [.isSelected] : [])
                    .accessibilityIdentifier("watch.session-type.\(type.rawValue)")
                }
            }
        }
        .navigationTitle("Session type")
    }
}

// MARK: - Session Recovery

/// Proven recovery/transfer screen. Kept feature-complete: aggregate rows,
/// progress bars, per-session log, Recover button, Home button.
private struct RecoveryStatusView: View {
    @ObservedObject var recorder: WorkoutRecorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let aggregate = recorder.recoveryAggregate {
                    VStack(spacing: 4) {
                        statusRow(
                            "Needs recovery",
                            value: "\(aggregate.needsRecoveryCount)",
                            emphasized: aggregate.needsRecoveryCount > 0
                        )
                        .accessibilityIdentifier("watch.recovery.needed")
                        statusRow(
                            "Recovered",
                            value: "\(aggregate.recoveredCount)/\(aggregate.sourceSessionCount)",
                            emphasized: false
                        )
                        .accessibilityIdentifier("watch.recovery.recovered")
                        statusRow(
                            "Waiting for iPhone",
                            value: "\(aggregate.waitingForIPhoneCount)",
                            emphasized: false
                        )
                        .accessibilityIdentifier("watch.recovery.waiting")
                        statusRow(
                            "Saved sessions",
                            value: "\(aggregate.savedSessionCount)",
                            emphasized: false
                        )
                        .accessibilityIdentifier("watch.recovery.saved")
                        statusRow(
                            "Imported",
                            value: "\(aggregate.importedCount)",
                            emphasized: false
                        )
                        if aggregate.notRequestedByPhoneCount > 0 {
                            statusRow(
                                "No resend needed",
                                value: "\(aggregate.notRequestedByPhoneCount)",
                                emphasized: false
                            )
                        }
                        statusRow(
                            "Needs attention",
                            value: "\(aggregate.needsAttentionCount)",
                            emphasized: aggregate.needsAttentionCount > 0
                        )
                    }

                    if aggregate.sourceSessionCount > 0 {
                        if aggregate.needsRecoveryCount > 0 {
                            recoveryProgress(
                                progress: Double(aggregate.recoveredCount),
                                total: Double(aggregate.sourceSessionCount),
                                label: "Recovered \(aggregate.recoveredCount) of \(aggregate.sourceSessionCount)"
                            )
                        } else if aggregate.notRequestedByPhoneCount == 0 {
                            let transferTotal = Double(max(aggregate.recoveredCount, 1))
                            recoveryProgress(
                                progress: Double(aggregate.importedCount),
                                total: transferTotal,
                                label: "Transferred \(aggregate.importedCount) of \(aggregate.recoveredCount) to iPhone"
                            )
                        }
                    }

                    if aggregate.sourceSessionCount == 0 {
                        Label("No interrupted sessions", systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(WatchTheme.muted)
                    } else if aggregate.allSessionsTransferred {
                        Label("All sessions transferred", systemImage: "checkmark.icloud.fill")
                            .font(.caption.bold())
                            .foregroundStyle(WatchTheme.accent)
                            .multilineTextAlignment(.center)
                            .accessibilityHint("Every recovered session has an iPhone receipt")
                    }
                    if aggregate.notRequestedByPhoneCount > 0 {
                        Text("The iPhone already knows these sessions or you deleted its copies. Their files stay on this Watch.")
                            .font(.footnote)
                            .foregroundStyle(WatchTheme.muted)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    ProgressView("Checking…")
                }

                if !recorder.recoveryLog.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(recorder.recoveryLog) { entry in
                            RecoveryLogRow(entry: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("watch.recovery.log")
                }

                if let message = recorder.recoveryMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.warning)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("watch.recovery.message")
                }

                Button {
                    recorder.recoverInterruptedSessionsNow()
                } label: {
                    if recorder.isRecovering {
                        HStack {
                            ProgressView()
                            Text("Recovering…")
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Label("Recover Sessions", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(WatchCapsuleStyle())
                .controlSize(.large)
                .disabled(recorder.isRecovering)
                .accessibilityHint("Recovers interrupted sessions and queues them for iPhone transfer")
                .accessibilityIdentifier("watch.recovery.recover")

                Button {
                    dismiss()
                } label: {
                    Label("Home", systemImage: "house.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(WatchCapsuleStyle(primary: true))
                .accessibilityHint("Returns to the Football home screen")
                .accessibilityIdentifier("watch.recovery.home")
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Session Recovery")
        .accessibilityIdentifier("watch.recovery.screen")
        .task {
            await recorder.refreshRecoveryAggregate()
        }
    }

    private func statusRow(_ title: String, value: String, emphasized: Bool) -> some View {
        WatchDetailRow(title: title, value: value, tint: emphasized ? WatchTheme.warning : .white)
    }

    private func recoveryProgress(progress: Double, total: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: progress, total: total)
                .tint(WatchTheme.accent)
            Text(label)
                .font(.caption2)
                .fontDesign(.rounded)
                .bold()
                .foregroundStyle(WatchTheme.muted)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// One recovered/queued/failed session line: human-readable identity, never
/// the opaque package filename.
private struct RecoveryLogRow: View {
    let entry: SessionRecoveryLogEntryV1

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: iconName)
                .font(.caption)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.bold())
                    .lineLimit(2)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.muted)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(WatchTheme.pitch, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var title: String {
        if let startedAt = entry.startedAt {
            return SessionDisplayFormatting.sessionTime(startedAt)
        }
        return "Session"
    }

    private var detail: String {
        switch entry.outcome {
        case .failed:
            return entry.message
        case .recovered, .queued:
            var parts: [String] = []
            parts.append(entry.outcome == .recovered ? "Recovered" : "Queued for transfer")
            if let duration = entry.duration {
                parts.append(SessionDisplayFormatting.shortDuration(duration))
            }
            return parts.joined(separator: " · ")
        }
    }

    private var accessibilityText: String {
        "\(detail) \(title)"
    }

    private var iconName: String {
        switch entry.outcome {
        case .recovered: "checkmark.circle.fill"
        case .queued: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch entry.outcome {
        case .recovered: WatchTheme.accent
        case .queued: WatchTheme.muted
        case .failed: WatchTheme.warning
        }
    }
}

// MARK: - Countdown

private struct CountdownView: View {
    let value: Int
    let cancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var numberSize = 68

    private var fractionRemaining: CGFloat {
        CGFloat(max(0, min(value, 3))) / 3
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: fractionRemaining)
                        .stroke(WatchTheme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: value)

                    Text("\(value)")
                        .font(.system(size: numberSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(WatchTheme.highlight)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .snappy, value: value)
                }
                .frame(width: 104, height: 104)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Starting in \(value)")
                .accessibilityIdentifier("watch.countdown")

                Text("Get ready")
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.muted)

                Button("Cancel", action: cancel)
                    .buttonStyle(WatchCapsuleStyle())
                    .accessibilityIdentifier("watch.countdown.cancel")
            }
        }
    }
}

// MARK: - Active

private struct ActiveFootballView: View {
    @ObservedObject var recorder: WorkoutRecorder
    @ObservedObject var motionCapture: MotionCaptureController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @ScaledMetric(relativeTo: .largeTitle) private var elapsedSize = 34

    @State private var showsDiagnostics = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let heartRate = recorder.heartRate(at: context.date)
            let zone = WatchEffortZone.current(heartRate: heartRate)
            let stale = recorder.currentHeartRate != nil && heartRate == nil
            // Default text sizes fit one screen with Hold to finish pinned; only
            // accessibility sizes fall back to scrolling the whole stack.
            ViewThatFits(in: .vertical) {
                recordingStack(at: context.date, heartRate: heartRate, zone: zone, stale: stale)
                ScrollView {
                    recordingStack(at: context.date, heartRate: heartRate, zone: zone, stale: stale)
                }
                .scrollIndicators(.hidden)
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background {
                ZStack {
                    Color.black
                    if let zone, !isLuminanceReduced {
                        WatchTheme.zoneColor(zone).opacity(0.25)
                    }
                }
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .animation(
                    reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.6),
                    value: zone
                )
            }
            .opacity(isLuminanceReduced ? 0.65 : 1)
        }
        .navigationDestination(isPresented: $showsDiagnostics) {
            RecordingDiagnosticsView(snapshot: motionCapture.snapshot)
        }
    }

    private func recordingStack(
        at date: Date,
        heartRate: Double?,
        zone: WatchEffortZone?,
        stale: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                recordingRow
                motionStatusIndicator
                Spacer(minLength: 0)
                optionsButton
            }

            Text(SessionFormatting.recordingElapsed(recorder.elapsed(at: date)))
                .font(.system(size: elapsedSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Elapsed \(SessionFormatting.spokenElapsed(recorder.elapsed(at: date)))")
                .accessibilityIdentifier("watch.elapsed")

            HStack(spacing: 6) {
                MetricTile(
                    title: stale ? "Heart rate, stale" : "Heart rate",
                    value: heartRate.map { "\(Int($0.rounded()))" } ?? "—",
                    unit: "bpm",
                    tint: WatchTheme.heart
                )
                .accessibilityIdentifier("watch.metric.heart")

                MetricTile(
                    title: "Distance",
                    value: SessionFormatting.distance(recorder.distanceMeters),
                    unit: "km",
                    tint: WatchTheme.movement
                )
                .accessibilityIdentifier("watch.metric.distance")
            }

            EffortZoneStrip(zone: zone)

            Spacer(minLength: 0)

            HoldToFinishButton(finish: recorder.finish)
        }
    }

    private var optionsButton: some View {
        Button {
            showsDiagnostics = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.footnote.bold())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(WatchTheme.pitch, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More options")
        .accessibilityIdentifier("watch.options")
    }

    private var recordingRow: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(WatchTheme.highlight)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text("Recording")
                .font(.caption2.bold())
                .foregroundStyle(WatchTheme.highlight)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording")
        .accessibilityIdentifier("watch.recording")
    }

    private var motionStatusIndicator: some View {
        let snapshot = motionCapture.snapshot
        let status = WatchMotionPresentation(snapshot: snapshot)
        return Image(systemName: status.symbol)
            .font(.caption2)
            .foregroundStyle(status.tint)
            .accessibilityLabel("\(status.label). \(snapshot.sourceLabel). \(snapshot.sourceDetail)")
            .accessibilityHint("Full motion status is in Options, Motion Diagnostics")
            .accessibilityIdentifier("watch.motion-status")
    }
}

private struct EffortZoneStrip: View {
    let zone: WatchEffortZone?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        HStack(spacing: 6) {
            Text(zone?.label ?? "Zone —")
                .font(.caption2)
                .foregroundStyle(zone.map(WatchTheme.zoneColor) ?? WatchTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)
            HStack(spacing: 3) {
                ForEach(WatchEffortZone.allCases, id: \.rawValue) { segment in
                    Capsule()
                        .fill(WatchTheme.zoneColor(segment).opacity(zone == segment ? 1 : 0.2))
                        .frame(height: zone == segment ? 6 : 4)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(zone?.label ?? "Effort zone, waiting for heart rate")
        .accessibilityIdentifier("watch.zone")
        .animation(reduceMotion || isLuminanceReduced ? nil : .easeInOut(duration: 0.6), value: zone)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    let tint: Color
    @ScaledMetric(relativeTo: .title2) private var numberSize = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: numberSize, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(WatchTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(WatchTheme.pitch, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) \(unit.uppercased())")
    }
}

/// Full motion capture diagnostics, reachable only from the toolbar menu.
private struct RecordingDiagnosticsView: View {
    let snapshot: MotionCaptureSnapshot

    var body: some View {
        ScrollView {
            MotionDiagnosticsCard(snapshot: snapshot)
                .padding(.horizontal, 4)
        }
        .navigationTitle("Motion Diagnostics")
        .accessibilityIdentifier("watch.diagnostics")
    }
}

private struct MotionDiagnosticsCard: View {
    let snapshot: MotionCaptureSnapshot
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let status = WatchMotionPresentation(snapshot: snapshot)
            Label(status.label, systemImage: status.symbol)
                .font(.caption.bold())
                .foregroundStyle(status.tint)

            Label(snapshot.sourceLabel, systemImage: "waveform.path.ecg")
                .font(.caption.bold())
                .foregroundStyle(WatchTheme.highlight)

            Text(snapshot.sourceDetail)
                .font(.caption2)
                .foregroundStyle(WatchTheme.muted)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 6))
            layout {
                stream(
                    name: "ACC",
                    metrics: snapshot.accelerometer,
                    frequency: snapshot.reportedAccelerometerHz
                )
                stream(
                    name: "MOTION",
                    metrics: snapshot.deviceMotion,
                    frequency: snapshot.reportedDeviceMotionHz
                )
            }

            if let error = snapshot.accelerometer.lastError
                ?? snapshot.deviceMotion.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(WatchTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(WatchTheme.pitch, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func stream(
        name: String,
        metrics: MotionStreamMetrics,
        frequency: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.caption2.bold())
                .foregroundStyle(WatchTheme.muted)
            Text("\(metrics.sampleCount) samples")
                .font(.system(.caption, design: .rounded).bold())
                .monospacedDigit()
            Text(
                "\(frequency.map { String(format: "%.0f Hz", $0) } ?? "— Hz") · "
                    + "\(String(format: "%.3f s max", metrics.maxGap))"
            )
            .font(.system(.caption2, design: .rounded).bold())
            .foregroundStyle(WatchTheme.muted)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Hold to finish

/// Press-and-hold finish control. `recorder.finish` fires only when the hold
/// completes: either a 50 ms poll of `HoldToFinishModel` passes the duration
/// while the finger is still down, or the gesture itself ends at exactly the
/// hold duration. Accessibility users finish with a named action.
private struct HoldToFinishButton: View {
    let finish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model = HoldToFinishModel()
    @State private var displayProgress: Double = 0
    @State private var isPressing = false
    @State private var holdTask: Task<Void, Never>?

    private var holdAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2)
    }

    var body: some View {
        Text("Hold to finish")
            .font(.body.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 8)
            .background {
                ZStack {
                    Capsule()
                        .strokeBorder(WatchTheme.heart, lineWidth: 2)
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(WatchTheme.heart.opacity(0.35))
                            .frame(width: max(0, proxy.size.width * displayProgress))
                    }
                    .clipShape(Capsule())
                }
                .accessibilityHidden(true)
            }
            .foregroundStyle(WatchTheme.heart)
            .scaleEffect(!reduceMotion && isPressing ? 0.97 : 1)
            .animation(holdAnimation, value: isPressing)
            .animation(holdAnimation, value: displayProgress)
            .contentShape(Rectangle())
            .onLongPressGesture(
                minimumDuration: holdToFinishDuration,
                maximumDistance: 32,
                perform: {},
                onPressingChanged: pressingChanged
            )
            .onDisappear {
                holdTask?.cancel()
                holdTask = nil
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Press and hold to save the football session")
            .accessibilityAction(named: Text("Finish session"), finish)
            .accessibilityIdentifier("watch.finish")
    }

    private func pressingChanged(_ pressing: Bool) {
        if pressing {
            isPressing = true
            model.pressBegan(at: .now)
            displayProgress = model.progress(at: .now)
            holdTask?.cancel()
            holdTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard !Task.isCancelled else { return }
                    if model.evaluate(at: .now) {
                        displayProgress = 1
                        holdTask = nil
                        finish()
                        return
                    }
                    displayProgress = model.progress(at: .now)
                }
            }
        } else {
            isPressing = false
            holdTask?.cancel()
            holdTask = nil
            model.pressEnded(at: .now)
            // The gesture ends its own press at exactly the hold duration, so
            // the release itself can be the completing moment; otherwise the
            // hold was released early and resets.
            if model.evaluate(at: .now) {
                displayProgress = 1
                finish()
            } else {
                displayProgress = 0
            }
        }
    }
}

// MARK: - Saved

private struct SavedSessionView: View {
    let summary: FootballSessionSummary
    @ObservedObject var syncCoordinator: WatchSyncCoordinator
    let recordAnother: () -> Void
    @ScaledMetric(relativeTo: .title3) private var numberSize = 22
    @ScaledMetric(relativeTo: .title3) private var titleSize = 20

    var body: some View {
        // Reading the generation makes a receipt update this view while the
        // summary remains on screen; it never equates framework delivery with
        // an iPhone import.
        let syncPresentation: WatchSyncPresentation = {
            _ = syncCoordinator.stateGeneration
            return syncCoordinator.presentation(for: summary.transferKey)
        }()
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(WatchTheme.onAccent, WatchTheme.highlight)
                    .accessibilityHidden(true)

                Text("Full time")
                    .font(.system(size: min(titleSize, 28), weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                HStack(alignment: .top, spacing: 4) {
                    summaryMetric(
                        "time",
                        value: SessionFormatting.recordingElapsed(summary.duration),
                        tint: .white,
                        spoken: "Time, \(SessionFormatting.elapsed(summary.duration))"
                    )
                    .accessibilityIdentifier("watch.saved.duration")
                    summaryMetric(
                        "km",
                        value: SessionFormatting.distance(summary.distanceMeters),
                        tint: WatchTheme.movement,
                        spoken: "Distance, \(SessionFormatting.distance(summary.distanceMeters)) KM"
                    )
                    summaryMetric(
                        "avg bpm",
                        value: summary.averageHeartRate.map { "\(Int($0.rounded()))" } ?? "—",
                        tint: WatchTheme.heart,
                        spoken: "Average heart rate, "
                            + (summary.averageHeartRate.map { "\(Int($0.rounded())) BPM" } ?? "No reading")
                    )
                }

                Label(
                    syncPresentation.title,
                    systemImage: syncSymbol(for: syncPresentation)
                )
                .font(.caption.bold())
                .foregroundStyle(syncColor(for: syncPresentation))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 32)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(WatchTheme.pitch, in: Capsule())
                .accessibilityIdentifier("watch.saved.transfer")

                healthStatus(summary.healthKitSaveOutcome)

                if let captureQualityError = summary.captureQualityError {
                    Label("Capture needs attention", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(WatchTheme.warning)
                    Text(captureQualityError)
                        .font(.caption2)
                        .foregroundStyle(WatchTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NavigationLink {
                    SavedSessionDetailsView(
                        summary: summary,
                        syncCoordinator: syncCoordinator
                    )
                } label: {
                    Label("Details", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(WatchCapsuleStyle())
                .accessibilityIdentifier("watch.saved.details.open")

                Button("Done", action: recordAnother)
                    .buttonStyle(WatchCapsuleStyle(primary: true))
                    .accessibilityIdentifier("watch.saved.done")
            }
            .padding(.horizontal, 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved on Watch")
        .accessibilityIdentifier("watch.saved")
    }

    private func summaryMetric(_ title: String, value: String, tint: Color, spoken: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: min(numberSize, 32), weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            Text(title)
                .font(.caption2)
                .foregroundStyle(WatchTheme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    @ViewBuilder
    private func healthStatus(_ outcome: HealthKitSaveOutcomeV1) -> some View {
        switch outcome {
        case .saved:
            Label("Health workout saved", systemImage: "heart.fill")
                .font(.caption)
                .foregroundStyle(WatchTheme.accent)
        case .failed(let message):
            Label("Health needs attention: \(message)", systemImage: "heart.slash")
                .font(.caption2)
                .foregroundStyle(WatchTheme.warning)
                .multilineTextAlignment(.center)
        case .unavailable, .authorizationIssue:
            Label("Health workout was not saved", systemImage: "heart.slash")
                .font(.caption2)
                .foregroundStyle(WatchTheme.warning)
        }
    }

    private func syncSymbol(for presentation: WatchSyncPresentation) -> String {
        switch presentation {
        case .waitingForIPhone:
            return "iphone"
        case .importedOnIPhone:
            return "checkmark.icloud.fill"
        case .needsAttention:
            return "exclamationmark.triangle.fill"
        case .notRequestedByPhone:
            return "applewatch"
        }
    }

    private func syncColor(for presentation: WatchSyncPresentation) -> Color {
        switch presentation {
        case .waitingForIPhone:
            return WatchTheme.muted
        case .importedOnIPhone:
            return WatchTheme.accent
        case .needsAttention:
            return WatchTheme.warning
        case .notRequestedByPhone:
            return WatchTheme.muted
        }
    }
}

/// Concise post-session detail: metrics, sync state, capture quality.
private struct SavedSessionDetailsView: View {
    let summary: FootballSessionSummary
    @ObservedObject var syncCoordinator: WatchSyncCoordinator

    var body: some View {
        let syncPresentation: WatchSyncPresentation = {
            _ = syncCoordinator.stateGeneration
            return syncCoordinator.presentation(for: summary.transferKey)
        }()
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Time", SessionFormatting.elapsed(summary.duration))
                detailRow("Distance", "\(SessionFormatting.distance(summary.distanceMeters)) km", tint: WatchTheme.movement)
                detailRow(
                    "Average HR",
                    summary.averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "No reading",
                    tint: WatchTheme.heart
                )
                detailRow("Sync", syncPresentation.title)

                if let captureQualityError = summary.captureQualityError {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Capture quality", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(WatchTheme.warning)
                        Text(captureQualityError)
                            .font(.caption2)
                            .foregroundStyle(WatchTheme.muted)
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle("Details")
        .accessibilityIdentifier("watch.saved.details")
    }

    private func detailRow(_ title: String, _ value: String, tint: Color = .white) -> some View {
        WatchDetailRow(title: title, value: value, tint: tint)
    }
}

// MARK: - Failure

private struct FailureView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(WatchTheme.warning)
                    .accessibilityHidden(true)

                Text("Recording problem")
                    .font(.headline)
                    .accessibilityIdentifier("watch.failure")

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(WatchTheme.muted)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(WatchTheme.pitch, in: RoundedRectangle(cornerRadius: 12))

                Button("Try Again", action: retry)
                    .buttonStyle(WatchCapsuleStyle(primary: true))
            }
            .padding(.horizontal, 8)
        }
    }
}

enum SessionFormatting {
    static func recordingElapsed(_ interval: TimeInterval) -> String {
        let clock = elapsed(interval)
        return interval < 3_600 ? String(clock.dropFirst(3)) : clock
    }

    static func elapsed(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    static func spokenElapsed(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded(.down)))
        return "\(totalSeconds / 60) minutes \(totalSeconds % 60) seconds"
    }

    static func distance(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return String(format: "%.2f", max(0, meters) / 1_000)
    }
}
