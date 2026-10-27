import SwiftUI

/// First-use guidance. It requests no account, Health access, or network access.
struct OnboardingView: View {
    let complete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG && targetEnvironment(simulator)
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    #endif
    @State private var page = 0

    private let pages: [(title: String, text: String, symbol: String)] = [
        (
            "Your football sessions",
            "Log every game and training session. See your load, intensity, and work rate, and get drills that make you fitter on the pitch.",
            "figure.soccer"
        ),
        (
            "Two ways to save",
            "Start a recording on Apple Watch for sensor readings. Or add a manual log on iPhone with the date, duration, and football type.",
            "applewatch"
        ),
        (
            "Know what was recorded",
            "Watch recordings can include heart rate, distance, and motion. Manual logs show only what you enter. A missing reading stays missing.",
            "checkmark.seal"
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("FOOTBALL PERFORMANCE")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(PerformanceTheme.accent)

                Image(systemName: pages[page].symbol)
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(PerformanceTheme.highlight)
                    .frame(maxWidth: .infinity, minHeight: 170)
                    .heroSurface()
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 16) {
                    Text(pages[page].title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(PerformanceTheme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("onboarding-title")
                    Text(pages[page].text)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .id(page)
                .transition(.opacity)

                if page == 0 {
                    guidance("Track your load", detail: "Minutes per week, streaks, and warnings when you ramp up too fast.", symbol: "gauge.with.dots.needle.67percent")
                    guidance("Get better every week", detail: "Each session ends with what to work on and a drill to do it.", symbol: "figure.soccer")
                } else if page == 1 {
                    guidance("Record on Watch", detail: "Your Watch records without a phone or internet connection.", symbol: "waveform.path.ecg")
                    guidance("Log on iPhone", detail: "Choose Football, 5-a-side, 7-a-side, 11-a-side, Training, or Calibration.", symbol: "square.and.pencil")
                } else if page == 2 {
                    guidance("Your own baseline", detail: "Comparisons need three valid Watch recordings. Manual logs do not count.", symbol: "chart.bar.xaxis")
                    guidance("Your data, clearly labelled", detail: "Manual logs stay on this iPhone. Watch recordings keep their recorded source and quality.", symbol: "iphone")
                }
            }
            .padding(.horizontal, PerformanceTheme.screenInset)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .id(page)
        .background(Color(.systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    if page > 0 {
                        Button("Back") { move(to: page - 1) }
                            .accessibilityIdentifier("onboarding-back")
                    }
                    Spacer()
                    Text("\(page + 1) of \(pages.count)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel("Step \(page + 1) of \(pages.count)")
                }
                Button {
                    if page == pages.count - 1 { complete() }
                    else { move(to: page + 1) }
                } label: {
                    Text(page == pages.count - 1 ? "Get started" : "Continue")
                        .font(.headline)
                        .foregroundStyle(PerformanceTheme.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(PerformanceTheme.accent)
                .accessibilityIdentifier("onboarding-continue")
            }
            .padding(PerformanceTheme.screenInset)
            .background(.regularMaterial)
        }
        #if DEBUG && targetEnvironment(simulator)
        .modifier(SimulatorQAEnvironment(model: model))
        #endif
    }

    private func move(to nextPage: Int) {
        withAnimation(reduceMotion ? nil : PerformanceTheme.replaceAnimation) { page = nextPage }
    }

    private func guidance(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemName: symbol, tint: PerformanceTheme.accent, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .performanceCard()
    }
}
