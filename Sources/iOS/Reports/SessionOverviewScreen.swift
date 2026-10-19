import Charts
import SwiftUI

/// The focused session report. One hero chart answers "how did it unfold";
/// everything else is progressive disclosure through Explore rows.
struct SessionOverviewScreen: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    let sessionID: UUID
    @State private var showsDeleteConfirmation = false
    @State private var selectedSeconds: Double?
    @State private var insights: PerformanceCoachV1.SessionInsights?
    @AppStorage("playerAge") private var playerAge = 0

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
                SessionHeroHeader(record: detail.record)
                if detail.record.isManualEntry {
                    Label("Only the date, duration, and type were entered. No sensor readings were recorded.", systemImage: "square.and.pencil")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .performanceCard()
                }
                if !detail.record.isManualEntry {
                    UnfoldedHeroCard(
                        detail: detail,
                        observation: model.visualSummaries[sessionID]?.observation,
                        selectedSeconds: $selectedSeconds
                    )
                    if let insights {
                        SessionInsightsSection(insights: insights, ageIsSet: playerAge > 0)
                    }
                }
                exploreSection(detail)
            }
            .padding(.horizontal, PerformanceTheme.screenInset)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .task(id: "\(detail.record.sessionID)-\(playerAge)") {
            insights = detail.record.isManualEntry
                ? nil
                : PerformanceCoachV1.insights(for: detail, age: playerAge > 0 ? playerAge : nil)
        }
    }

    private func exploreSection(_ detail: FileSessionRepository.SessionDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Explore this session")

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
        if detail.record.isManualEntry { return "Manual log" }
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

/// The session at a glance on the green hero surface.
struct SessionHeroHeader: View {
    let record: FileSessionRepository.SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: record.sessionEnvelope.footballType.symbolName)
                    .font(.title2.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SessionRowFormatting.typeAndSource(record))
                        .font(.headline)
                    Text(
                        record.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide))
                            + " · " + SessionRowFormatting.timeLabel(record.startedAt)
                    )
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
            }

            AdaptiveMetricGroup {
                HeroStat(
                    value: SessionRowFormatting.durationLabel(SessionRowFormatting.summaryDuration(record)),
                    caption: "Duration",
                    emphasised: true
                )
                HeroStat(
                    value: SessionRowFormatting.distanceLabel(meters: SessionRowFormatting.summaryDistance(record)),
                    caption: "Distance"
                )
                HeroStat(
                    value: SessionRowFormatting.heartRateLabel(SessionRowFormatting.summaryAverageHeartRate(record)),
                    caption: "Avg heart rate"
                )
            }
        }
        .heroSurface()
    }
}

/// Intensity zones, effort metrics, and what to work on after this session.
struct SessionInsightsSection: View {
    let insights: PerformanceCoachV1.SessionInsights
    let ageIsSet: Bool

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: PerformanceTheme.sectionSpacing) {
            if insights.zoneSeconds > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(
                        title: "Intensity",
                        caption: "Time in each heart-rate zone. Max \(Int(insights.heartRateMax.rounded())) bpm "
                            + (ageIsSet ? "from your age." : "estimated; set your age in Settings for accuracy.")
                    )
                    ZoneBreakdownView(zones: insights.zones, heartRateMax: insights.heartRateMax)
                        .performanceCard()
                }
            }

            if !tiles.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Effort")
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(tiles, id: \.caption) { tile in
                            MetricTile(icon: tile.icon, tint: tile.tint, value: tile.value, caption: tile.caption)
                        }
                    }
                }
            }

            if !insights.takeaways.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "How to get better", caption: "What this session says to work on.")
                    ForEach(insights.takeaways) { CoachTipCard(tip: $0) }
                }
            }
        }
    }

    private struct Tile {
        let icon: String
        let tint: Color
        let value: String
        let caption: String
    }

    private var tiles: [Tile] {
        var result: [Tile] = []
        if let share = insights.highIntensityShare {
            result.append(Tile(
                icon: "flame.fill",
                tint: PerformanceTheme.heartRate,
                value: "\(Int((share * 100).rounded()))%",
                caption: "Time above 80% max HR"
            ))
        }
        if let efforts = insights.highIntensityEffortCount {
            result.append(Tile(
                icon: "bolt.heart.fill",
                tint: PerformanceTheme.warning,
                value: "\(efforts)",
                caption: "Hard efforts"
            ))
        }
        if let recovery = insights.medianRecoveryBetweenEffortsS {
            result.append(Tile(
                icon: "arrow.clockwise.heart",
                tint: PerformanceTheme.movement,
                value: "\(Int(recovery.rounded())) s",
                caption: "Typical recovery between efforts"
            ))
        }
        if let first = insights.firstHalfDistancePerMinute, let second = insights.secondHalfDistancePerMinute {
            result.append(Tile(
                icon: "figure.run",
                tint: PerformanceTheme.accent,
                value: "\(Int(first.rounded())) → \(Int(second.rounded()))",
                caption: "m/min, 1st → 2nd half"
            ))
        }
        if insights.sprintCount > 0 {
            result.append(Tile(
                icon: "hare.fill",
                tint: PerformanceTheme.improve,
                value: "\(insights.sprintCount)",
                caption: "Sprints detected"
            ))
        }
        if let peak = insights.peakHeartRate {
            result.append(Tile(
                icon: "heart.fill",
                tint: PerformanceTheme.heartRate,
                value: "\(Int(peak.rounded()))",
                caption: "Peak bpm"
            ))
        }
        return result
    }
}

/// A large drill-in row with icon, title, and an optional factual value.
struct ExploreRow: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let trailing: String?
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        let rowLayout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        rowLayout {
            if textSize.isAccessibilitySize {
                HStack {
                    rowIcon
                    Spacer()
                    disclosure
                }
            } else {
                rowIcon
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(PerformanceTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if textSize.isAccessibilitySize, let trailing {
                    Text(trailing)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if !textSize.isAccessibilitySize {
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                disclosure
            }
        }
        .performanceCard(padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var rowIcon: some View {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
    }

    private var disclosure: some View {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
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
    @Environment(\.dynamicTypeSize) private var textSize

    private var startedAt: Date { detail.record.startedAt }

    var body: some View {
        let headingLayout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        VStack(alignment: .leading, spacing: 12) {
            headingLayout {
                Text("How it unfolded")
                    .font(.headline)
                    .foregroundStyle(PerformanceTheme.primaryText)
                if !textSize.isAccessibilitySize { Spacer() }
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

            if !heartRateSegments.isEmpty || !distanceMinuteBars.isEmpty { legend }
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

    @ViewBuilder
    private var heartRateLane: some View {
        let segments = heartRateSegments
        if segments.isEmpty {
            Label("No heart-rate readings", systemImage: "heart.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
        Chart {
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
        .chartXSelection(value: Binding(
            get: { selectedSeconds.map { $0 / 60 } },
            set: { selectedSeconds = $0.map { max(0, $0 * 60) } }
        ))
        .frame(height: 170)
        .accessibilityLabel("Heart rate across the session")
        .accessibilityValue(selectedAccessibilityText)
        }
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
                Text("No per-minute distance readings.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
