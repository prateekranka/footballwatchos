import SwiftUI

/// Native destination shell. Sessions and Settings now; Progress joins as
/// its own destination in the same redesign series. Session Overview is not
/// a tab: it opens from a session row inside Sessions.
struct RootTabView: View {
    @EnvironmentObject private var library: PhoneSessionLibraryModel
    @AppStorage("appearancePreference") private var appearancePreference = AppearancePreference.system.rawValue

    private var appearance: AppearancePreference {
        AppearancePreference(rawValue: appearancePreference) ?? .system
    }

    var body: some View {
        TabView {
            NavigationStack {
                SessionsHomeView()
            }
            .tabItem {
                Label("Sessions", systemImage: "figure.run")
            }

            NavigationStack {
                SettingsHomeView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .task {
            await library.refresh()
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
