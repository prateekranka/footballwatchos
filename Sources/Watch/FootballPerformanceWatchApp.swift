import SwiftUI

@main
@MainActor
struct FootballPerformanceWatchApp: App {
    @StateObject private var recorder = WorkoutRecorder()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchCrashSidecarWriter.install()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(
                recorder: recorder,
                motionCapture: recorder.motionCapture
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            WatchLog.capture(
                WatchLog.lifecycle,
                "scenePhase -> \(String(describing: newPhase))"
            )
        }
    }
}
