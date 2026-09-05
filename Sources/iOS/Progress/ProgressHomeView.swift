import Charts
import SwiftUI

/// One measure at a time, against the player's own history. The measure and
/// time-range selectors are real filters over recorded sessions; the
/// baseline follows the documented three-valid-session rule and never
/// includes the current session in its own pool.
struct ProgressHomeView: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    @State private var measure: TrendMeasure = .distancePerMinute
    @State private var range: ProgressRange = .fourWeeks

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerformanceTheme.sectionSpacing) {
                header
                selectors

                if trendSessions.isEmpty {
                    emptyCard
                } else {
                    TrendCard(
                        measure: measure,
                        sessions: trendSessions,
                        baseline: baselineStatus
                    )
                    baselineCard
                    if let statement = rangeStatement {
                        observationCard(statement)
                    }
                    recentCard
                }
            }
            .padding(.horizontal, PerformanceTheme.screenInset)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .animation(PerformanceTheme.replaceAnimation, value: measure)
            .animation(PerformanceTheme.replaceAnimation, value: range)
        }
        .background(Color(.systemGroupedBackground))
        .scrollBounceBehavior(.basedOnSize)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PERSONAL BASELINE")
                .font(.caption.weight(.bold))
                .foregroundStyle(PerformanceTheme.accent)
                .tracking(0.8)
                .accessibilityHidden(true)

            Text("Progress")
                .font(PerformanceTheme.screenTitle)
                .foregroundStyle(PerformanceTheme.primaryText)

            Text("One measure at a time, against your own history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var selectors: some View {
        VStack(spacing: 10) {
            Picker("Measure", selection: $measure) {
                ForEach(TrendMeasure.allCases) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
            .pickerStyle(.segmented)

            Picker("Range", selection: $range) {
                ForEach(ProgressRange.allCases) { candidate in
                    Text(candidate.title).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
        }
        .accessibilityElement(children: .contain)
    }

    /// Sessions of the selected range that actually carry the selected
    /// measure. Sessions without the evidence drop out rather than showing 0.
    private var trendSessions: [FileSessionRepository.SessionRecord] {
        let cutoff = range.cutoffDate
        return model.sessions.filter { record in
            guard cutoff == nil || record.startedAt >= cutoff! else { return false }
            return measure.value(of: record) != nil
        }
    }

    private var latestSession: FileSessionRepository.SessionRecord? {
        trendSessions.first
    }

    private var baselineStatus: BaselineEngineV1.BaselineStatus {
        guard let latestSession else { return .unavailable }
        // The latest session never joins its own comparison pool.
        let pool = model.sessions.filter { $0.sessionID != latestSession.sessionID }
        return BaselineEngineV1.baseline(
            for: measure.baselineMeasure,
            priorSessions: pool,
            currentStartedAt: latestSession.startedAt
        )
    }

    private var rangeStatement: String? {
        let values = trendSessions.prefix(10).compactMap { measure.value(of: $0) }
        return SessionObservationEngineV1.rangeStatement(
            values: values,
            measureName: measure.title,
            unitName: measure.unitSuffix
        )
    }

    @ViewBuilder
    private var baselineCard: some View {
        switch baselineStatus {
        case .established(let value, let count):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Your recent baseline")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PerformanceTheme.primaryText)
                    Spacer()
                    Text(measure.formatted(value))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PerformanceTheme.accent)
                }
                Text("Built from your \(count) most recent valid sessions before the latest one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .performanceCard(padding: 14)

        case .building(let validCount, let required):
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(BaselineEngineV1.buildingSentence(validCount: validCount, required: required))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PerformanceTheme.primaryText)
                } icon: {
                    Image(systemName: "figure.run")
                        .foregroundStyle(PerformanceTheme.accent)
                }
                Text("Comparisons stay neutral until \(required) valid sessions exist.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .performanceCard(padding: 14)

        case .unavailable:
            VStack(alignment: .leading, spacing: 6) {
                Text("Building your baseline")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PerformanceTheme.primaryText)
                Text("A baseline appears after three valid sessions. Completed recordings of at least ten minutes count.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .performanceCard(padding: 14)
        }
    }

    private func observationCard(_ sentence: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PerformanceTheme.accent)
                .padding(.top, 1)
            Text(sentence)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .performanceCard(padding: 14)
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent sessions")
                .font(.title3.weight(.semibold))
                .foregroundStyle(PerformanceTheme.primaryText)
            VStack(spacing: 0) {
                ForEach(trendSessions.prefix(4)) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(SessionRowFormatting.dayLabel(record.startedAt))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(PerformanceTheme.primaryText)
                            Text(
                                "\(SessionRowFormatting.timeLabel(record.startedAt)) · "
                                    + SessionRowFormatting.state(record).label
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(measure.formatted(measure.value(of: record) ?? 0))
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 9)
                    if record.sessionID != trendSessions.prefix(4).last?.sessionID {
                        Divider()
                    }
                }
            }
        }
        .performanceCard()
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No sessions in this range yet")
                .font(.headline)
                .foregroundStyle(PerformanceTheme.primaryText)
            Text("Record Football Sessions on your watch; trends appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
        .performanceCard()
    }
}

