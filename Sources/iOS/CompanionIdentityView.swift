import SwiftUI

struct CompanionIdentityView: View {
    var body: some View {
        HStack(alignment: .top, spacing: CompanionDesign.cardSpacing) {
            Image(systemName: "figure.soccer")
                .font(.title)
                .foregroundStyle(.tint)
                .frame(width: CompanionDesign.iconSize, height: CompanionDesign.iconSize)
                .background(.tint.quaternary, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Football Performance")
                    .font(.title2)
                    .bold()

                Text("Your Apple Watch football recorder companion")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
