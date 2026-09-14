import Foundation
import HealthKit
import BackgroundTasks
import UIKit

// MARK: - SyncEngine

/// Orchestrates all sync pathways:
/// - HKObserverQuery with HealthKit background delivery (wakes the app when a type gets new samples)
/// - BGAppRefreshTask `com.health4ai.sync` (iOS-scheduled safety net, hourly at the earliest)
/// - Workout completion observer (immediate sync on workout end)
/// - Foreground launch sync (on every app open)
///
/// Also handles batched HTTP POST with retry logic.

/// Marks a BGTask completed exactly once.
///
/// The expiration handler and the work itself race to finish the task, and whichever loses
/// would otherwise call `setTaskCompleted` a second time. Lock, not actor: the expiration
/// handler arrives on an arbitrary queue and must complete synchronously.
final class BGTaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var done = false

    init(_ task: BGTask) { self.task = task }

    func finish(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        task.setTaskCompleted(success: success)
    }
}

/// FIFO async mutex.
///
/// A Swift `actor` is re-entrant across `await`: another call enters at every suspension
/// point, so actor isolation alone does not serialize an operation that suspends — and a
/// sync suspends twice per page, on the HealthKit query and on the HTTP post. This gives
/// real mutual exclusion across those awaits.
actor SyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Whether a server's ingest function replaces per-device rows when it stores a merged hour.
///
/// An older deployment stores merged hours WITHOUT deleting that hour's per-device rows, so the
/// same steps would be counted by both, which is worse than not merging at all. The app sends
/// merged hours only where the function has answered `merged_hours_v1`. It asks once per launch
/// per endpoint, so a function updated while the app runs is picked up at the next launch, and an
/// older function redeployed over a newer one is noticed too. Register D361.
actor MergedHoursCapability {
    static let shared = MergedHoursCapability()
    private var answers: [String: Bool] = [:]

    func isSupported(serverURL: String, token: String) async throws -> Bool {
        if let known = answers[serverURL] { return known }
        let supported = try await Self.ask(serverURL: serverURL, token: token)
        answers[serverURL] = supported
        return supported
    }

    /// An empty batch writes nothing and every version of the function answers it after
    /// verifying the token. Only a 2xx is an answer; anything else throws, so a network failure
    /// is never mistaken for "not supported".
    private static func ask(serverURL: String, token: String) async throws -> Bool {
        guard let url = URL(string: serverURL) else { throw SyncError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"samples":[]}"#.utf8)
        // Same as postSamples. Shorter, a network slow enough to time out here but not there
        // would fail the page on the check while the post itself would have gone through.
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.invalidResponse }
        switch http.statusCode {
        case 200...299: return parseCapabilities(data).contains("merged_hours_v1")
        case 401:       throw SyncError.unauthorized
        default:        throw SyncError.httpError(http.statusCode)
        }
    }

    /// A 2xx body that is not JSON, or JSON without `capabilities`, declares none. That is the
    /// honest reading of a REST endpoint or an older function, not a parse failure to hide.
    static func parseCapabilities(_ data: Data) -> Set<String> {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capabilities = object["capabilities"] as? [String] else { return [] }
        return Set(capabilities)
    }
}

final class SyncEngine {

    @MainActor static let shared = SyncEngine()

    /// Guards `syncAnchors` and keeps two sync passes from overlapping.
    ///
    /// Both were live: `AppDelegate.didFinishLaunching` starts a full pass and
    /// `applicationDidBecomeActive` starts a second one moments later on the same cold
    /// launch, while any observer fire adds a third. They shared an unsynchronized
    /// Dictionary — undefined behaviour in Swift — and could regress each other's anchor,
    /// re-fetching a window that had already been posted.
    private static let syncMutex = SyncMutex()

    /// Whether a full pass is in flight. Deliberately NOT `syncState.isSyncing`.
    ///
    /// `isSyncing` is UI state, and the observer path writes it too: an observer firing
    /// mid-pass calls `recordSyncComplete`, which sets it false. Guarding on it would have
    /// let a second full pass start while the first was still running — the very thing the
    /// guard exists to prevent. MainActor-isolated so the claim below can be a single
    /// atomic hop.
    @MainActor private static var fullSyncInFlight = false

