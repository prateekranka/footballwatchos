import SwiftUI

struct RecorderStatusCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: CompanionDesign.cardSpacing) {
            Label("Record on Apple Watch", systemImage: "applewatch")
                .font(.title3)
                .bold()

            Text("Apple Watch is the primary, independent recorder. Start Football on your watch; this iPhone companion is for your later review.")
                .font(.body)
                .foregroundStyle(.secondary)

            Divider()

            Label("Target: Apple Watch Series 8", systemImage: "checkmark.seal")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .accessibilityLabel("Target device: Apple Watch Series 8")
        }
        .padding(CompanionDesign.cardInset)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}
