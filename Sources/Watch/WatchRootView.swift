import SwiftUI

struct WatchRootView: View {
    @ObservedObject var recorder: WorkoutRecorder
    @ObservedObject var motionCapture: MotionCaptureController

    var body: some View {
        Group {
            switch recorder.phase {
            case .authorizing:
                ProgressView("Preparing Health")

            case .idle:
                StartFootballView(
                    recoveryNotice: recorder.recoveryNotice,
                    start: recorder.startCountdown
                )

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

private struct StartFootballView: View {
    let recoveryNotice: String?
    let start: () -> Void

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

                if let recoveryNotice {
                    Text(recoveryNotice)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                Button(action: start) {
                    Label("Start Football", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .accessibilityHint("Starts after a three second countdown")
            }
            .padding(.horizontal, 8)
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
