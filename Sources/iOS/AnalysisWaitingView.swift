import SwiftUI

struct AnalysisWaitingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No analysis on iPhone yet", systemImage: "chart.xyaxis.line")
        } description: {
            Text("Analysis arrives after Watch sync in a later slice.")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(CompanionDesign.cardInset)
        .background(.background, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}
