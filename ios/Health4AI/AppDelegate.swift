import UIKit
import HealthKit

// MARK: - AppDelegate

/// UIApplicationDelegate responsible for:
/// - BGTaskScheduler registration (must happen before didFinishLaunching returns)
/// - Foreground sync on launch and app-foreground transitions
/// - HealthKit observer startup after auth check
/// - Scheduling the background sync and backfill tasks when the app leaves the foreground
class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register BGTask handlers BEFORE the app finishes launching. The system silently
        // ignores registrations made after launch completes, and a launch triggered by a
        // pending task would then find no handler. UIKit guarantees the main thread here.
        MainActor.assumeIsolated {
            SyncEngine.shared.registerBackgroundTasks()
            BulkExportManager.shared.registerBackgroundBackfillTask()
        }
        Task { @MainActor in
            self.reconnectIfAuthenticated()
        }
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task { @MainActor in
            let authManager = SyncEngine.sharedAuthManager
            if authManager.isSignedIn {
                SyncEngine.shared.performForegroundSync()
            }
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        Task { @MainActor in
            SyncEngine.shared.scheduleBackgroundSync()
            BulkExportManager.shared.requestBackgroundTime()
            BulkExportManager.shared.scheduleBackgroundBackfill()
        }
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        Task { @MainActor in
            BulkExportManager.shared.endBackgroundTime()
        }
    }

    // MARK: - Private helpers

    @MainActor
    private func reconnectIfAuthenticated() {
        let authManager = SyncEngine.sharedAuthManager
        guard authManager.isSignedIn else { return }

        let syncState = SyncEngine.sharedSyncState
        syncState.isAuthenticated = true
        syncState.userEmail = authManager.storedEmail

        guard HKHealthStore.isHealthDataAvailable() else { return }
        Task { @MainActor in
            SyncEngine.shared.startObserving()
            SyncEngine.shared.performForegroundSync()
            await BulkExportManager.shared.applyStuckTypeMigrationIfNeeded(syncState: syncState)
            await BulkExportManager.shared.applyMergedHoursResendIfNeeded(syncState: syncState)
            await BulkExportManager.shared.publishEmptyExpectedTypes(syncState: syncState)
            if BulkExportManager.shared.backfillNeeded {
                BulkExportManager.shared.startBackfill(syncState: syncState)
            }
        }
    }
}
