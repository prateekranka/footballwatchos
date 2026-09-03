import SwiftUI

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
            .task {
                recorder.prepare()
            }
        }
    }
}

private struct StartFootballView: View {
    @ObservedObject var recorder: WorkoutRecorder

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "figure.soccer")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)

                Text("Football")
                    .font(.title2)
                    .bold()

                Text("Watch records independently")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(action: recorder.startCountdown) {
                    Label("Start Football", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .accessibilityHint("Starts after a three second countdown")

                NavigationLink {
                    RecoveryStatusView(recorder: recorder)
                } label: {
                    HStack {
                        Label("Session Recovery", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if recorder.recoveryAggregate?.attentionRequired == true {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
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
                            .foregroundStyle(.green)
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
                .tint(.green)
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
        case .recovered: .green
        case .queued: .secondary
        case .failed: .orange
        }
    }
}

private struct CountdownView: View {
    let value: Int
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("\(value)")
                .font(.system(size: 68, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .accessibilityLabel("Starting in \(value)")

            Button("Cancel", action: cancel)
                .buttonStyle(.bordered)
        }
    }
}

private struct ActiveFootballView: View {
    @ObservedObject var recorder: WorkoutRecorder
    @ObservedObject var motionCapture: MotionCaptureController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(spacing: 10) {
                    Label("RECORDING", systemImage: "circle.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                        .accessibilityLabel("Recording")

                    Text(SessionFormatting.elapsed(recorder.elapsed(at: context.date)))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .accessibilityLabel(
                            "Elapsed \(SessionFormatting.spokenElapsed(recorder.elapsed(at: context.date)))"
                        )

                    HStack(spacing: 8) {
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

                    MotionDiagnosticsCard(snapshot: motionCapture.snapshot)

                    HoldToFinishButton(finish: recorder.finish)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
            }
        }
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
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(.gray.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
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
        .background(.blue.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
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

private struct HoldToFinishButton: View {
    let finish: () -> Void
    @State private var isPressing = false

    var body: some View {
        Label("Hold to Finish", systemImage: "stop.fill")
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                isPressing ? Color.red : Color.red.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .foregroundStyle(.white)
            .scaleEffect(isPressing ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: isPressing)
            .contentShape(Rectangle())
            .onLongPressGesture(
                minimumDuration: 1.25,
                maximumDistance: 32,
                perform: finish,
                onPressingChanged: { isPressing = $0 }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Press and hold to save the football session")
            .accessibilityAction(named: Text("Finish session"), finish)
    }
}

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
                    .foregroundStyle(.green)

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

                summaryRow("Time", SessionFormatting.elapsed(summary.duration))
                summaryRow("Distance", "\(SessionFormatting.distance(summary.distanceMeters)) km")
                summaryRow(
                    "Average HR",
                    summary.averageHeartRate.map { "\(Int($0.rounded())) bpm" } ?? "No reading"
                )
                MotionDiagnosticsCard(snapshot: summary.motion)

                Button("Done", action: recordAnother)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
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
    }

    @ViewBuilder
    private func healthStatus(_ outcome: HealthKitSaveOutcomeV1) -> some View {
        switch outcome {
        case .saved:
            Label("Health workout saved", systemImage: "heart.fill")
                .font(.caption)
                .foregroundStyle(.green)
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
            return .green
        case .needsAttention:
            return .orange
        }
    }
}

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
