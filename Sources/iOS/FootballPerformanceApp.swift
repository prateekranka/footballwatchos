import SwiftUI

@main
struct FootballPerformanceApp: App {
    @StateObject private var library: PhoneSessionLibraryModel

    init() {
        // Build the local recipient and activate WCSession before the scene is
        // displayed. Import success remains a repository concern, not a WC
        // callback claim.
        PhoneTransferRuntime.shared.start()
        _library = StateObject(wrappedValue: PhoneSessionLibraryModel())
    }

    var body: some Scene {
        WindowGroup {
            CompanionHomeView()
                .environmentObject(library)
        }
    }
}
