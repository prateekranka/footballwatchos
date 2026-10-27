import SwiftUI

/// First-use guidance. It requests no account, Health access, or network access.
struct OnboardingView: View {
    let complete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG && targetEnvironment(simulator)
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    #endif
    @State private var page = 0

    /// One title and one sentence per page.
    private let pages: [(title: String, text: String, symbol: String)] = [
        (
            "Your football sessions",
            "See your load and work rate, and get a drill for what to improve.",
            "figure.soccer"
        ),
        (
            "Two ways to save",
            "Record on Apple Watch, or log a session on iPhone.",
            "applewatch"
        ),
        (
            "Know what was recorded",
            "Manual logs show only what you enter. A missing reading stays missing.",
            "checkmark.seal"
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
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
}
