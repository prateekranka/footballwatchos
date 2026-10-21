import SwiftUI
import WatchKit

@MainActor
final class FootballPerformanceWatchDelegate: NSObject, WKApplicationDelegate {
    let recorder = WorkoutRecorder()

    func handleActiveWorkoutRecovery() {
        recorder.recoverActiveWorkout()
    }
}

@main
@MainActor
struct FootballPerformanceWatchApp: App {
    @WKApplicationDelegateAdaptor(FootballPerformanceWatchDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchCrashSidecarWriter.install()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(
                recorder: delegate.recorder,
                motionCapture: delegate.recorder.motionCapture
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
