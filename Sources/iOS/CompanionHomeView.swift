import SwiftUI

struct CompanionHomeView: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            SessionLibraryView()
                .navigationTitle("Sessions")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        NavigationLink {
                            WatchDiagnosticsView()
                        } label: {
                            Label("Watch diagnostics", systemImage: "ladybug")
                        }

                        Button {
                            Task { await model.refresh() }
                        } label: {
                            Label("Refresh sessions", systemImage: "arrow.clockwise")
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if let message = model.message {
                        Text(message)
                            .font(.footnote)
                            .padding(12)
                            .background(.regularMaterial, in: Capsule())
                            .padding()
                            .accessibilityElement(children: .combine)
                    }
                }
                .task {
                    await model.refresh()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active else { return }
                    Task { await model.refresh() }
                }
        }
    }
}

#Preview("Default") {
    CompanionHomeView()
}

#Preview("Dark appearance") {
    CompanionHomeView()
        .preferredColorScheme(.dark)
}

#Preview("Accessibility type size") {
    CompanionHomeView()
        .environment(\.dynamicTypeSize, .accessibility3)
}