/// The measures Progress can chart today. Both come straight from recorded
/// summary values. Movement needs per-session motion aggregation that would
/// force full package decodes per row, so it is deliberately not offered.
enum TrendMeasure: String, CaseIterable, Identifiable {
    case distancePerMinute
    case averageHeartRate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .distancePerMinute: return "Distance"
        case .averageHeartRate: return "Heart rate"
        }
    }

    var unitSuffix: String {
        switch self {
        case .distancePerMinute: return "m/min"
        case .averageHeartRate: return "bpm"
        }
    }

    var headline: String {
        switch self {
        case .distancePerMinute: return "Distance per minute"
        case .averageHeartRate: return "Average heart rate"
        }
    }

    var baselineMeasure: BaselineEngineV1.Measure {
        switch self {
        case .distancePerMinute: return .distancePerMinute
        case .averageHeartRate: return .averageHeartRate
        }
    }

    func value(of record: FileSessionRepository.SessionRecord) -> Double? {
        switch self {
        case .distancePerMinute:
            return BaselineEngineV1.distancePerMinute(record)
        case .averageHeartRate:
            return record.completion.summary?.averageHeartRate?.value
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .distancePerMinute: return String(format: "%.0f m/min", value)
        case .averageHeartRate: return "\(Int(value.rounded())) bpm"
        }
    }
}

enum ProgressRange: String, CaseIterable, Identifiable {
    case fourWeeks
    case twelveWeeks
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fourWeeks: return "4 weeks"
        case .twelveWeeks: return "12 weeks"
        case .allTime: return "All time"
        }
    }

    var cutoffDate: Date? {
        guard self != .allTime else { return nil }
        let weeks: Double = self == .fourWeeks ? 4 : 12
        return Date().addingTimeInterval(-weeks * 7 * 24 * 3_600)
    }
}

/// The one dominant trend card: current value, comparison with the personal
/// baseline when one exists, and the per-session series.
struct TrendCard: View {
    let measure: TrendMeasure
    let sessions: [FileSessionRepository.SessionRecord]
    let baseline: BaselineEngineV1.BaselineStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(measure.headline)
                    .font(.headline)
                    .foregroundStyle(PerformanceTheme.primaryText)
                Spacer()
                if let latest = sessions.first, let value = measure.value(of: latest) {
                    Text(measure.formatted(value))
                        .font(.title3.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(PerformanceTheme.primaryText)
                }
            }

            if let latest = sessions.first, let value = measure.value(of: latest) {
                comparisonChip(value)
            }

            chart

            Text("Each point is one recorded session.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .performanceCard()
    }

    @ViewBuilder
    private func comparisonChip(_ value: Double) -> some View {
        if case .established(let baselineValue, _) = baseline, baselineValue > 0 {
            let percentDelta = (value - baselineValue) / baselineValue * 100
            HStack(spacing: 5) {
                Image(systemName: percentDelta >= 0 ? "arrow.up" : "arrow.down")
                    .font(.caption2.weight(.bold))
                Text(String(format: "%.0f%% %@", abs(percentDelta), percentDelta >= 0 ? "above your baseline" : "below your baseline"))
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(PerformanceTheme.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(PerformanceTheme.accent.opacity(0.12), in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }

    private var chart: some View {
        let points = sessions.prefix(12).reversed().compactMap { record -> (record: FileSessionRepository.SessionRecord, value: Double)? in
            guard let value = measure.value(of: record) else { return nil }
            return (record, value)
        }
        return Chart {
            ForEach(points, id: \.record.sessionID) { entry in
                LineMark(
                    x: .value("Session", entry.record.startedAt, unit: .day),
                    y: .value(measure.headline, entry.value)
                )
                .foregroundStyle(PerformanceTheme.accent)
                .interpolationMethod(.catmullRom)
                PointMark(
                    x: .value("Session", entry.record.startedAt, unit: .day),
                    y: .value(measure.headline, entry.value)
                )
                .foregroundStyle(PerformanceTheme.accent)
                .symbolSize(28)
            }

            if case .established(let baselineValue, _) = baseline {
                RuleMark(y: .value("Baseline", baselineValue))
                    .foregroundStyle(PerformanceTheme.accent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .bottom, spacing: 2) {
                        Text("Baseline")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) {
                AxisGridLine().foregroundStyle(.clear)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) {
                AxisValueLabel().font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(height: 160)
        .accessibilityLabel("\(measure.headline) trend across recent sessions")
        .accessibilityValue("\(points.count) sessions")
    }
}
