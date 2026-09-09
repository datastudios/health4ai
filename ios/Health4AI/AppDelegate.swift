import UIKit
import HealthKit

// MARK: - AppDelegate

class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // BGTaskScheduler registration removed: BackgroundTasks.framework triggers
        // _libxpc_initializer XPC crash on iOS 27 Beta (24A5355q). Restore when fixed.
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
            BulkExportManager.shared.requestBackgroundTime()
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
            await BulkExportManager.shared.publishEmptyExpectedTypes(syncState: syncState)
            if BulkExportManager.shared.backfillNeeded {
                BulkExportManager.shared.startBackfill(syncState: syncState)
            }
        }
    }
}
