import Charts
import SwiftUI

/// The focused session report. One hero chart answers "how did it unfold";
/// everything else is progressive disclosure through Explore rows.
struct SessionOverviewScreen: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    let sessionID: UUID
    @State private var showsDeleteConfirmation = false
    @State private var selectedSeconds: Double?

    var body: some View {
        Group {
            if let detail = model.selectedDetail, detail.record.sessionID == sessionID {
                overview(detail)
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
        .background(Color(.systemGroupedBackground))
        .navigationTitle(SessionRowFormatting.dayLabel(startedAt))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await model.prepareExactExport() }
                    } label: {
                        Label("Prepare exact export", systemImage: "checkmark.seal")
                    }
                    if let exportURL = model.exportURL {
                        ShareLink(item: exportURL) {
                            Label("Share verified package", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        showsDeleteConfirmation = true
                    } label: {
                        Label("Delete iPhone copy", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Session actions")
            }
        }
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
        .task(id: sessionID) {
            await model.loadDetail(for: sessionID)
        }
    }

    private var startedAt: Date {
        model.selectedDetail?.record.startedAt ?? Date()
    }

    @ViewBuilder
    private func overview(_ detail: FileSessionRepository.SessionDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerformanceTheme.sectionSpacing) {
                summaryRow(detail.record)
                UnfoldedHeroCard(
                    detail: detail,
                    observation: model.visualSummaries[sessionID]?.observation,
                    selectedSeconds: $selectedSeconds
                )
                exploreSection(detail)
            }
            .padding(.horizontal, PerformanceTheme.screenInset)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
    }

    /// Three compact metrics. Only recorded values appear; missing evidence
    /// shows an explicit dash.
    private func summaryRow(_ record: FileSessionRepository.SessionRecord) -> some View {
        HStack(spacing: 0) {
            StatBlock(
                value: SessionRowFormatting.distanceLabel(meters: SessionRowFormatting.summaryDistance(record)),
                caption: "Distance"
            )
            StatBlock(
                value: SessionRowFormatting.durationLabel(SessionRowFormatting.summaryDuration(record)),
                caption: "Duration"
            )
            StatBlock(
                value: SessionRowFormatting.heartRateLabel(
                    SessionRowFormatting.summaryAverageHeartRate(record)
                ),
                caption: "Avg heart rate"
            )
        }
        .padding(.vertical, 14)
        .padding(.horizontal, PerformanceTheme.cardInset)
        .performanceCard()
    }

    private func exploreSection(_ detail: FileSessionRepository.SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Explore this session")
                .font(.title3.weight(.semibold))
                .foregroundStyle(PerformanceTheme.primaryText)

            VStack(spacing: 10) {
                NavigationLink {
                    HeartRateReportView(detail: detail)
                } label: {
                    ExploreRow(
                        icon: "heart.fill",
                        tint: PerformanceTheme.heartRate,
                        title: "Heart rate",
                        subtitle: "Trace, distribution, and coverage",
                        trailing: model.visualSummaries[sessionID]?.heartRateRange.map {
                            "\(Int($0.lowerBound.rounded()))–\(Int($0.upperBound.rounded())) bpm"
                        }
                    )
                }
                .buttonStyle(PressableStyle())

                NavigationLink {
                    MovementReportView(detail: detail)
                } label: {
                    ExploreRow(
                        icon: "waveform.path.ecg",
                        tint: PerformanceTheme.movement,
                        title: "Movement",
                        subtitle: "Wrist-motion evidence on its own timeline",
                        trailing: nil
                    )
                }
                .buttonStyle(PressableStyle())

                NavigationLink {
                    RecordingQualityReportView(detail: detail)
                } label: {
                    ExploreRow(
                        icon: "checkmark.seal",
                        tint: recordQualityTint(detail),
                        title: "Recording quality",
                        subtitle: "Source, coverage, and gaps",
                        trailing: recordQualityLabel(detail)
                    )
                }
                .buttonStyle(PressableStyle())

                NavigationLink {
                    SessionDetailsView(detail: detail)
                } label: {
                    ExploreRow(
                        icon: "list.bullet",
                        tint: .secondary,
                        title: "Details",
                        subtitle: "Energy, provenance, export, and deletion",
                        trailing: nil
                    )
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    private func recordQualityLabel(_ detail: FileSessionRepository.SessionDetail) -> String? {
        switch SessionRowFormatting.state(detail.record) {
        case .completed:
            return detail.diagnostics.isEmpty ? nil : "Recorded"
        case .interrupted, .incompletePackage:
            return SessionRowFormatting.state(detail.record).label
        }
    }

    private func recordQualityTint(_ detail: FileSessionRepository.SessionDetail) -> Color {
        switch SessionRowFormatting.state(detail.record) {
        case .completed: return PerformanceTheme.accent
        case .interrupted, .incompletePackage: return PerformanceTheme.warning
        }
    }
}

/// A large drill-in row with icon, title, and an optional factual value.
struct ExploreRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(PerformanceTheme.primaryText)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .performanceCard(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The one dominant chart card: heart rate as a red area over session time,
/// with a distance-per-minute track beneath on the same synchronized clock
/// (both series are HealthKit-dated, so the timeline alignment is real).
/// Movement is deliberately absent here; its clock is relative to its own
/// first sample and lives in the Movement report.
struct UnfoldedHeroCard: View {
    let detail: FileSessionRepository.SessionDetail
    let observation: SessionObservationV1?
    @Binding var selectedSeconds: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var startedAt: Date { detail.record.startedAt }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("How it unfolded")
                    .font(.headline)
                    .foregroundStyle(PerformanceTheme.primaryText)
                Spacer()
                if let duration = SessionRowFormatting.summaryDuration(detail.record) {
                    Text(SessionRowFormatting.durationLabel(duration))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            heartRateLane

            distanceLane

            if let observation {
                Button {
                    selectObservationRange(observation)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PerformanceTheme.accent)
                            .padding(.top, 1)
                        Text(observation.sentence)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "scope")
                            .font(.caption2)
                            .foregroundStyle(PerformanceTheme.accent)
                            .padding(.top, 2)
                    }
                }
                .buttonStyle(PressableStyle())
                .accessibilityHint("Shows this stretch in the chart")
            }

            legend
        }
        .performanceCard()
        .accessibilityElement(children: .contain)
    }

    // MARK: - Data

    private var heartRateSegments: [ChartPreparationV1.Segment] {
        ChartPreparationV1.segments(
            from: detail.heartRateSnapshots.map { ($0.timestamp, $0.value) },
            maximumGapSeconds: 120
        )
    }

    private var sessionMinutes: Double {
        let end = detail.record.completion.endedAt.timeIntervalSince(startedAt) / 60
        let lastHeartRate = detail.heartRateSnapshots.last?.timestamp.timeIntervalSince(startedAt) ?? 0
        return max(1, end, lastHeartRate / 60)
    }

    /// Per-minute distance deltas from the cumulative recorded distance.
    /// Empty minutes are gaps, never zeros.
    private var distanceMinuteBars: [DistanceMinuteBar] {
        let points = detail.distanceSnapshots
            .filter { $0.timestamp >= startedAt }
            .sorted { $0.timestamp < $1.timestamp }
        guard points.count >= 2 else { return [] }
        var bars: [DistanceMinuteBar] = []
        var currentMinute = Int(points[0].timestamp.timeIntervalSince(startedAt) / 60)
        var currentMeters = 0.0
        for index in points.indices.dropFirst() {
            let delta = points[index].value - points[index - 1].value
            let minute = Int(points[index].timestamp.timeIntervalSince(startedAt) / 60)
            if delta > 0 {
                if minute == currentMinute {
                    currentMeters += delta
                } else {
                    bars.append(DistanceMinuteBar(minute: currentMinute, meters: currentMeters))
                    currentMinute = minute
                    currentMeters = delta
                }
            }
        }
        if currentMeters > 0 {
            bars.append(DistanceMinuteBar(minute: currentMinute, meters: currentMeters))
        }
        return bars
    }

    private func selectObservationRange(_ observation: SessionObservationV1) {
        let midpoint = Double(observation.minuteRange.lowerBound + observation.minuteRange.upperBound) / 2 * 60
        if reduceMotion {
            selectedSeconds = midpoint
        } else {
            withAnimation(PerformanceTheme.replaceAnimation) {
                selectedSeconds = midpoint
            }
        }
    }

    // MARK: - Chart lanes

    private var heartRateLane: some View {
        let segments = heartRateSegments
        return Chart {
            ForEach(segments) { segment in
                ForEach(segment.points) { point in
                    heartRateArea(point)
                    heartRateLine(point)
                }
            }

            if let selectedSeconds {
                selectionRule(seconds: selectedSeconds)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: 15)) { axisValue in
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel {
                    if let minute = axisValue.as(Int.self) {
                        Text("\(minute)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) {
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .chartOverlay { proxy in
            chartSelectionOverlay(proxy: proxy)
        }
        .frame(height: 170)
        .accessibilityLabel("Heart rate across the session")
        .accessibilityValue(selectedAccessibilityText)
    }

    private func heartRateArea(_ point: ChartPreparationV1.ChartSample) -> some ChartContent {
        AreaMark(
            x: .value("Minute", point.seconds / 60),
            y: .value("Heart rate", point.value)
        )
        .foregroundStyle(
            .linearGradient(
                colors: [PerformanceTheme.heartRate.opacity(0.25), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .interpolationMethod(.catmullRom)
    }

    private func heartRateLine(_ point: ChartPreparationV1.ChartSample) -> some ChartContent {
        LineMark(
            x: .value("Minute", point.seconds / 60),
            y: .value("Heart rate", point.value)
        )
        .foregroundStyle(PerformanceTheme.heartRate)
        .interpolationMethod(.catmullRom)
        .lineStyle(StrokeStyle(lineWidth: 1.6))
    }

    private func selectionRule(seconds: Double) -> some ChartContent {
        RuleMark(x: .value("Selected", seconds / 60))
            .foregroundStyle(PerformanceTheme.primaryText.opacity(0.35))
            .annotation(position: .top, spacing: 0) {
                selectedValueLabel
            }
    }

    private func chartSelectionOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let plot = proxy.plotFrame else { return }
                            let x = value.location.x - geometry[plot].origin.x
                            guard let rawMinute: Double = proxy.value(atX: x) else { return }
                            selectedSeconds = max(0, rawMinute * 60)
                        }
                )
        }
    }

    @ViewBuilder
    private var selectedValueLabel: some View {
        if let selectedSeconds,
           let value = nearestHeartRate(at: selectedSeconds) {
            Text("\(Int(value.rounded())) bpm")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PerformanceTheme.heartRate.opacity(0.14), in: Capsule())
                .foregroundStyle(PerformanceTheme.heartRate)
        }
    }

    private func nearestHeartRate(at seconds: Double) -> Double? {
        let all = heartRateSegments.flatMap(\.points)
        guard !all.isEmpty else { return nil }
        return all.min(by: { abs($0.seconds - seconds) < abs($1.seconds - seconds) })?.value
    }

    private var selectedAccessibilityText: String {
        guard let selectedSeconds, let value = nearestHeartRate(at: selectedSeconds) else {
            return "No time selected"
        }
        let minute = Int(selectedSeconds / 60)
        return "\(Int(value.rounded())) beats per minute at minute \(minute)"
    }

    /// Slim relative-height distance track under the heart-rate lane.
    private var distanceLane: some View {
        let bars = distanceMinuteBars
        let peak = bars.map(\.meters).max() ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            if bars.isEmpty {
                Text("No distance evidence was recorded.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Chart {
                    ForEach(bars) { bar in
                        BarMark(
                            x: .value("Minute", bar.minute),
                            y: .value("Relative distance", max(0.02, bar.meters / max(peak, 1))),
                            width: .fixed(2.5)
                        )
                        .foregroundStyle(PerformanceTheme.accent.opacity(0.4))
                        .cornerRadius(1)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: 0...sessionMinutes)
                .frame(height: 34)
                .accessibilityLabel("Distance per minute across the session")
            }
            Text(bars.isEmpty ? "Distance" : "Distance per minute (relative height)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(PerformanceTheme.heartRate, "Heart rate")
            legendDot(PerformanceTheme.accent.opacity(0.55), "Distance per minute")
            Spacer()
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct DistanceMinuteBar: Identifiable, Equatable {
    let minute: Int
    let meters: Double

    var id: Int { minute }
}
