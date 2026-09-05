import SwiftUI
import UIKit

/// Adaptive visual language for the redesigned product.
///
/// Light mode is the primary designed appearance: a very light neutral
/// background, white surfaces, navy-black text, and a confident football
/// green accent. Every color is adaptive, so dark mode stays legible without
/// a second design pass. Heart rate is always red, movement cyan, and
/// recording-quality warnings amber, in both appearances.
enum PerformanceTheme {

    // MARK: - Color

    /// Confident football green. The single primary accent.
    static let accent = adaptive(light: UIColor(red: 0.13, green: 0.55, blue: 0.30, alpha: 1),
                                 dark: UIColor(red: 0.22, green: 0.72, blue: 0.42, alpha: 1))

    /// Heart-rate red. Reserved for heart-rate evidence.
    static let heartRate = adaptive(light: UIColor(red: 0.82, green: 0.21, blue: 0.22, alpha: 1),
                                    dark: UIColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1))

    /// Movement cyan. Reserved for wrist-motion evidence.
    static let movement = adaptive(light: UIColor(red: 0.10, green: 0.55, blue: 0.79, alpha: 1),
                                   dark: UIColor(red: 0.30, green: 0.72, blue: 1.00, alpha: 1))

    /// Amber for degraded/interrupted capture states.
    static let warning = adaptive(light: UIColor(red: 0.78, green: 0.58, blue: 0.05, alpha: 1),
                                  dark: UIColor(red: 1.00, green: 0.76, blue: 0.28, alpha: 1))

    /// Navy-black primary text instead of harsh pure black in light mode.
    static let primaryText = adaptive(light: UIColor(red: 0.07, green: 0.11, blue: 0.17, alpha: 1),
                                      dark: UIColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1))

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    // MARK: - Geometry

    static let screenInset: CGFloat = 20
    static let cardInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 24
    static let cardCorner: CGFloat = 20
    static let innerCorner: CGFloat = 12

    // MARK: - Typography

    /// Large, tight-leading screen title as in the approved concept.
    static let screenTitle: Font = .system(size: 30, weight: .bold, design: .default)

    // MARK: - Motion

    /// Press feedback and small state changes: critically damped, short.
    static let pressAnimation = Animation.snappy(duration: 0.16, extraBounce: 0)
    /// Content replacement between related states (e.g. Progress metrics).
    static let replaceAnimation = Animation.snappy(duration: 0.24, extraBounce: 0)
}

/// Card surface with a soft border and low shadow, matching the concept's
/// quiet separation. Does not nest: a card never draws inside another card.
struct PerformanceCard: ViewModifier {
    var padding: CGFloat = PerformanceTheme.cardInset

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: PerformanceTheme.cardCorner, style: .continuous)
                    .fill(colorScheme == .dark ? Color(.secondarySystemGroupedBackground) : .white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PerformanceTheme.cardCorner, style: .continuous)
                    .strokeBorder(.separator.opacity(0.16), lineWidth: 1)
            )
            // Low, soft separation only. Never a large shadow.
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.04), radius: 8, y: 2)
    }
}

extension View {
    func performanceCard(padding: CGFloat = PerformanceTheme.cardInset) -> some View {
        modifier(PerformanceCard(padding: padding))
    }
}

/// Immediate press feedback: scale around 0.98 on touch-down with a short,
/// critically damped spring. Reduce Motion replaces the scale with an opacity
/// change so feedback is never lost.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(PerformanceTheme.pressAnimation, value: configuration.isPressed)
    }
}
