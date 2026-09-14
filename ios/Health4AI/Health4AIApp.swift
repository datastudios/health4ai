import SwiftUI

// MARK: - Health4AIApp

@main
struct Health4AIApp: App {
    // UIApplicationDelegate adapter: BGTaskScheduler registration has to happen inside
    // didFinishLaunching, which SwiftUI's App protocol does not expose on its own.
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Shared state objects injected into the SwiftUI environment
    // These reference the same singletons used by SyncEngine and BulkExportManager
    @StateObject private var syncState  = SyncEngine.sharedSyncState
    @StateObject private var authManager = SyncEngine.sharedAuthManager

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(syncState)
                .environmentObject(authManager)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // AppDelegate.applicationDidEnterBackground also schedules; submitting the
                // same identifier twice replaces the pending request, so this is a harmless
                // second chance rather than a second task.
                SyncEngine.shared.scheduleBackgroundSync()
            case .active:
                break // AppDelegate.applicationDidBecomeActive handles foreground sync
            default:
                break
            }
        }
    }
}
