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
            "Keep your football history in one place, from a quick training session to a full 11-a-side session.",
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
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(PerformanceTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .background(PerformanceTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 28))
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

                if page == 1 {
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
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(PerformanceTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
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
