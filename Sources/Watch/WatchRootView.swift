import SwiftUI

/// Football green accent, lightened for the black OLED canvas.
private let accentGreen = Color(red: 0.22, green: 0.72, blue: 0.42)

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
    }
}

// MARK: - Start

private struct StartFootballView: View {
    @ObservedObject var recorder: WorkoutRecorder

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "figure.soccer")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(accentGreen)
                    .accessibilityHidden(true)

                Text("Football Performance")
                    .font(.title3)
                    .bold()
                    .multilineTextAlignment(.center)

                Text("Your watch records on its own. No phone needed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: recorder.startCountdown) {
                    Label("Start Football", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentGreen)
                .controlSize(.large)
                .accessibilityHint("Starts after a three second countdown")

                NavigationLink {
                    RecoveryStatusView(recorder: recorder)
                } label: {
                    HStack {
                        Label("Session Recovery", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if recorder.recoveryAggregate?.attentionRequired == true {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                                .accessibilityLabel("Recovery or transfer work remains")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityHint("Shows interrupted sessions and iPhone transfer status")
            }
            .padding(.horizontal, 8)
        }
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
                        statusRow(
                            "Recovered",
                            value: "\(aggregate.recoveredCount)/\(aggregate.sourceSessionCount)",
                            emphasized: false
                        )
                        statusRow(
                            "Waiting for iPhone",
                            value: "\(aggregate.waitingForIPhoneCount)",
                            emphasized: false
                        )
                        statusRow(
                            "Imported",
                            value: "\(aggregate.importedCount)",
                            emphasized: false
                        )
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
                        } else {
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
                            .foregroundStyle(.secondary)
                    } else if aggregate.allSessionsTransferred {
                        Label("All sessions transferred", systemImage: "checkmark.icloud.fill")
                            .font(.caption.bold())
                            .foregroundStyle(accentGreen)
                            .multilineTextAlignment(.center)
                            .accessibilityHint("Every recovered session has an iPhone receipt")
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
                }

                if let message = recorder.recoveryMessage {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
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
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(recorder.isRecovering)
                .accessibilityHint("Recovers interrupted sessions and queues them for iPhone transfer")

                Button {
                    dismiss()
                } label: {
                    Label("Home", systemImage: "house.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentGreen)
                .controlSize(.large)
                .accessibilityHint("Returns to the Football home screen")
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle("Session Recovery")
        .task {
            await recorder.refreshRecoveryAggregate()
        }
    }

    private func statusRow(_ title: String, value: String, emphasized: Bool) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(emphasized ? Color.orange : Color.primary)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    private func recoveryProgress(progress: Double, total: Double, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: progress, total: total)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
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
        case .recovered: accentGreen
        case .queued: .secondary
        case .failed: .orange
        }
    }
}

// MARK: - Countdown

private struct CountdownView: View {
    let value: Int
    let cancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fractionRemaining: CGFloat {
        CGFloat(max(0, min(value, 3))) / 3
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fractionRemaining)
                    .stroke(accentGreen, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: value)

                Text("\(value)")
                    .font(.system(size: 68, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .snappy, value: value)
            }
            .frame(width: 104, height: 104)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Starting in \(value)")

            Text("Get ready")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Cancel", action: cancel)
                .buttonStyle(.bordered)
        }
    }
}

// MARK: - Active

private struct ActiveFootballView: View {
    @ObservedObject var recorder: WorkoutRecorder
    @ObservedObject var motionCapture: MotionCaptureController

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showsDiagnostics = false

