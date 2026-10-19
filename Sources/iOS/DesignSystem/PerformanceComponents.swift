import Charts
import SwiftUI

/// Faint pitch markings (halfway line, centre circle, penalty box) drawn
/// over hero surfaces. Purely decorative.
struct PitchMarkings: View {
    var body: some View {
        Canvas { context, size in
            let line = GraphicsContext.Shading.color(.white.opacity(0.10))
            let width: CGFloat = 1.5
            let midX = size.width * 0.72
            var halfway = Path()
            halfway.move(to: CGPoint(x: midX, y: 0))
            halfway.addLine(to: CGPoint(x: midX, y: size.height))
            context.stroke(halfway, with: line, lineWidth: width)

            let radius = min(size.height * 0.42, 70)
            let circle = Path(ellipseIn: CGRect(
                x: midX - radius,
                y: size.height / 2 - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.stroke(circle, with: line, lineWidth: width)
            context.fill(
                Path(ellipseIn: CGRect(x: midX - 3, y: size.height / 2 - 3, width: 6, height: 6)),
                with: line
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The green hero surface: gradient, pitch markings, white content.
struct HeroSurface: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background {
                ZStack {
                    PerformanceTheme.heroGradient
                    PitchMarkings()
                }
                .clipShape(RoundedRectangle(cornerRadius: PerformanceTheme.cardCorner + 4, style: .continuous))
            }
            .shadow(color: PerformanceTheme.pitchDeep.opacity(0.25), radius: 14, y: 6)
    }
}

extension View {
    func heroSurface(padding: CGFloat = 18) -> some View {
        modifier(HeroSurface(padding: padding))
    }
}

/// Section title with an optional caption beneath it.
struct SectionHeader: View {
    let title: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(PerformanceTheme.primaryText)
                .accessibilityAddTraits(.isHeader)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A rounded-square tinted symbol.
struct IconBadge: View {
    let systemName: String
    let tint: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A compact metric: icon, big rounded value, caption.
struct MetricTile: View {
    let icon: String
    let tint: Color
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            IconBadge(systemName: icon, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(PerformanceTheme.metricNumber)
                    .monospacedDigit()
                    .foregroundStyle(PerformanceTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .performanceCard(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

/// A big number on a hero surface.
struct HeroStat: View {
    let value: String
    let caption: String
    var emphasised = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: emphasised ? 34 : 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(emphasised ? PerformanceTheme.highlight : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(caption)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension PerformanceCoachV1.Tone {
    var tint: Color {
        switch self {
        case .positive: return PerformanceTheme.positive
        case .improve: return PerformanceTheme.improve
        case .caution: return PerformanceTheme.warning
        }
    }

    var label: String {
        switch self {
        case .positive: return "Keep it up"
        case .improve: return "Work on"
        case .caution: return "Take care"
        }
    }
}

/// One coaching tip: what we saw, and what to do about it.
struct CoachTipCard: View {
    let tip: PerformanceCoachV1.Tip
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemName: tip.focus.symbolName, tint: tip.tone.tint, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(tip.tone.label.uppercased()) · \(tip.focus.title.uppercased())")
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(tip.tone.tint)
                    Text(tip.title)
                        .font(.headline)
                        .foregroundStyle(PerformanceTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(tip.evidence)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let drill = tip.drill, !compact {
                VStack(alignment: .leading, spacing: 4) {
                    Label(drill.name, systemImage: "figure.soccer")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PerformanceTheme.primaryText)
                    Text(drill.prescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    tip.tone.tint.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: PerformanceTheme.innerCorner, style: .continuous)
                )
            }

            if tip.isGeneral {
                Text("General football-fitness guidance")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .performanceCard()
        .accessibilityElement(children: .combine)
    }
}

/// Minutes per week as rounded bars, the current week highlighted.
struct WeeklyLoadChart: View {
    let weeks: [PerformanceCoachV1.WeekBucket]
    /// Draw for a hero (white) surface instead of a card.
    var onHero = false

    var body: some View {
        Chart(weeks) { week in
            BarMark(
                x: .value("Week", week.weekStart, unit: .weekOfYear),
                y: .value("Minutes", week.minutes),
                width: .ratio(0.55)
            )
            .cornerRadius(4)
            .foregroundStyle(barColor(week))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .weekOfYear, count: 2)) {
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    .font(.caption2)
                    .foregroundStyle(onHero ? Color.white.opacity(0.7) : Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) {
                AxisGridLine()
                    .foregroundStyle(onHero ? Color.white.opacity(0.15) : Color.secondary.opacity(0.15))
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(onHero ? Color.white.opacity(0.7) : Color.secondary)
            }
        }
        .accessibilityLabel("Minutes played per week")
        .accessibilityValue(accessibilitySummary)
    }

    private func barColor(_ week: PerformanceCoachV1.WeekBucket) -> Color {
        let isCurrent = week.id == weeks.last?.id
        if onHero {
            return isCurrent ? PerformanceTheme.highlight : .white.opacity(0.45)
        }
        return isCurrent ? PerformanceTheme.accent : PerformanceTheme.accent.opacity(0.35)
    }

    private var accessibilitySummary: String {
        weeks.map { "\(Int($0.minutes.rounded())) minutes" }.joined(separator: ", ")
    }
}

/// Five-zone heart-rate intensity as one segmented bar plus a legend.
struct ZoneBreakdownView: View {
    let zones: [PerformanceCoachV1.ZoneShare]
    let heartRateMax: Double

    private var total: Double { zones.reduce(0) { $0 + $1.seconds } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(zones) { zone in
                        if zone.seconds > 0 {
                            Rectangle()
                                .fill(PerformanceTheme.zoneColor(zone.zone))
                                .frame(width: max(3, proxy.size.width * zone.seconds / max(total, 1) - 2))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                ForEach(zones.reversed()) { zone in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(PerformanceTheme.zoneColor(zone.zone))
                            .frame(width: 8, height: 8)
                        Text("Z\(zone.zone) \(zone.name)")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(PerformanceTheme.primaryText)
                        Text(rangeLabel(zone))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(minutesLabel(zone.seconds))
                            .font(.footnote.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(PerformanceTheme.primaryText)
                        Text(percentLabel(zone.seconds))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func rangeLabel(_ zone: PerformanceCoachV1.ZoneShare) -> String {
        let lower = Int((zone.lowerFraction * heartRateMax).rounded())
        return zone.zone == 1 ? "<\(Int((0.6 * heartRateMax).rounded()))" : "\(lower)+"
    }

    private func minutesLabel(_ seconds: Double) -> String {
        "\(Int((seconds / 60).rounded())) min"
    }

    private func percentLabel(_ seconds: Double) -> String {
        guard total > 0 else { return "—" }
        return "\(Int((seconds / total * 100).rounded()))%"
    }
}

extension FootballSessionTypeV1 {
    var symbolName: String {
        switch self {
        case .training: return "figure.run"
        case .calibration: return "scope"
        case .football, .fiveASide, .sevenASide, .elevenASide: return "figure.soccer"
        }
    }
}
