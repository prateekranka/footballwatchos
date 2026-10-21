import SwiftUI

/// Native destination shell: Sessions, Progress, Settings. Session Overview
/// is not a tab; it opens from a session row inside Sessions.
struct RootTabView: View {
    @EnvironmentObject private var library: PhoneSessionLibraryModel
    @AppStorage("appearancePreference") private var appearancePreference = AppearancePreference.system.rawValue
    /// `FP_QA_TAB` (sessions, progress, settings) opens a tab at launch so
    /// CI screenshots can reach it; unset in normal use.
    @State private var selectedTab = UserDefaults.standard.string(forKey: "FP_QA_TAB") ?? "sessions"

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearancePreference) ?? .system
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                SessionsHomeView()
            }
            .tabItem {
                Label("Sessions", systemImage: "figure.run")
            }
            .tag("sessions")

            NavigationStack {
                ProgressHomeView()
            }
            .tabItem {
                Label("Progress", systemImage: "chart.bar.xaxis")
            }
            .tag("progress")

            NavigationStack {
                SettingsHomeView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag("settings")
        }
        .preferredColorScheme(appearance.colorScheme)
        .task {
            #if DEBUG && targetEnvironment(simulator)
            await library.applyLaunchQAScenarioIfRequested()
            #endif
            await library.refresh()
            await library.prepareVisualSummaries(budget: 1)
        }
    }
}

#Preview("Light") {
    RootTabView()
        .environmentObject(PhoneSessionLibraryModel())
}

#Preview("Dark") {
    RootTabView()
        .environmentObject(PhoneSessionLibraryModel())
        .preferredColorScheme(.dark)
}