    /// Keeps the whole recording screen on one page on a 41 mm watch; larger
    /// accessibility type sizes trade font size for fit.
    private var elapsedFontSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 36 : 44
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 6) {
                recordingRow

                Text(SessionFormatting.elapsed(recorder.elapsed(at: context.date)))
                    .font(.system(size: elapsedFontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityLabel(
                        "Elapsed \(SessionFormatting.spokenElapsed(recorder.elapsed(at: context.date)))"
                    )

                HStack(spacing: 6) {
                    MetricTile(
                        title: "HEART",
                        value: recorder.currentHeartRate.map {
                            "\(Int($0.rounded()))"
                        } ?? "—",
                        unit: "BPM"
                    )

                    MetricTile(
                        title: "DISTANCE",
                        value: SessionFormatting.distance(recorder.distanceMeters),
                        unit: "KM"
                    )
                }

                motionQualityRow

                HoldToFinishButton(finish: recorder.finish)
            }
            .padding(.horizontal, 4)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsDiagnostics = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More options")
            }
        }
        .navigationDestination(isPresented: $showsDiagnostics) {
            RecordingDiagnosticsView(snapshot: motionCapture.snapshot)
        }
    }

    private var recordingRow: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(accentGreen)
                .frame(width: 7, height: 7)
            Text("RECORDING")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording")
    }

    /// One compact line. Full Hz/gap details live in the diagnostics screen.
    private var motionQualityRow: some View {
        let snapshot = motionCapture.snapshot
        let hasStreamError = snapshot.accelerometer.lastError != nil
            || snapshot.deviceMotion.lastError != nil
        let maximumGap = max(snapshot.accelerometer.maxGap, snapshot.deviceMotion.maxGap)
        let degraded = hasStreamError || maximumGap >= 5
        return HStack(spacing: 4) {
            Circle()
                .fill(degraded ? Color.orange : accentGreen)
                .frame(width: 6, height: 6)
            Text(degraded ? "Motion degraded" : "Motion OK")
                .font(.caption2)
                .foregroundStyle(degraded ? Color.orange : Color.primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
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
    }
}

private struct MotionDiagnosticsCard: View {
    let snapshot: MotionCaptureSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(snapshot.sourceLabel, systemImage: "waveform.path.ecg")
                .font(.caption.bold())

            Text(snapshot.sourceDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
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
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func stream(
        name: String,
        metrics: MotionStreamMetrics,
        frequency: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text("\(metrics.sampleCount) samples")
                .font(.caption2)
                .monospacedDigit()
            Text(
                "\(frequency.map { String(format: "%.0f Hz", $0) } ?? "— Hz") · "
                    + "\(String(format: "%.3f s max", metrics.maxGap))"
            )
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
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
        Label("Hold to Finish", systemImage: "stop.fill")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.red.opacity(0.72))
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.red)
                            .frame(width: max(0, proxy.size.width * displayProgress))
                    }
                }
            }
            .foregroundStyle(.white)
            .scaleEffect(isPressing ? 0.97 : 1)
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
                    .font(.title)
                    .foregroundStyle(accentGreen)

                Text("Saved on Watch")
                    .font(.headline)

                Label(
                    syncPresentation.title,
                    systemImage: syncSymbol(for: syncPresentation)
                )
                .font(.caption.bold())
                .foregroundStyle(syncColor(for: syncPresentation))
                .multilineTextAlignment(.center)

                healthStatus(summary.healthKitSaveOutcome)

                if let captureQualityError = summary.captureQualityError {
                    Label("Capture needs attention", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    Text(captureQualityError)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }

                VStack(spacing: 3) {
                    summaryRow("Time", SessionFormatting.elapsed(summary.duration))
                    summaryRow("Distance", "\(SessionFormatting.distance(summary.distanceMeters)) km")
                    summaryRow(
                        "Average HR",
                        summary.averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "No reading"
                    )
                }
                .padding(6)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                NavigationLink {
                    SavedSessionDetailsView(
                        summary: summary,
                        syncCoordinator: syncCoordinator
                    )
                } label: {
                    Label("Details", systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button("Done", action: recordAnother)
                    .buttonStyle(.borderedProminent)
                    .tint(accentGreen)
                    .controlSize(.large)
            }
            .padding(.horizontal, 6)
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func healthStatus(_ outcome: HealthKitSaveOutcomeV1) -> some View {
        switch outcome {
        case .saved:
            Label("Health workout saved", systemImage: "heart.fill")
                .font(.caption)
                .foregroundStyle(accentGreen)
        case .failed(let message):
            Label("Health needs attention: \(message)", systemImage: "heart.slash")
                .font(.caption2)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        case .unavailable, .authorizationIssue:
            Label("Health workout was not saved", systemImage: "heart.slash")
                .font(.caption2)
                .foregroundStyle(.orange)
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
        }
    }

    private func syncColor(for presentation: WatchSyncPresentation) -> Color {
        switch presentation {
        case .waitingForIPhone:
            return .secondary
        case .importedOnIPhone:
            return accentGreen
        case .needsAttention:
            return .orange
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
                detailRow("Distance", "\(SessionFormatting.distance(summary.distanceMeters)) km")
                detailRow(
                    "Average HR",
                    summary.averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "No reading"
                )
                detailRow("Sync", syncPresentation.title)

                if let captureQualityError = summary.captureQualityError {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Capture quality", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                        Text(captureQualityError)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle("Details")
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
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
                    .foregroundStyle(.orange)

                Text("Recording problem")
                    .font(.headline)

                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
            .padding(.horizontal, 8)
        }
    }
}

private enum SessionFormatting {
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

    static func distance(_ meters: Double) -> String {
        String(format: "%.2f", max(0, meters) / 1_000)
    }
}
