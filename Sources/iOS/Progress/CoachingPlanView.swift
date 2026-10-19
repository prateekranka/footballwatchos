import SwiftUI

/// Everything the coach has to say: training-load status, then every tip
/// ranked by what matters most right now.
struct CoachingPlanView: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel

    private var snapshot: PerformanceCoachV1.TrainingSnapshot {
        PerformanceCoachV1.snapshot(records: model.sessions)
    }

    private var tips: [PerformanceCoachV1.Tip] {
        PerformanceCoachV1.tips(records: model.sessions, snapshot: snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerformanceTheme.sectionSpacing) {
                LoadStatusCard(snapshot: snapshot)

                let personal = tips.filter { !$0.isGeneral }
                let general = tips.filter(\.isGeneral)

                if !personal.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "From your sessions", caption: "Ranked by what matters most right now.")
                        ForEach(personal) { CoachTipCard(tip: $0) }
                    }
                }

                if !general.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Foundations", caption: "Weekly habits that make every footballer fitter.")
                        ForEach(general) { CoachTipCard(tip: $0) }
                    }
                }

                if tips.isEmpty {
                    Text("Log a few sessions and your plan appears here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .performanceCard()
                }

                Text("Guidance, not medical advice. Stop and get checked if something hurts.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, PerformanceTheme.screenInset)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Your plan")
        .navigationBarTitleDisplayMode(.large)
    }
}

/// Acute:chronic training load as a simple, labelled gauge.
struct LoadStatusCard: View {
    let snapshot: PerformanceCoachV1.TrainingSnapshot

    private enum Status {
        case unknown, low, steady, high

        var title: String {
            switch self {
            case .unknown: return "Building history"
            case .low: return "Lighter than usual"
            case .steady: return "Steady build"
            case .high: return "Load spike"
            }
        }

        var detail: String {
            switch self {
            case .unknown: return "After a few weeks of sessions, this compares your last 7 days with your usual week."
            case .low: return "A lighter week is fine for recovery. Rebuild gradually so you don't spike later."
            case .steady: return "Your last 7 days are in line with your usual week. This is the sweet spot for getting fitter safely."
            case .high: return "Much more than your usual week. Keep the next few days lighter."
            }
        }

        var tint: Color {
            switch self {
            case .unknown: return .secondary
            case .low: return PerformanceTheme.movement
            case .steady: return PerformanceTheme.accent
            case .high: return PerformanceTheme.warning
            }
        }
    }

    private var status: Status {
        guard let ratio = snapshot.loadRatio else { return .unknown }
        if ratio > 1.5 { return .high }
        if ratio < 0.8 { return .low }
        return .steady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconBadge(systemName: "gauge.with.dots.needle.67percent", tint: status.tint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TRAINING LOAD")
                        .font(.caption2.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text(status.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(status.tint)
                }
            }

            if let ratio = snapshot.loadRatio {
                Gauge(value: min(ratio, 2), in: 0...2) {
                    EmptyView()
                } currentValueLabel: {
                    Text(String(format: "%.1f×", ratio))
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("2×")
                }
                .gaugeStyle(.accessoryLinear)
                .tint(Gradient(colors: [PerformanceTheme.movement, PerformanceTheme.accent, PerformanceTheme.warning]))
                .accessibilityLabel("Load ratio")
                .accessibilityValue(String(format: "%.1f times your usual week", ratio))
            }

            HStack(spacing: 0) {
                StatBlock(value: "\(Int(snapshot.acuteMinutes.rounded())) min", caption: "Last 7 days")
                StatBlock(
                    value: snapshot.chronicWeeklyMinutes.map { "\(Int($0.rounded())) min" } ?? "—",
                    caption: "Usual week"
                )
                StatBlock(value: "\(snapshot.streakWeeks)", caption: "Week streak")
            }

            Text(status.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .performanceCard()
    }
}
