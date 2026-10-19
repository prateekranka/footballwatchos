import SwiftUI

@main
struct FootballPerformanceApp: App {
    @StateObject private var library: PhoneSessionLibraryModel
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false

    init() {
        // Build the local recipient and activate WCSession before the scene is
        // displayed. Import success remains a repository concern, not a WC
        // callback claim.
        PhoneTransferRuntime.shared.start()
        _library = StateObject(wrappedValue: PhoneSessionLibraryModel())
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingCompleted {
                    RootTabView()
                } else {
                    OnboardingView { onboardingCompleted = true }
                }
            }
            .environmentObject(library)
            #if DEBUG && targetEnvironment(simulator)
            .modifier(SimulatorQAEnvironment(model: library))
            #endif
        }
    }
}