    /// Runs `body` with no other sync in flight.
    private static func serialized<T>(_ body: () async throws -> T) async rethrows -> T {
        await syncMutex.lock()
        do {
            let result = try await body()
            await syncMutex.unlock()
            return result
        } catch {
            await syncMutex.unlock()
            throw error
        }
    }

    static let batchSize = 500

    private let hkManager = HealthKitManager.shared
    private let authManager: AuthManager
    private let syncState: SyncState

    // Active observer queries keyed by type identifier
    private var observerQueries: [String: HKObserverQuery] = [:]

    // Serializes HTTP POST operations
    private let postQueue = DispatchQueue(label: "com.healthkitbridge.postQueue", qos: .utility)

    // Track last sync anchor per type to avoid re-syncing old data
    private var syncAnchors: [String: HKQueryAnchor] = [:]
    private static let anchorsKey = "hkb.syncAnchors"

    // ISO8601 date formatter for JSON
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    @MainActor
    private init() {
        self.authManager = AuthManager()
        self.syncState = SyncState()
        loadAnchors()
    }

    // MARK: - Shared state accessor (used by AppDelegate and views)

    @MainActor static var sharedAuthManager: AuthManager { shared.authManager }
    @MainActor static var sharedSyncState: SyncState { shared.syncState }

    // MARK: - BGTaskScheduler registration

    /// Must match an entry in Info.plist `BGTaskSchedulerPermittedIdentifiers`.
    static let backgroundSyncTaskIdentifier = "com.health4ai.sync"

    /// Earliest-begin offset for the refresh task, targeting a roughly hourly cadence. iOS
    /// treats it as a floor and runs the task when it chooses to.
    static let backgroundSyncInterval: TimeInterval = 55 * 60

