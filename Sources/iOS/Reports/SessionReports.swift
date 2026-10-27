import Charts
import SwiftUI

// MARK: - Heart rate report

/// Full heart-rate report: synchronized trace, distribution, and evidence
/// coverage. Zones live on the session overview, where the max heart rate is.
struct HeartRateReportView: View {
    let detail: FileSessionRepository.SessionDetail

    @State private var selectedSeconds: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerformanceTheme.sectionSpacing) {
                if heartRateSegments.isEmpty {
                    unavailableCard(title: "No heart-rate readings")
                } else {
                    traceCard
                    distributionCard
                    coverageCard
                }
            }
            .padding(.horizontal, PerformanceTheme.screenInset)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Heart rate")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sortedSamples: [(timestamp: Date, value: Double)] {
        detail.heartRateSnapshots
            .map { ($0.timestamp, $0.value) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    private var heartRateSegments: [ChartPreparationV1.Segment] {
        ChartPreparationV1.segments(from: sortedSamples)
    }

    private var traceCard: some View {
        let segments = heartRateSegments
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Trace")
                    .font(.headline)
                    .foregroundStyle(PerformanceTheme.primaryText)
                Spacer()
                if let selectedSeconds,
                   let nearest = nearestValue(at: selectedSeconds) {
                    Text("\(Int(nearest.rounded())) bpm")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PerformanceTheme.heartRate)
                }
            }

            Chart {
                ForEach(segments) { segment in
                    ForEach(segment.points) { point in
                        heartRateLine(point)
                    }
                }
                if let selectedSeconds {
                    RuleMark(x: .value("Selected", selectedSeconds / 60))
                        .foregroundStyle(PerformanceTheme.primaryText.opacity(0.35))
                }
            }
            .chartXAxis { minuteAxis() }
            .chartYAxis {
                AxisMarks(position: .trailing) {
                    AxisValueLabel()
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .chartXSelection(value: Binding(
                get: { selectedSeconds.map { $0 / 60 } },
                set: { selectedSeconds = $0.map { max(0, $0 * 60) } }
            ))
            .frame(height: 200)
            .accessibilityLabel("Heart-rate trace across the session, minutes from session start")
        }
        .performanceCard()
    }

    private func heartRateLine(_ point: ChartPreparationV1.ChartSample) -> some ChartContent {
        LineMark(
            x: .value("Minute", point.seconds / 60),
            y: .value("Heart rate", point.value)
        )
        .foregroundStyle(PerformanceTheme.heartRate)
        .interpolationMethod(.catmullRom)
        .lineStyle(StrokeStyle(lineWidth: 1.5))
    }

    private func nearestValue(at seconds: Double) -> Double? {
        let all = heartRateSegments.flatMap(\.points)
        return all.min(by: { abs($0.seconds - seconds) < abs($1.seconds - seconds) })?.value
    }

    private var distributionCard: some View {
        let buckets = distributionBuckets()
        return VStack(alignment: .leading, spacing: 10) {
            Text("Distribution")
                .font(.headline)
                .foregroundStyle(PerformanceTheme.primaryText)

            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Band", bucket.label),
                    y: .value("Seconds", bucket.seconds)
                )
                .foregroundStyle(PerformanceTheme.heartRate.opacity(0.7))
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks {
                    AxisValueLabel().font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing) { axisValue in
                    AxisValueLabel {
                        if let seconds = axisValue.as(Double.self) {
                            Text("\(Int(seconds / 60))m")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Heart-rate distribution across five-beat bands")
        }
        .performanceCard()
    }

    private struct Bucket: Identifiable {
        let label: String
        let seconds: Double
        var id: String { label }
    }

    private func distributionBuckets() -> [Bucket] {
        let samples = sortedSamples.map(\.value)
        guard !samples.isEmpty else { return [] }
        let low = (samples.min()! / 5).rounded(.down) * 5
        let high = (samples.max()! / 5).rounded(.up) * 5
        guard high > low else { return [] }
        var secondsPerBucket = [Double](repeating: 0, count: Int((high - low) / 5))
        for index in sortedSamples.indices.dropFirst() {
            let delta = sortedSamples[index].timestamp.timeIntervalSince(sortedSamples[index - 1].timestamp)
            guard delta > 0, delta < 120 else { continue }
            let offset = Int((sortedSamples[index].value - low) / 5)
            let bucket = min(secondsPerBucket.count - 1, max(0, offset))
            secondsPerBucket[bucket] += delta
        }
        return secondsPerBucket.enumerated().compactMap { index, seconds in
            guard seconds > 0 else { return nil }
            let lower = Int(low) + index * 5
            return Bucket(label: "\(lower)–\(lower + 5)", seconds: seconds)
        }
    }

    private var coverageCard: some View {
        let samples = sortedSamples
        let span = samples.count >= 2
            ? samples.last!.timestamp.timeIntervalSince(samples.first!.timestamp)
            : 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("Evidence coverage")
                .font(.headline)
                .foregroundStyle(PerformanceTheme.primaryText)
            coverageRow("Readings", "\(samples.count)")
            coverageRow("Covered span", span > 0 ? SessionRowFormatting.durationLabel(span) : "—")
            coverageRow(
                "Largest gap",
                span > 0
                    ? String(format: "%.0f s", largestGap(in: samples.map(\.timestamp)) ?? 0)
                    : "—"
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .performanceCard()
    }

    private func coverageRow(_ title: String, _ value: String) -> some View {
        AdaptiveDetailRow(title: title, value: value)
    }
}

/// Largest time gap in a sorted list of dates.
func largestGap(in dates: [Date]) -> TimeInterval? {
    guard dates.count >= 2 else { return nil }
    var largest: TimeInterval?
    for index in dates.indices.dropFirst() {
        let gap = dates[index].timeIntervalSince(dates[index - 1])
        if gap > (largest ?? 0) {
            largest = gap
        }
    }
    return largest
}

// MARK: - Movement report

/// Wrist-motion evidence on its own relative timeline. Core Motion stamps
/// are seconds since device boot, so this chart counts minutes from the
/// first recorded motion sample (its accessibility label says so) and is
/// never merged onto the HealthKit clock.
struct MovementReportView: View {
    let detail: FileSessionRepository.SessionDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerformanceTheme.sectionSpacing) {
                if accelerationPoints.isEmpty {
                    unavailableCard(title: "No motion data was captured")
                } else {
                    traceCard
                    openCloseCard
                }
            }
            .padding(.horizontal, PerformanceTheme.screenInset)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Movement")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var accelerationPoints: [MotionChartPoint] {
        MotionChartBuilder.accelerationMagnitudePoints(
            from: detail.accelerometerSamples,
            idPrefix: "overview-acceleration"
        )
    }

    private var traceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wrist motion (g)")
                .font(.headline)
                .foregroundStyle(PerformanceTheme.primaryText)

            Chart(accelerationPoints) { point in
                LineMark(
                    x: .value("Minute", point.timestamp / 60),
                    y: .value("Acceleration", point.value)
                )
                .foregroundStyle(PerformanceTheme.movement)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1))
            }
            .chartXAxis { minuteAxis() }
            .chartYAxis {
                AxisMarks(position: .trailing) { axisValue in
                    AxisValueLabel {
                        if let number = axisValue.as(Double.self) {
                            Text(String(format: "%.1f", number))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(height: 180)
            .accessibilityLabel("Wrist motion across the session, minutes from the first motion sample")
        }
        .performanceCard()
    }

    /// Factual opening-versus-closing comparison of mean wrist motion over
    /// the first and last 15 recorded minutes. Requires a long enough
    /// recording on both ends; otherwise the card says so.
    private var openCloseCard: some View {
        let points = accelerationPoints
        let comparison = Self.openingVersusClosing(points: points)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Opening versus closing")
                .font(.headline)
                .foregroundStyle(PerformanceTheme.primaryText)
            if let comparison {
                AdaptiveMetricGroup {
                    StatBlock(value: String(format: "%.2f g", comparison.opening), caption: "First 15 min")
                    StatBlock(value: String(format: "%.2f g", comparison.closing), caption: "Last 15 min")
                }
            } else {
                Text("Too short to compare.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .performanceCard()
    }

    static func openingVersusClosing(
        points: [MotionChartPoint],
        windowSeconds: Double = 900
    ) -> (opening: Double, closing: Double)? {
        guard let last = points.last?.timestamp, last >= windowSeconds * 2 else { return nil }
        let opening = points.filter { $0.timestamp < windowSeconds }.map(\.value)
        let closing = points.filter { $0.timestamp > last - windowSeconds }.map(\.value)
        guard !opening.isEmpty, !closing.isEmpty else { return nil }
        return (
            opening.reduce(0, +) / Double(opening.count),
            closing.reduce(0, +) / Double(closing.count)
        )
    }
}

// MARK: - Recording quality report

/// Source, coverage, gaps, lifecycle, and the HealthKit save outcome. This
/// is the honest-record screen: interrupted and degraded sessions describe
/// themselves here.
struct RecordingQualityReportView: View {
    let detail: FileSessionRepository.SessionDetail

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerformanceTheme.sectionSpacing) {
                lifecycleCard
                // A manual log has no capture or Health outcome to report.
                if !detail.record.isManualEntry {
                    captureCard
                    healthCard
                }
            }
            .padding(.horizontal, PerformanceTheme.screenInset)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Recording quality")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var lifecycleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if detail.record.isManualEntry {
                Text("Manual log")
                    .font(.headline)
                    .foregroundStyle(PerformanceTheme.primaryText)
                Text("No sensor readings were recorded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
            Text("Recording state")
                .font(.headline)
                .foregroundStyle(PerformanceTheme.primaryText)
            HStack {
                StateTag(state: SessionRowFormatting.state(detail.record))
                Spacer()
            }
            switch SessionRowFormatting.state(detail.record) {
            case .completed:
                EmptyView()
            case .interrupted(let reason):
                Text(SessionRowFormatting.interruptionDetail(reason))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .incompletePackage:
                Text("This package never received a completion record.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .performanceCard()
    }

    private var captureCard: some View {
        let latest = detail.diagnostics.last
        return VStack(alignment: .leading, spacing: 8) {
            Text("Capture evidence")
                .font(.headline)
                .foregroundStyle(PerformanceTheme.primaryText)
            if let latest {
                qualityRow("Motion source", captureSourceText(latest.source))
                qualityRow("Accelerometer samples", "\(latest.accelerometerSampleCount)")
                qualityRow("Device-motion samples", "\(latest.deviceMotionSampleCount)")
                if let hz = latest.accelerometerReportedHz {
                    qualityRow("Accelerometer rate", String(format: "%.0f Hz", hz))
                }
                qualityRow(
                    "Largest recorded gap",
                    latest.maximumObservedGap.map { String(format: "%.1f s", $0) } ?? "Not recorded"
                )
                qualityRow("Accelerometer", availabilityText(latest.accelerometerAvailability))
                qualityRow("Device motion", availabilityText(latest.deviceMotionAvailability))
            } else {
                Text("Not recorded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .performanceCard()
    }

    private var healthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Health save outcome")
                .font(.headline)
                .foregroundStyle(PerformanceTheme.primaryText)
            Label {
                Text(healthSaveText(detail.record.completion.healthKitSaveOutcome))
            } icon: {
                Image(systemName: healthSaveSymbol(detail.record.completion.healthKitSaveOutcome))
                    .foregroundStyle(healthSaveTint(detail.record.completion.healthKitSaveOutcome))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .performanceCard()
    }

    private func qualityRow(_ title: String, _ value: String) -> some View {
        AdaptiveDetailRow(title: title, value: value)
    }

    private func healthSaveSymbol(_ outcome: HealthKitSaveOutcomeV1) -> String {
        switch outcome {
        case .saved: return "heart.fill"
        case .failed, .unavailable, .authorizationIssue: return "heart.slash"
        }
    }

    private func healthSaveTint(_ outcome: HealthKitSaveOutcomeV1) -> Color {
        switch outcome {
        case .saved: return PerformanceTheme.accent
        case .failed, .unavailable, .authorizationIssue: return PerformanceTheme.warning
        }
    }
}

// MARK: - Details report

/// Energy, provenance, package facts, exact export, and local deletion.
/// Technical identifiers live here, one level deep, never on the overview.
struct SessionDetailsView: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    let detail: FileSessionRepository.SessionDetail
    @State private var showsDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerformanceTheme.sectionSpacing) {
                energyCard
                provenanceCard
                packageCard
                actionsCard
            }
            .padding(.horizontal, PerformanceTheme.screenInset)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete iPhone copy?",
            isPresented: $showsDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete iPhone copy", role: .destructive) {
                Task { await model.deleteIPhoneCopy() }
            }
        } message: {
            Text("This removes only the stored package on this iPhone. It does not alter Health data or contact your Apple Watch.")
        }
    }

    private var energyCard: some View {
        let energy = detail.record.completion.summary?.activeEnergy
        return VStack(alignment: .leading, spacing: 8) {
            Text("Active energy")
                .font(.headline)
                .foregroundStyle(PerformanceTheme.primaryText)
            if let energy {
                Text("\(Int(energy.value.rounded())) kcal")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            } else {
                Text("Not recorded")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .performanceCard()
    }

    private var provenanceCard: some View {
        let summary = detail.record.completion.summary
        return VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.headline)
                .foregroundStyle(PerformanceTheme.primaryText)
            if let distance = summary?.distance {
                provenanceRow("Distance", provenanceText(distance.provenance))
            }
            if let heartRate = summary?.averageHeartRate {
                provenanceRow("Average heart rate", provenanceText(heartRate.provenance))
            }
            if let duration = summary?.duration {
                provenanceRow("Duration", provenanceText(duration.provenance))
            }
            if let energy = summary?.activeEnergy {
                provenanceRow("Active energy", provenanceText(energy.provenance))
            }
            provenanceRow("Motion capture", captureSourceText(detail.record.sessionEnvelope.captureSource))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .performanceCard()
    }

    private var packageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Package")
                .font(.headline)
                .foregroundStyle(PerformanceTheme.primaryText)
            detailRow("Stored size", ByteCountFormatter.string(fromByteCount: Int64(detail.record.byteCount), countStyle: .file))
            detailRow(
                "Received",
                detail.record.transferEnvelope.createdAt.formatted(date: .abbreviated, time: .shortened)
            )
            detailRow(
                "Session identifier",
                String(detail.record.sessionID.uuidString.lowercased().prefix(8))
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .performanceCard()
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let exportURL = model.exportURL {
                ShareLink(item: exportURL) {
                    Label("Share verified package", systemImage: "square.and.arrow.up")
                }
            } else {
                Button {
                    Task { await model.prepareExactExport() }
                } label: {
                    Label("Prepare exact export", systemImage: "checkmark.seal")
                }
            }

            Divider()

            Button(role: .destructive) {
                showsDeleteConfirmation = true
            } label: {
                Label("Delete iPhone copy", systemImage: "trash")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .performanceCard()
    }

    private func provenanceRow(_ title: String, _ value: String) -> some View {
        AdaptiveDetailRow(title: title, value: value, valueFont: .footnote.weight(.medium))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        provenanceRow(title, value)
    }
}

// MARK: - Shared pieces

/// Session-minute x-axis. The unit rides on each label ("15m"), so the
/// chart needs no "minutes from start" caption.
@MainActor
func minuteAxis() -> some AxisContent {
    AxisMarks(values: .stride(by: 15)) { axisValue in
        AxisGridLine().foregroundStyle(.clear)
        AxisValueLabel {
            if let minute = axisValue.as(Double.self) {
                Text("\(Int(minute))m")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Standard unavailable-evidence card. Used instead of any fake chart.
@MainActor
@ViewBuilder
func unavailableCard(title: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: "chart.bar.scatter")
            .font(.title2)
            .foregroundStyle(.tertiary)
        Text(title)
            .font(.headline)
            .foregroundStyle(PerformanceTheme.primaryText)
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
    .padding(.horizontal, 16)
    .performanceCard()
}
