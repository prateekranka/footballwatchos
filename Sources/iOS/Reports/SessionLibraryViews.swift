import Charts
import SwiftUI

struct SessionLibraryView: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No sessions received yet", systemImage: "tray")
                } description: {
                    Text("Completed Apple Watch sessions appear here after they are transferred to this iPhone.")
                }
                .accessibilityElement(children: .combine)
            } else {
                List(model.sessions) { session in
                    NavigationLink(value: session.sessionID) {
                        SessionLibraryRow(session: session)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationDestination(for: UUID.self) { sessionID in
            SessionDetailScreen(sessionID: sessionID)
        }
    }
}

private struct SessionLibraryRow: View {
    let session: FileSessionRepository.SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.startedAt, format: .dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
                .font(.headline)
            Text(session.sessionID.uuidString.lowercased())
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session from \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

private struct SessionDetailScreen: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    let sessionID: UUID
    @State private var selectedMetric: RecordedMetric = .heartRate
    @State private var showsDeleteConfirmation = false

    var body: some View {
        Group {
            if let detail = model.selectedDetail, detail.record.sessionID == sessionID {
                SessionDetailReport(
                    detail: detail,
                    selectedMetric: $selectedMetric,
                    exportURL: model.exportURL,
                    prepareExport: { await model.prepareExactExport() },
                    delete: { await model.deleteIPhoneCopy() },
                    showsDeleteConfirmation: $showsDeleteConfirmation
                )
            } else if model.isLoading {
                ProgressView("Loading session")
            } else {
                ContentUnavailableView {
                    Label("Session unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("This session is not available as a readable iPhone copy.")
                }
            }
        }
        .navigationTitle("Session report")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sessionID) {
            await model.loadDetail(for: sessionID)
        }
    }
}

private struct SessionDetailReport: View {
    let detail: FileSessionRepository.SessionDetail
    @Binding var selectedMetric: RecordedMetric
    let exportURL: URL?
    let prepareExport: () async -> Void
    let delete: () async -> Void
    @Binding var showsDeleteConfirmation: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                chartSection
                overviewSection
                summarySection
                healthSaveSection
                captureSection
                exportSection
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .confirmationDialog(
            "Delete iPhone copy?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete iPhone copy", role: .destructive) {
                Task { await delete() }
            }
        } message: {
            Text("This removes only the stored package on this iPhone. It does not alter Health data or contact your Apple Watch.")
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recorded snapshots")
                .font(.title2.bold())
            Picker("Recorded metric", selection: $selectedMetric) {
                ForEach(RecordedMetric.allCases) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .pickerStyle(.segmented)

            switch selectedMetric {
            case .heartRate:
                SnapshotChart(
                    points: detail.heartRateSnapshots,
                    x: \.timestamp,
                    y: \.value,
                    metricName: "Heart rate",
                    unit: "beats per minute",
                    tint: .red
                )
            case .distance:
                SnapshotChart(
                    points: detail.distanceSnapshots,
                    x: \.timestamp,
                    y: \.value,
                    metricName: "Cumulative distance",
                    unit: "meters",
                    tint: .blue
                )
            case .accelerationMagnitude:
                SnapshotChart(
                    points: MotionChartBuilder.accelerationMagnitudePoints(
                        from: detail.accelerometerSamples,
                        idPrefix: "acceleration"
                    ),
                    x: \.timestamp,
                    y: \.value,
                    metricName: "Acceleration magnitude",
                    unit: "g",
                    tint: .orange,
                    xAxisLabel: "Seconds from first sample",
                    emptyTitle: "No motion data was captured.",
                    emptyDescription: "This session recorded no accelerometer samples."
                )
            case .rotationRate:
                SnapshotChart(
                    points: MotionChartBuilder.rotationRatePoints(
                        from: detail.deviceMotionSamples,
                        idPrefix: "rotation"
                    ),
                    x: \.timestamp,
                    y: \.value,
                    metricName: "Rotation rate",
                    unit: "rad/s",
                    tint: .purple,
                    xAxisLabel: "Seconds from first sample",
                    emptyTitle: "No motion data was captured.",
                    emptyDescription: "This session recorded no rotation-rate samples."
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var overviewSection: some View {
        GroupBox("Session") {
            LabeledContent("Started") {
                Text(detail.record.startedAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
            }
            LabeledContent("Duration") {
                Text(durationText)
            }
            LabeledContent("Lifecycle") {
                Text(lifecycleText(detail.record.completion.lifecycle))
            }
        }
    }

    private var summarySection: some View {
        GroupBox("Recorded summary") {
            SummaryMetricRow(title: "Distance", metric: detail.record.completion.summary?.distance)
            SummaryMetricRow(title: "Average heart rate", metric: detail.record.completion.summary?.averageHeartRate)
            SummaryMetricRow(title: "Active energy", metric: detail.record.completion.summary?.activeEnergy)
        }
    }

    private var healthSaveSection: some View {
        GroupBox("HealthKit save outcome") {
            Text(healthSaveText(detail.record.completion.healthKitSaveOutcome))
                .foregroundStyle(.secondary)
        }
    }

    private var captureSection: some View {
        GroupBox("Capture record") {
            LabeledContent("Source") {
                Text(captureSourceText(detail.record.sessionEnvelope.captureSource))
            }
            if let latest = detail.diagnostics.last {
                LabeledContent("Accelerometer samples") {
                    Text("\(latest.accelerometerSampleCount)")
                }
                LabeledContent("Device motion samples") {
                    Text("\(latest.deviceMotionSampleCount)")
                }
                LabeledContent("Largest recorded gap") {
                    Text(latest.maximumObservedGap.map { String(format: "%.1f seconds", $0) } ?? "Not recorded")
                }
                LabeledContent("Accelerometer") {
                    Text(availabilityText(latest.accelerometerAvailability))
                }
                LabeledContent("Device motion") {
                    Text(availabilityText(latest.deviceMotionAvailability))
                }
            } else {
                Text("No capture diagnostics were recorded for this session.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Package")
                .font(.title3.bold())
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share verified package", systemImage: "square.and.arrow.up")
                }
                .accessibilityHint("Shares the exact stored footysession package")
            } else {
                Button {
                    Task { await prepareExport() }
                } label: {
                    Label("Prepare verified export", systemImage: "checkmark.seal")
                }
                .accessibilityHint("Verifies the package digest before sharing")
            }
            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label("Delete iPhone copy", systemImage: "trash")
            }
        }
    }

    private var durationText: String {
        if let duration = detail.record.completion.summary?.duration {
            return metricText(duration)
        }
        let span = detail.record.completion.endedAt.timeIntervalSince(detail.record.startedAt)
        guard span >= 0 else { return "Not recorded" }
        return "\(Int(span.rounded())) seconds (from recorded start and end)"
    }
}

/// Renders any point series whose x and y values conform to `Plottable`.
/// Snapshot series use `FileSessionRepository.ChartPoint` (Date x-axis);
/// motion series use `MotionChartPoint` (TimeInterval seconds, x-axis labeled
/// "Seconds from first sample").
private struct SnapshotChart<Point: Identifiable, X: Plottable, Y: Plottable>: View {
    let points: [Point]
    let x: KeyPath<Point, X>
    let y: KeyPath<Point, Y>
    let metricName: String
    let unit: String
    let tint: Color
    var xAxisLabel: String = "Recorded time"
    var emptyTitle: String?
    var emptyDescription: String?

    var body: some View {
        if points.isEmpty {
            ContentUnavailableView(
                emptyTitle ?? "No \(metricName.lowercased()) snapshots",
                systemImage: "chart.line.downtrend.xyaxis",
                description: Text(emptyDescription ?? "This session did not record usable \(metricName.lowercased()) snapshots.")
            )
            .frame(height: 220)
        } else {
            Chart(points) { point in
                LineMark(
                    x: .value(xAxisLabel, point[keyPath: x]),
                    y: .value(metricName, point[keyPath: y])
                )
                .foregroundStyle(tint)
                PointMark(
                    x: .value(xAxisLabel, point[keyPath: x]),
                    y: .value(metricName, point[keyPath: y])
                )
                .foregroundStyle(tint)
            }
            .chartXAxisLabel(xAxisLabel)
            .chartYAxisLabel(unit)
            .frame(height: 240)
            .accessibilityLabel("\(metricName) chart in \(unit)")
        }
    }
}

private struct SummaryMetricRow: View {
    let title: String
    let metric: SessionMetricV1?

    var body: some View {
        LabeledContent(title) {
            Text(metric.map(metricText) ?? "Not recorded")
        }
    }
}

private func metricText(_ metric: SessionMetricV1) -> String {
    let value: String
    switch metric.unit {
    case .seconds:
        value = "\(Int(metric.value.rounded())) seconds"
    case .meters:
        value = String(format: "%.1f meters", metric.value)
    case .beatsPerMinute:
        value = String(format: "%.0f bpm", metric.value)
    case .kilocalories:
        value = String(format: "%.0f kcal", metric.value)
    case .count:
        value = String(format: "%.0f", metric.value)
    }
    return "\(value) · \(provenanceText(metric.provenance))"
}

private func provenanceText(_ provenance: MetricProvenanceV1) -> String {
    switch provenance {
    case .healthKitLive: "HealthKit live"
    case .healthKitFinalWorkout: "HealthKit final workout"
    case .coreMotionBatched: "Batched Core Motion"
    case .coreMotionFallback: "Foreground Core Motion"
    case .capturedDeviceEstimate: "Captured device estimate"
    }
}

private func lifecycleText(_ lifecycle: SessionLifecycleV1) -> String {
    switch lifecycle {
    case .completed: "Completed"
    case let .interrupted(reason): "Interrupted: \(interruptionText(reason))"
    }
}

private func interruptionText(_ reason: SessionInterruptionReasonV1) -> String {
    switch reason {
    case .appTerminated: "app terminated"
    case .workoutEndedUnexpectedly: "workout ended unexpectedly"
    case .storageFailure: "storage failure"
    case .partialFileRecovery: "partial file recovery"
    case .userAbandoned: "user abandoned"
    case .unknown: "unknown reason"
    }
}

private func healthSaveText(_ outcome: HealthKitSaveOutcomeV1) -> String {
    switch outcome {
    case .saved: "Saved by Apple Watch"
    case let .failed(message): "Apple Watch save failed: \(message)"
    case let .unavailable(reason): "Unavailable: \(healthUnavailableText(reason))"
    case let .authorizationIssue(reason): "Authorization issue: \(authorizationText(reason))"
    }
}

private func healthUnavailableText(_ reason: HealthKitUnavailabilityReasonV1) -> String {
    switch reason {
    case .healthDataUnavailable: "health data unavailable"
    case .notAttempted: "not attempted"
    case .serviceUnavailable: "service unavailable"
    }
}

private func authorizationText(_ reason: HealthKitAuthorizationIssueV1) -> String {
    switch reason {
    case .notDetermined: "not determined"
    case .denied: "denied"
    case .restricted: "restricted"
    case .requestFailed: "request failed"
    }
}

/// Human-readable label for every `MotionCaptureSourceV1` case. The switch is
/// exhaustive over the shared enum, so adding a case forces a label here.
func captureSourceText(_ source: MotionCaptureSourceV1) -> String {
    switch source {
    case .batchedCoreMotion: "Batched Core Motion"
    case .foregroundFallback: "Foreground Core Motion fallback"
    case let .unavailable(reason): "Unavailable: \(streamUnavailableText(reason))"
    }
}

private func availabilityText(_ availability: StreamAvailabilityV1) -> String {
    switch availability {
    case .available: "Available"
    case let .unavailable(reason): "Unavailable: \(streamUnavailableText(reason))"
    case let .insufficient(reason): "Insufficient: \(streamInsufficiencyText(reason))"
    }
}

private func streamUnavailableText(_ reason: StreamUnavailabilityReasonV1) -> String {
    switch reason {
    case .hardwareUnsupported: "hardware unsupported"
    case .permissionDenied: "permission denied"
    case .authorizationUnavailable: "authorization unavailable"
    case .serviceUnavailable: "service unavailable"
    case .disabledByUser: "disabled by user"
    case .captureNotStarted: "capture not started"
    case .sourceError: "source error"
    }
}

private func streamInsufficiencyText(_ reason: StreamInsufficiencyReasonV1) -> String {
    switch reason {
    case .noSamples: "no samples"
    case .insufficientSamples: "insufficient samples"
    case .insufficientCoverage: "insufficient coverage"
    case .excessiveGaps: "excessive gaps"
    case .captureEndedEarly: "capture ended early"
    }
}