    /// Call during app launch, before `didFinishLaunching` returns.
    ///
    /// Restored 2026-09-14. Removed 2026-06-18 with the entitlement and both Info.plist keys
    /// as a workaround for an iOS 27 Beta 1 `_libxpc_initializer` crash, which left observers
    /// firing only in the foreground: measured 2026-09-11, not one row reached the database in
    /// 48 hours. Register D335.
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundSyncTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self = self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundSyncTask(refreshTask)
        }
    }

    /// Submits the next refresh request. Called after every full pass and whenever the app
    /// leaves the foreground; resubmitting the same identifier replaces the pending request.
    ///
    /// `nextScheduledSync` is written here and nowhere else. It used to be declared and read
    /// but never written, so the Home card said "Not scheduled" forever.
    @MainActor
    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundSyncTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.backgroundSyncInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
            syncState.nextScheduledSync = request.earliestBeginDate
        } catch let error as BGTaskScheduler.Error where error.code == .tooManyPendingTaskRequests {
            // A request for this identifier is already pending; the earlier date still stands.
            // Documented behaviour is that a resubmit replaces it, so this branch is not
            // expected, but if it ever fires the card must not say "Not scheduled" while a
            // request is queued.
            print("[SyncEngine] Background sync already pending: \(error)")
        } catch {
            // Fails on the simulator and when the identifier is missing from Info.plist. nil is
            // rendered as "Not scheduled", which is the true state; nothing is left claiming a
            // sync that will not come.
            syncState.nextScheduledSync = nil
            print("[SyncEngine] Failed to schedule background sync: \(error)")
        }
    }

    // MARK: - Background task handler

    /// Runs the same anchored pass as the foreground path, under the task's expiration.
    ///
    /// The expiration handler is installed before the work starts, as BackgroundTasks
    /// requires. On expiry the pass is cancelled: every page already posted has saved its
    /// anchor, so the next pass resumes rather than repeats.
    private func handleBackgroundSyncTask(_ task: BGAppRefreshTask) {
        let completion = BGTaskCompletion(task)
        var syncTask: Task<Void, Never>?
        task.expirationHandler = {
            syncTask?.cancel()
            completion.finish(success: false)
        }
        syncTask = Task {
            // Reschedule first, so a kill mid-pass still leaves a request pending.
            await MainActor.run { self.scheduleBackgroundSync() }
            let outcome = await self.runFullPass()
            if outcome == .skipped {
                // A pass is already running (a background launch starts one from
                // didFinishLaunching moments before this handler fires). Hold the task
                // assertion until it finishes so iOS does not suspend it half way.
                await self.waitForInFlightPass()
            }
            completion.finish(success: outcome != .failed)
        }
    }

    private func waitForInFlightPass() async {
        while await MainActor.run(body: { Self.fullSyncInFlight }) {
            guard (try? await Task.sleep(nanoseconds: 500_000_000)) != nil else { return }
        }
    }

    // MARK: - HKObserverQuery registration

    /// Registers background delivery and observer queries for all HealthKit types.
    /// Call after authorization is granted.
    func startObserving() {
        let types = HealthKitManager.sampleTypes()

        for sampleType in types {
            // Enable background delivery (fires our app when new data is written). A failure
            // becomes published state: the Home card then says background sync is unavailable
            // instead of the app quietly syncing only while open. Register D335.
            hkManager.store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { [weak self] success, error in
                guard let self = self else { return }
                let enabled = success && error == nil
                Task { @MainActor in
                    self.syncState.recordBackgroundDelivery(for: sampleType.identifier, enabled: enabled)
                }
            }

            // Create observer query
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
                guard let self = self else {
                    completionHandler()
                    return
                }
                if let error = error {
                    print("[SyncEngine] Observer query error for \(sampleType.identifier): \(error)")
                    completionHandler()
                    return
                }
                // Perform incremental sync for this type only
                Task {
                    do {
                        let count = try await self.syncType(sampleType)
                        if count > 0 {
                            await MainActor.run {
                                self.syncState.recordSyncComplete(count: count)
                            }
                        }
                    } catch {
                        print("[SyncEngine] Sync error for \(sampleType.identifier): \(error)")
                    }
                    completionHandler()
                }
            }

            observerQueries[sampleType.identifier] = query
            hkManager.store.execute(query)
        }

        // Special observer for workout completion
        registerWorkoutObserver()
    }

    /// Stops all observer queries (call on sign-out).
    func stopObserving() {
        for (_, query) in observerQueries {
            hkManager.store.stop(query)
        }
        observerQueries.removeAll()
    }

    // MARK: - Workout completion observer

    private func registerWorkoutObserver() {
        let workoutType = HKWorkoutType.workoutType()
        let query = HKObserverQuery(sampleType: workoutType, predicate: nil) { [weak self] _, completionHandler, error in
            guard let self = self else { completionHandler(); return }
            if error != nil { completionHandler(); return }

            Task {
                do {
                    let count = try await self.syncType(workoutType)
                    if count > 0 {
                        await MainActor.run {
                            self.syncState.recordSyncComplete(count: count)
                        }
                    }
                } catch {
                    print("[SyncEngine] Workout sync error: \(error)")
                }
                completionHandler()
            }
        }
        hkManager.store.execute(query)
    }

    // MARK: - Foreground sync

    /// Syncs all types using anchored queries (only new data since last sync).
    /// Call on every app foreground / launch.
    func performForegroundSync() {
        Task { await runFullPass() }
    }

    enum FullPassOutcome {
        /// Another pass was already in flight; nothing was run.
        case skipped
        case succeeded
        /// At least one type failed, or the pass was cancelled before finishing.
        case failed
    }

    /// The one full anchored pass, shared by the foreground path and the BGAppRefreshTask
    /// handler. Publishes its outcome to `syncState` and schedules the next background
    /// refresh whatever the outcome, so a failed pass is retried rather than orphaned.
    @discardableResult
    func runFullPass() async -> FullPassOutcome {
        // Test AND set in ONE MainActor hop. Reading the flag, awaiting, then writing
        // it is check-then-act: both cold-launch callers (didFinishLaunching and
        // applicationDidBecomeActive, which fire within moments of each other) could
        // observe false before either wrote true, and both would proceed — exactly the
        // duplicate pass this guard exists to stop.
        let claimed = await MainActor.run { () -> Bool in
            guard !Self.fullSyncInFlight else { return false }
            Self.fullSyncInFlight = true
            self.syncState.isSyncing = true
            return true
        }
        guard claimed else { return .skipped }

        do {
            let outcome = try await performFullSync()
            return await MainActor.run {
                Self.fullSyncInFlight = false
                defer { self.scheduleBackgroundSync() }
                if outcome.failures.isEmpty {
                    self.syncState.recordSyncComplete(count: outcome.count)
                    return .succeeded
                } else if outcome.failures.count == outcome.attempted {
                    // Every type failed. Reporting this as a completed sync of 0
                    // records is how a total outage looks like a quiet day.
                    let first = outcome.failures[0]
                    self.syncState.recordSyncError(
                        "Sync failed for all \(outcome.attempted) data types. "
                        + "\(first.error.localizedDescription)")
                    return .failed
                } else {
                    self.syncState.recordSyncPartial(
                        count: outcome.count,
                        failed: outcome.failures.count,
                        ofTypes: outcome.attempted)
                    return .failed
                }
            }
        } catch is CancellationError {
            // iOS reclaimed the background task's time. Not a sync error to show the user:
            // every page already posted saved its anchor and the next pass resumes there.
            await MainActor.run {
                Self.fullSyncInFlight = false
                self.syncState.recordSyncCancelled()
                self.scheduleBackgroundSync()
            }
            return .failed
        } catch {
            await MainActor.run {
                Self.fullSyncInFlight = false
                self.syncState.recordSyncError(error.localizedDescription)
                self.scheduleBackgroundSync()
            }
            return .failed
        }
    }

    // MARK: - Full sync (all types, anchored)

    /// - Returns: records synced, the per-type failures, and how many types were tried.
    ///
    /// The failures are RETURNED, not just logged. Per-type `do/catch` stopped one bad type
    /// aborting the pass, but on its own it also meant the pass could never throw, so the
    /// caller's error branch went dead and 107-of-107 failures reported as a clean sync.
    @discardableResult
    func performFullSync() async throws
        -> (count: Int, failures: [(type: String, error: Error)], attempted: Int) {
        let types = HealthKitManager.sampleTypes()
        var totalCount = 0

        // Sync each type sequentially to keep memory usage bounded.
        //
        // Per-type do/catch, matching BulkExportManager.runBackfill. This loop used to be a
        // bare `try await`, so ONE type throwing — a transient 5xx, a token expiring
        // mid-pass, a single bad HealthKit query — abandoned every type after it in
        // iteration order, and an abandoned pass is not retried until the next pass.
        //
        // Cancellation is the one thing that does stop the loop: it means iOS is reclaiming
        // background time, and pressing on would only get the process suspended mid-post.
        var failures: [(type: String, error: Error)] = []
        for sampleType in types {
            try Task.checkCancellation()
            do {
                totalCount += try await syncType(sampleType)
            } catch {
                failures.append((sampleType.identifier, error))
                print("[SyncEngine] Sync failed for \(sampleType.identifier): \(error)")
            }
        }
        if !failures.isEmpty {
            print("[SyncEngine] \(failures.count) of \(types.count) types failed this pass")
        }
        return (totalCount, failures, types.count)
    }

    // MARK: - Merged hourly totals

    /// Whether this server may be sent merged hours. Also publishes the answer, so Home can say
    /// when step and energy totals are still being counted per device.
    func mergedHoursAllowed(serverURL: String, token: String) async throws -> Bool {
        let supported = try await MergedHoursCapability.shared.isSupported(serverURL: serverURL, token: token)
        await MainActor.run {
            // Only an answer about the endpoint still configured. A check for the old URL that
            // resolves after the user switched projects would otherwise label the new one.
            guard syncState.resolvedEndpointURL == serverURL else { return }
            syncState.serverLacksMergedHours = !supported
        }
        return supported
    }

    // MARK: - Per-type anchored sync

    /// Queries new samples since the last anchor for `sampleType`, posts them,
    /// and saves the new anchor.
    func syncType(_ sampleType: HKSampleType) async throws -> Int {
        try await Self.serialized { try await self.syncTypeLocked(sampleType) }
    }

    /// The body of `syncType`. Only ever called while `syncMutex` is held, which is what
    /// makes the `syncAnchors` reads and writes below safe.
    private func syncTypeLocked(_ sampleType: HKSampleType) async throws -> Int {
        let serverURL = await MainActor.run { syncState.resolvedEndpointURL }
        let token: String
        do {
            token = try await authManager.validToken(serverURL: serverURL)
        } catch {
            throw SyncError.authFailed(error.localizedDescription)
        }

        // Drain pages until one comes back short. A single page would silently sync only
        // the first 5,000 changes and leave the rest until the next observer fire, which
        // on a first run for a high-volume type means never catching up.
        var total = 0
        while true {
            let anchor = syncAnchors[sampleType.identifier]
            let (samples, newAnchor) = try await queryAnchoredSamples(
                type: sampleType, anchor: anchor)

            if samples.isEmpty {
                // Save the anchor even on an empty page: it is how HealthKit says
                // "you are caught up", and discarding it re-asks the same question.
                if let newAnchor { syncAnchors[sampleType.identifier] = newAnchor; saveAnchors() }
                return total
            }

            // Double-counted activity types post HealthKit's merged hourly totals, never raw
            // samples: summing raw samples counts an iPhone and a Watch twice. Only to a server
            // that replaces per-device rows with them. See HealthKitManager.syncsAsHourlyTotals
            // and MergedHoursCapability.
            var usesMergedHours = false
            if HealthKitManager.syncsAsHourlyTotals(sampleType) {
                usesMergedHours = try await mergedHoursAllowed(serverURL: serverURL, token: token)
            }
            let healthSamples: [HealthSample]
            if usesMergedHours, let quantityType = sampleType as? HKQuantityType {
                healthSamples = try await hkManager.hourlyTotals(for: quantityType, touchedBy: samples)
            } else {
                healthSamples = samples.compactMap { hkManager.convert(sample: $0) }
            }
            if !healthSamples.isEmpty {
                let batches = stride(from: 0, to: healthSamples.count, by: Self.batchSize).map {
                    Array(healthSamples[$0..<min($0 + Self.batchSize, healthSamples.count)])
                }
                for batch in batches {
                    try await postSamples(batch, token: token, serverURL: serverURL)
                }
                // HealthKit samples, not rows posted. An hourly total is re-posted every time
                // the observer fires within that hour, so counting rows would grow the
                // lifetime figure a dozen times over for one stored row.
                total += usesMergedHours ? samples.count : healthSamples.count
            }

            // Advance ONLY after the page's rows are posted, so a failure mid-page
            // re-fetches that page rather than skipping it.
            guard let newAnchor else { return total }
            syncAnchors[sampleType.identifier] = newAnchor
            saveAnchors()

            if samples.count < Self.anchorPageSize { return total }
        }
    }

    // MARK: - Anchored HKSample query

    /// One PAGE of changes since `anchor`. Never unbounded.
    ///
    /// This was `HKObjectQueryNoLimit`, which on a first run (anchor nil, predicate nil)
    /// asks HealthKit for a type's ENTIRE history in one shot. For StepCount, HeartRate
    /// and ActiveEnergyBurned that is 800,000+ samples; the query never completes, so no
    /// anchor is ever saved, so the next run reissues exactly the same impossible query.
    /// Those three types had therefore NEVER live-synced a single row in the app's whole
    /// history — verified against the database: 0 rows for each arrived within two days of
    /// being recorded, while DistanceWalkingRunning and BasalEnergyBurned, which happened
    /// to get a successful first run years ago when their histories were small, have
    /// worked off small deltas ever since.
    ///
    /// BulkExportManager already chunks for exactly this reason ("Loading all records at
    /// once (400K+ for steps/HR) causes iOS OOM kills") — that lesson was never applied
    /// here. Paged, each page's anchor is saved, so a first sync makes durable progress
    /// and a kill resumes instead of restarting.
    static let anchorPageSize = 5_000

    private func queryAnchoredSamples(
        type sampleType: HKSampleType,
        anchor: HKQueryAnchor?
    ) async throws -> ([HKSample], HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: nil,
                anchor: anchor,
                limit: Self.anchorPageSize
            ) { _, added, _, newAnchor, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (added ?? [], newAnchor))
                }
            }
            hkManager.store.execute(query)
        }
    }

    // MARK: - HTTP POST with retry

    /// Posts a batch of HealthSamples to the configured endpoint.
    /// Retries up to 3 times with exponential backoff (1s, 2s, 4s).
    /// Reads `{"inserted": N}` from an ingest response. Returns nil when the field is
    /// absent or not a number, so an older or third-party endpoint degrades to "unknown"
    /// rather than to a fabricated success count.
    static func parseInsertedCount(_ data: Data) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let n = obj["inserted"] as? Int { return n }
        // Int(exactly:), never Int(_:). The endpoint is user-supplied, and Int(Double)
        // TRAPS on anything outside Int's range — a server echoing {"inserted": 1e30}
        // would crash the app on every batch. nil is the contract for "unknown".
        if let d = obj["inserted"] as? Double { return Int(exactly: d.rounded()) }
        return nil
    }

    /// - Returns: the count the SERVER reports having written, or nil if it did not say.
    ///
    /// The endpoint upserts on (user_id, metric_type, started_at), so a batch that posts
    /// successfully may store nothing at all — every sample already present. Treating
    /// "the POST returned 2xx" as "N records synced" is how the import came to report
    /// 255,000 records while the table gained zero rows. nil means unknown, and unknown
    /// must never be rendered as the batch size.
    @discardableResult
    func postSamples(
        _ samples: [HealthSample],
        token: String,
        serverURL: String
    ) async throws -> Int? {
        guard let url = URL(string: serverURL) else {
            throw SyncError.invalidURL
        }

        let batch = SampleBatch(samples: samples)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.dateFormatter.string(from: date))
        }

        let bodyData = try encoder.encode(batch)

        var lastError: Error = SyncError.unknownPostFailure
        let maxAttempts = 3

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                // Exponential backoff: 1s, 2s, 4s
                let delay = pow(2.0, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = bodyData
            request.timeoutInterval = 60

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SyncError.invalidResponse
                }

                switch httpResponse.statusCode {
                case 200...299:
                    return Self.parseInsertedCount(data)
                case 401:
                    throw SyncError.unauthorized
                case 429, 503:
                    // Rate limited or unavailable — retry
                    lastError = SyncError.serverError(httpResponse.statusCode)
                    continue
                default:
                    lastError = SyncError.httpError(httpResponse.statusCode)
                    if httpResponse.statusCode >= 500 {
                        continue // retry on 5xx
                    } else {
                        throw lastError // don't retry on 4xx
                    }
                }
            } catch let syncError as SyncError {
                if case .unauthorized = syncError { throw syncError }
                lastError = syncError
                if attempt == maxAttempts - 1 { throw lastError }
            } catch {
                lastError = error
                if attempt == maxAttempts - 1 { throw lastError }
            }
        }

        throw lastError
    }

    // MARK: - Anchor persistence

    private func loadAnchors() {
        guard let data = UserDefaults.standard.data(forKey: Self.anchorsKey),
              let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSString.self, HKQueryAnchor.self], from: data) as? [String: HKQueryAnchor] else {
            return
        }
        syncAnchors = decoded
    }

    private func saveAnchors() {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: syncAnchors as NSDictionary, requiringSecureCoding: true) else {
            return
        }
        UserDefaults.standard.set(data, forKey: Self.anchorsKey)
    }

    /// Clears all sync anchors (call before a full backfill to allow re-sync).
    ///
    /// Under the mutex like every other `syncAnchors` access. Unguarded, this raced a sync
    /// already in flight, which would write its own anchor back immediately afterwards and
    /// quietly defeat the reset.
    func resetAnchors() {
        Task {
            await Self.serialized {
                self.syncAnchors.removeAll()
                UserDefaults.standard.removeObject(forKey: Self.anchorsKey)
            }
        }
    }
}

// MARK: - SyncError

enum SyncError: LocalizedError {
    case authFailed(String)
    case invalidURL
    case invalidResponse
    case unauthorized
    case serverError(Int)
    case httpError(Int)
    case unknownPostFailure

    var errorDescription: String? {
        switch self {
        case .authFailed(let m):        return "Auth failed: \(m)"
        case .invalidURL:               return "Invalid server URL"
        case .invalidResponse:          return "Invalid HTTP response"
        case .unauthorized:             return "Unauthorized — please sign in again"
        case .serverError(let code):    return "Server error \(code)"
        case .httpError(let code): return "HTTP \(code)"
        case .unknownPostFailure:       return "Unknown POST failure"
        }
    }
}
