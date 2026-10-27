import SwiftUI
import WatchKit

@MainActor
final class FootballPerformanceWatchDelegate: NSObject, WKApplicationDelegate {
    let recorder = WorkoutRecorder()

    func handleActiveWorkoutRecovery() {
        recorder.recoverActiveWorkout()
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                recorder.syncCoordinator.handleBackgroundTask(connectivityTask)
            } else if let snapshotTask = task as? WKSnapshotRefreshBackgroundTask {
                snapshotTask.setTaskCompleted(
                    restoredDefaultState: false,
                    estimatedSnapshotExpiration: .distantFuture,
                    userInfo: nil
                )
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
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
            if newPhase == .active {
                delegate.recorder.syncCoordinator.refreshConnection()
            }
            WatchLog.capture(
                WatchLog.lifecycle,
                "scenePhase -> \(String(describing: newPhase))"
            )
        }
    }
}
