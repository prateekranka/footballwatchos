#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Real SwiftUI layout constraints for the isolated simulator QA vault.
/// Release builds contain neither these controls nor these overrides.
enum SimulatorQALayout: String, CaseIterable, Identifiable {
    case standard, narrow, largeText, largeNarrow, rightToLeft, noAnimations

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "Standard"
        case .narrow: "320 pt width"
        case .largeText: "200% text"
        case .largeNarrow: "200% text at 320 pt"
        case .rightToLeft: "Right to left"
        case .noAnimations: "Animations off"
        }
    }
    var isNarrow: Bool { self == .narrow || self == .largeNarrow }
    var usesLargeText: Bool { self == .largeText || self == .largeNarrow }
}

struct SimulatorQAEnvironment: ViewModifier {
    @ObservedObject var model: PhoneSessionLibraryModel
    @Environment(\.dynamicTypeSize) private var systemTextSize
    @Environment(\.layoutDirection) private var systemDirection

    func body(content: Content) -> some View {
        let layout = model.isUIQA ? model.qaLayout : .standard
        content
            .frame(maxWidth: layout.isNarrow ? 320 : .infinity)
            .environment(\.dynamicTypeSize, layout.usesLargeText ? .accessibility3 : systemTextSize)
            .environment(\.layoutDirection, layout == .rightToLeft ? .rightToLeft : systemDirection)
            .transaction { transaction in
                if layout == .noAnimations {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
    }
}
#endif
