import Foundation
import HealthKit
import BackgroundTasks
import UIKit

// MARK: - BulkExportManager

/// Manages the one-time historical backfill of all HealthKit data.
/// On first launch after auth, queries historical HKSamples back to the sweep floor
/// (`sweepFloor`: one year for a new install, 2013 when `ImportHorizon.everything` is
/// chosen) and POSTs them in batches of 500, tracking progress in UserDefaults.
final class BulkExportManager {

    @MainActor static let shared = BulkExportManager()

    private let hkManager = HealthKitManager.shared
    private let syncEngine: SyncEngine

    /// Must match an entry in Info.plist `BGTaskSchedulerPermittedIdentifiers`.
    static let backfillTaskIdentifier = "com.health4ai.backfill"

    // Tracks which types have been fully backfilled
    private static let completedTypesKey = "hkb.backfill.completedTypes"
    private static let backfillInProgressKey = "hkb.backfill.inProgress"
    // Per-type chunk checkpoint: saves the last completed chunkEnd so restarts resume mid-type
    private static let chunkCheckpointPrefix = "hkb.backfill.chunk."
    // Per-type END of the window, set only when a type is armed to import the older history
    // (2013 up to the floor a bounded sweep used). Absent means the window runs to now.
    private static let chunkUntilPrefix = "hkb.backfill.until."
    // The floor the bounded (`lastYear`) sweep actually used, fixed at the first bounded run
    // so a resume days later and a later "import the rest" share one boundary. Absent while
    // no bounded sweep has started, and removed once the older window has been armed.
    private static let horizonFloorKey = "hkb.backfill.horizonFloor"
    // Types that finished a full floor→now sweep having returned zero samples
    private static let emptyHighVolumeTypesKey = "hkb.backfill.emptyHighVolumeTypes"
    // Types whose most recent sweep threw, kept until that type completes
    private static let failedImportTypesKey = "hkb.backfill.failedTypes"

    /// Types that any iPhone-carrying user necessarily has years of data for.
    ///
    /// HealthKit deliberately does not expose read authorization (see
    /// `HealthKitManager.needsAuthorizationRequest`): a denied read type returns an
    /// EMPTY sample array, indistinguishable from a window with genuinely no data.
    /// So a completed all-time sweep of one of these that yields zero samples is not
    /// "no data" — it is a revoked or never-granted per-type toggle in the Health app,
    /// and it is the only signal the app can ever get about that state.
    /// Restricted to types where zero is impossible, so an ordinary user who simply
    /// does not record swimming or handwashing is never warned.
    static let alwaysExpectedIdentifiers: Set<String> = [
        HKQuantityTypeIdentifier.stepCount.rawValue,
        HKQuantityTypeIdentifier.heartRate.rawValue,
        HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
        HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
    ]

    /// Health-app-facing name for an always-expected identifier, so the warning names
    /// the toggle the user has to find rather than an HK type string.
    static func displayName(for identifier: String) -> String {
        switch identifier {
        case HKQuantityTypeIdentifier.stepCount.rawValue:               return "Steps"
        case HKQuantityTypeIdentifier.heartRate.rawValue:               return "Heart Rate"
        case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:  return "Walking + Running Distance"
        case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:      return "Active Energy"
        default:                                                        return readableName(for: identifier)
        }
    }

    /// "HKQuantityTypeIdentifierFlightsClimbed" → "Flights Climbed", "…VO2Max" → "VO2 Max".
    /// Any of the ~120 types can fail an import, and a warning that shows an HK type string
    /// names nothing the user recognises. An uppercase run stays together ("SDNN").
    static func readableName(for identifier: String) -> String {
        if identifier == "HKWorkoutTypeIdentifier" { return "Workouts" }
        let prefixes = ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier",
                        "HKCorrelationTypeIdentifier", "HKDataTypeIdentifier"]
        var name = Substring(identifier)
        if let prefix = prefixes.first(where: { name.hasPrefix($0) }) {
            name = name.dropFirst(prefix.count)
        }
        let chars = Array(name)
        var words = ""
        for (i, ch) in chars.enumerated() {
            if i > 0, ch.isUppercase {
                let prev = chars[i - 1]
                let nextIsLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prev.isLowercase || prev.isNumber || (prev.isUppercase && nextIsLower) {
                    words.append(" ")
                }
            }
            words.append(ch)
        }
        return words.isEmpty ? identifier : words
    }

    /// Subset of `alwaysExpectedIdentifiers` whose last full sweep returned nothing.
    private(set) var emptyHighVolumeTypes: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: Self.emptyHighVolumeTypesKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.emptyHighVolumeTypesKey)
        }
    }

    /// Types whose most recent sweep threw, removed when the type later completes.
    ///
    /// Persisted, because the retry only happens on a later run. Until 2026-09-15 the failure
    /// lived only in `SyncState.backfillError`, which no screen read: the card fell back to the
    /// plain "Run Import" prompt, identical to an import that never ran. That is how Walking +
    /// Running Distance and Flights Climbed sat half re-sent on a real account with nothing on
    /// screen. Register D361.
    private(set) var failedImportTypes: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: Self.failedImportTypesKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.failedImportTypesKey)
        }
    }

    /// Double-counted activity types first, then by identifier.
    ///
    /// `sampleTypes()` is a Set, so the sweep order used to change every launch, and the one-time
    /// step, distance and energy re-send could wait hours behind a heart-rate import of millions
    /// of samples. A fixed order also makes a resumed run pick up where a user expects.
    static func importOrder(_ a: HKSampleType, _ b: HKSampleType) -> Bool {
        let aFirst = HealthKitManager.doubleCountedActivityIdentifiers.contains(a.identifier)
        let bFirst = HealthKitManager.doubleCountedActivityIdentifiers.contains(b.identifier)
        if aFirst != bFirst { return aFirst }
        return a.identifier < b.identifier
    }

    // UIKit background task token — keeps the app alive ~30s after going to background
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid

    private var completedTypes: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: Self.completedTypesKey) ?? []
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.completedTypesKey)
        }
    }

    private var currentTask: Task<Void, Never>? = nil

    @MainActor private init() {
        self.syncEngine = SyncEngine.shared
    }

    // MARK: - Should we run a backfill?

    var backfillNeeded: Bool {
        let completed = UserDefaults.standard.bool(forKey: "hkb.backfillCompleted")
        return !completed
    }

    /// True if any sweep has ever made progress on this install: the global latch, a
    /// finished type, or a mid-type checkpoint. `SyncState.init` reads this once, on the
    /// first launch that knows about `ImportHorizon`, to keep an install that already
    /// swept from 2013 on the 2013 floor. Static: it runs before the shared instance exists.
    static func hasImportHistory() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "hkb.backfillCompleted") { return true }
        if !(defaults.stringArray(forKey: completedTypesKey) ?? []).isEmpty { return true }
        return defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix(chunkCheckpointPrefix) }
    }

    // MARK: - Sweep floor

    /// The earliest date any sweep starts at, shared by this backfill and by live sync's
    /// anchored query predicate (`SyncEngine.queryAnchoredSamples`).
    ///
    /// `everything` is the 2013 floor and is never persisted. `lastYear` is fixed the first
    /// time either path asks and reused after that: types run sequentially over days and a
    /// per-call `now - 1 year` would give each type, and each path, its own floor, leaving
    /// the later "import everything" pass no single boundary to fill up to. Static so the
    /// sync engine can read it off the main actor; UserDefaults is thread-safe.
    static func sweepFloor(for horizon: ImportHorizon, now: Date = Date()) -> Date {
        switch horizon {
        case .everything:
            return ImportHorizon.historyFloor
        case .lastYear:
            // The read-check-write is locked: the launch sync and a just-armed backfill can
            // ask within the same second, and two floors a second apart would break the
            // "one boundary" promise the older-history pass relies on.
            Self.horizonFloorLock.lock()
            defer { Self.horizonFloorLock.unlock() }
            let defaults = UserDefaults.standard
            let stored = defaults.double(forKey: Self.horizonFloorKey)
            if stored > 0 { return Date(timeIntervalSince1970: stored) }
            let floor = horizon.floor(now: now)
            defaults.set(floor.timeIntervalSince1970, forKey: Self.horizonFloorKey)
            return floor
        }
    }

    private static let horizonFloorLock = NSLock()

    /// Arms every type to import the history a bounded sweep left out: 2013 up to the floor
    /// that sweep used, and nothing later. Called by the setting's `lastYear → everything`
    /// change, after `cancelAndWait()`.
    ///
    /// A finished type gets that one window, bounded by `chunkUntilPrefix`, so the year it
    /// already sent is not sent again. A type caught mid-sweep, with a checkpoint inside
    /// the last year, is reset to 2013→now instead: its two windows are not contiguous, and
    /// re-posting the part of the year it had reached is idempotent (the endpoint upserts)
    /// while adding a second window shape to the checkpoint machinery is not. A type that
    /// never started needs nothing; the new horizon already gives it the 2013 floor.
    ///
    /// No bounded sweep ever having run means there is no older window to fill, and
    /// nothing is changed. The stored floor is removed once used, so a later switch back
    /// and forth does not re-arm a window that has already been imported.
    @MainActor
    func importOlderHistory(syncState: SyncState) {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: Self.horizonFloorKey)
        guard stored > 0 else { return }
        let previousFloor = Date(timeIntervalSince1970: stored)
        var completed = completedTypes
        for sampleType in HealthKitManager.sampleTypes() {
            let identifier = sampleType.identifier
            let checkpointKey = Self.chunkCheckpointPrefix + identifier
            if completed.contains(identifier) {
                completed.remove(identifier)
                defaults.removeObject(forKey: checkpointKey)
                defaults.set(previousFloor.timeIntervalSince1970, forKey: Self.chunkUntilPrefix + identifier)
            } else if defaults.double(forKey: checkpointKey) > 0 {
                defaults.removeObject(forKey: checkpointKey)
                defaults.removeObject(forKey: Self.chunkUntilPrefix + identifier)
            }
        }
        completedTypes = completed
        defaults.removeObject(forKey: Self.horizonFloorKey)
        // Un-latch so backfillNeeded fires and startBackfill actually runs again.
        syncState.backfillCompleted = false
        print("[BulkExport] Armed older history up to \(previousFloor) for every type.")
    }

    // MARK: - Start backfill

    /// Begins (or resumes) the full historical backfill.
    /// Safe to call multiple times — skips already-completed types.
    func startBackfill(syncState: SyncState) {
        guard currentTask == nil else { return } // Already running

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await MainActor.run {
                syncState.isBackfilling = true
                syncState.backfillError = nil
                // Start the stall clock HERE, not at the first batch. Seeded from the
                // first batch, a run that wedges before ever posting — auth hang, wedged
                // first query, no network — leaves it nil, and isImportStalled returns
                // false forever. The detector would miss the total failure it exists for.
                syncState.backfillLastBatchAt = Date()
            }
            await self.runBackfill(syncState: syncState)
            self.currentTask = nil
        }
    }

    func cancelBackfill() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Cancel and WAIT for the run to actually stop before returning.
    ///
    /// cancelBackfill() only *requests* cancellation and clears currentTask synchronously,
    /// so an immediate startBackfill() passes its `currentTask == nil` guard and a SECOND
    /// runBackfill begins while the first is still unwinding — both then read-modify-write
    /// completedTypes, emptyHighVolumeTypes and failedImportTypes from different executors, and both report
    /// progress from their own local counters, which can make the on-screen count jump
    /// backwards. Any restart path must await this, not cancelBackfill().
    func cancelAndWait() async {
        let running = currentTask
        running?.cancel()
        currentTask = nil
        await running?.value
    }

    // MARK: - Backfill execution

    private func runBackfill(syncState: SyncState) async {
        let allTypes = HealthKitManager.sampleTypes()
        let remainingTypes = allTypes
            .filter { !completedTypes.contains($0.identifier) }
            .sorted(by: Self.importOrder)

        // posted = samples handed to the server; stored = rows the server says it wrote.
        // They diverge sharply on a re-sweep, because the endpoint upserts and most of a
        // repeated range already exists. Only `stored` is evidence anything was added.
        var totalPosted = 0
        var totalStored = 0
        var storedCountUnreliable = false
        let totalTypes = remainingTypes.count
        var typesCompleted = 0

        let (serverURL, horizon) = await MainActor.run {
            (syncState.resolvedEndpointURL, syncState.importHorizon)
        }
        // One floor for the whole run. Read once, so a setting change mid-run cannot give
        // two types two floors; the change path cancels this run and starts a new one.
        let floor = Self.sweepFloor(for: horizon)

        for sampleType in remainingTypes {
            if Task.isCancelled { break }

            // A window bounded at the previous floor is the older history only. Zero
            // samples there says nothing about a permission: a Watch bought last spring has
            // no heart rate in 2019. Only a window that reaches now can prove a denial.
            let sweepsToNow = UserDefaults.standard
                .double(forKey: Self.chunkUntilPrefix + sampleType.identifier) <= 0

            do {
                let count = try await backfillType(
                    sampleType: sampleType,
                    serverURL: serverURL,
                    floor: floor,
                    onBatch: { batchPosted, batchStored, earliestDate, latestDate in
                        totalPosted += batchPosted
                        if let s = batchStored {
                            totalStored += s
                        } else if batchPosted > 0 {
                            // A batch that posted rows but reported no count makes the
                            // running total an undercount we can never reconcile. Latch
                            // the whole run to "unknown" rather than let a stale figure
                            // keep looking authoritative while it silently stops tracking.
                            storedCountUnreliable = true
                        }
                        Task { @MainActor in
                            syncState.recordBackfillProgress(
                                posted: totalPosted,
                                stored: storedCountUnreliable ? nil : totalStored,
                                total: max(totalPosted, syncState.backfillTotalRecords),
                                earliest: earliestDate,
                                latest: latestDate
                            )
                        }
                    }
                )

                // Mark this type as done
                var completed = completedTypes
                completed.insert(sampleType.identifier)
                completedTypes = completed
                typesCompleted += 1
                var failed = failedImportTypes
                failed.remove(sampleType.identifier)
                failedImportTypes = failed

                // A full sweep of a type that cannot legitimately be empty, returning
                // nothing, is the app's only observable symptom of a denied read
                // permission. Record it rather than latching a silent "complete". A year
                // of steps is as impossible to have none of as thirteen years, so the
                // bounded horizon keeps this working; the older-window pass is skipped.
                if sweepsToNow && Self.alwaysExpectedIdentifiers.contains(sampleType.identifier) {
                    var empties = emptyHighVolumeTypes
                    if count == 0 {
                        empties.insert(sampleType.identifier)
                    } else {
                        empties.remove(sampleType.identifier)
                    }
                    emptyHighVolumeTypes = empties
                }

                print("[BulkExport] \(sampleType.identifier): \(count) records (\(typesCompleted)/\(totalTypes) types)")

            } catch is CancellationError {
                break
            } catch {
                // Log per-type errors and continue with other types, but do NOT mark this
                // type's checkpoint/completion — leaving it out of `completedTypes` means
                // the next startBackfill() call retries it from the same checkpoint instead
                // of silently treating a real failure as "nothing more to sync."
                // A cancel does not always arrive as CancellationError: one that lands during
                // postSamples' final attempt surfaces as URLError(.cancelled), with no retry sleep
                // left to convert it. Recording that as a failure would warn about a user's Cancel.
                if Task.isCancelled { break }
                print("[BulkExport] Error on \(sampleType.identifier): \(error)")
                var failed = failedImportTypes
                failed.insert(sampleType.identifier)
                failedImportTypes = failed
                await MainActor.run {
                    syncState.backfillError = "\(sampleType.identifier): \(error.localizedDescription)"
                }
            }
        }

        let emptyNames = emptyHighVolumeTypes.map(Self.displayName(for:)).sorted()
        let failedNames = failedImportTypes.map(Self.displayName(for:)).sorted()
        await MainActor.run {
            syncState.emptyExpectedMetricNames = emptyNames
            syncState.importFailedMetricNames = failedNames
        }

        if !Task.isCancelled {
            if typesCompleted == totalTypes {
                // Every outstanding type actually succeeded this run — safe to latch
                // the global "done" flag so future launches skip backfill entirely.
                await MainActor.run {
                    syncState.recordBackfillComplete()
                }
                print("[BulkExport] Backfill complete. Posted \(totalPosted), server stored \(totalStored).")
            } else {
                // At least one type errored. Do NOT set the global backfillCompleted latch —
                // that flag gates whether startBackfill() ever runs again (see backfillNeeded),
                // so latching it here on a partial run would permanently strand the failed
                // types with zero data and no future retry.
                await MainActor.run {
                    syncState.isBackfilling = false
                }
                print("[BulkExport] Backfill incomplete: \(typesCompleted)/\(totalTypes) types succeeded — will retry remaining types next launch.")
            }
        } else {
            await MainActor.run {
                syncState.isBackfilling = false
            }
        }
    }

    // MARK: - Per-type backfill

    /// Queries historical samples for a type in 90-day chunks to keep memory bounded.
    /// Loading all records at once (400K+ for steps/HR) causes iOS OOM kills.
    /// Each chunk is queried, converted, posted, and released before the next chunk loads.
    ///
    /// The window is `[floor, until)`: `floor` is the run's sweep floor, `until` is now
    /// unless the type is armed for the older history, in which case it is the floor the
    /// earlier bounded sweep used (see `importOlderHistory`).
    private func backfillType(
        sampleType: HKSampleType,
        serverURL: String,
        floor: Date,
        onBatch: @escaping (_ posted: Int, _ stored: Int?, _ earliest: Date?, _ latest: Date?) -> Void
    ) async throws -> Int {
        let token: String
        do {
            token = try await SyncEngine.sharedAuthManager.validToken(serverURL: serverURL)
        } catch {
            throw SyncError.authFailed(error.localizedDescription)
        }

        let calendar = Calendar.current
        let now = Date()
        let chunkDays = 90
        var totalCount = 0

        let untilKey = Self.chunkUntilPrefix + sampleType.identifier
        let untilTS = UserDefaults.standard.double(forKey: untilKey)
        let until = untilTS > 0 ? min(Date(timeIntervalSince1970: untilTS), now) : now

        // Resume from last saved checkpoint if the app was killed mid-type. Never below the
        // floor: a checkpoint left by a 2013 sweep before the horizon was narrowed to a
        // year would otherwise carry on importing the history the user just declined.
        let checkpointKey = Self.chunkCheckpointPrefix + sampleType.identifier
        let checkpointTS = UserDefaults.standard.double(forKey: checkpointKey)
        var chunkStart = checkpointTS > 0 ? max(Date(timeIntervalSince1970: checkpointTS), floor) : floor

        while chunkStart < until {
            // THROW, never break. Breaking falls through to the checkpoint-clear and
            // returns normally, and runBackfill reads a normal return as "this type
            // finished" — so a cancelled type was marked fully imported AND lost its
            // resume point. checkCancellation() raises CancellationError, which
            // runBackfill already handles by leaving the type un-completed.
            try Task.checkCancellation()

            let chunkEnd = min(calendar.date(byAdding: .day, value: chunkDays, to: chunkStart)!, until)

            let samples: [HKSample]
            do {
                samples = try await hkManager.querySamples(
                    type: sampleType,
                    startDate: chunkStart,
                    endDate: chunkEnd,
                    limit: HKObjectQueryNoLimit
                )
            } catch {
                // HKSampleQuery returns an empty array (not a thrown error) when a window
                // genuinely has no data. Any thrown error here is real — auth not determined,
                // database inaccessible, invalid argument — and must propagate so the caller
                // does NOT mark this type checkpointed/complete past an unprocessed window.
                throw error
            }

            if !samples.isEmpty {
                // Same rule as live sync: double-counted activity types post HealthKit's merged
                // hourly totals, only to a server that replaces per-device rows with them.
                // See HealthKitManager.syncsAsHourlyTotals and MergedHoursCapability.
                var usesMergedHours = false
                if HealthKitManager.syncsAsHourlyTotals(sampleType) {
                    usesMergedHours = try await syncEngine.mergedHoursAllowed(serverURL: serverURL, token: token)
                }
                let healthSamples: [HealthSample]
                if usesMergedHours, let quantityType = sampleType as? HKQuantityType {
                    healthSamples = try await hkManager.hourlyTotals(
                        for: quantityType, touchedBy: samples, notBefore: floor)
                } else {
                    healthSamples = samples.compactMap { hkManager.convert(sample: $0) }
                }

                if !healthSamples.isEmpty {
                    let batchSize = SyncEngine.batchSize
                    let batches = stride(from: 0, to: healthSamples.count, by: batchSize).map {
                        Array(healthSamples[$0..<min($0 + batchSize, healthSamples.count)])
                    }

                    for batch in batches {
                        // Cancellation mid-chunk means the REMAINING batches were never
                        // posted. Advancing the checkpoint past this window would mark
                        // those samples done forever — silent, permanent data loss on the
                        // exact interrupt-and-resume path the stall recovery tells a user
                        // to take. Leave the checkpoint where it is and let the resume
                        // re-query this window; re-posting is idempotent (the endpoint
                        // upserts), so a partial repeat is free and a skip is not.
                        try Task.checkCancellation()
                        let stored = try await syncEngine.postSamples(
                            batch, token: token, serverURL: serverURL)
                        // Dates come from the batch, not from nil. Passing nil here meant
                        // backfillEarliestDate was never set by anything, which left the
                        // "back to <date>" progress line permanently unrendered.
                        let starts = batch.map(\.startedAt)
                        onBatch(batch.count, stored, starts.min(), starts.max())
                        totalCount += batch.count
                    }
                }
            } else {
                // An empty window is still work. Without this the stall detector, which
                // reads only the last batch time, fires on a healthy import sweeping a
                // type the user has never recorded: ~53 chunks back to 2013, none of
                // which post anything.
                onBatch(0, nil, nil, nil)
            }

            chunkStart = chunkEnd
            // Save checkpoint after each chunk so kills resume here, not from the floor.
            // Reached only when every batch in the chunk posted — see the early return.
            UserDefaults.standard.set(chunkEnd.timeIntervalSince1970, forKey: checkpointKey)
        }

        // Clear checkpoint and window end once type is fully complete
        UserDefaults.standard.removeObject(forKey: checkpointKey)
        UserDefaults.standard.removeObject(forKey: untilKey)
        return totalCount
    }

    // MARK: - Background task support

    /// Register the BGProcessingTask handler. Call at app launch before didFinishLaunching
    /// returns. Restored 2026-09-14 with the rest of the BGTask infrastructure (D335).
    func registerBackgroundBackfillTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backfillTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self = self, let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundBackfillTask(processingTask)
        }
    }

    /// Schedule the next background backfill run. Call when entering background.
    /// requiresExternalPower = true so iOS only runs it while the phone is charging.
    func scheduleBackgroundBackfill() {
        guard backfillNeeded else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backfillTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Nothing on screen depends on this request: the import card already shows
            // whether the history import is complete, and the next foreground launch
            // resumes it from its checkpoints regardless.
            print("[BulkExport] Failed to schedule background backfill: \(error)")
        }
    }

    /// Resumes the checkpointed import under the task's expiration. Goes through
    /// `startBackfill` so it shares the single-run guard with the foreground callers.
    private func handleBackgroundBackfillTask(_ task: BGProcessingTask) {
        let completion = BGTaskCompletion(task)
        // Installed before any work starts, as BackgroundTasks requires. cancelBackfill
        // leaves every per-type checkpoint in place, so the next run resumes, not restarts.
        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.cancelBackfill() }
            completion.finish(success: false)
        }
        Task { @MainActor [weak self] in
            guard let self = self else {
                completion.finish(success: false)
                return
            }
            self.scheduleBackgroundBackfill() // Reschedule immediately for the next opportunity
            let syncState = SyncEngine.sharedSyncState
            guard self.backfillNeeded, self.currentTask == nil else {
                // Nothing left to import, or a run is already in flight. No work was owed.
                completion.finish(success: true)
                return
            }
            self.startBackfill(syncState: syncState)
            await self.currentTask?.value
            completion.finish(success: syncState.backfillError == nil)
        }
    }

    /// Request ~30 seconds of background execution time when the app transitions to background.
    /// This lets the current 90-day chunk finish rather than being cut off mid-upload.
    func requestBackgroundTime() {
        guard bgTaskID == .invalid else { return }
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "HK Backfill Chunk") { [weak self] in
            self?.endBackgroundTime()
        }
    }

    func endBackgroundTime() {
        guard bgTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskID)
        bgTaskID = .invalid
    }

    // MARK: - One-time repair for the pre-fix silent-skip bug

    private static let stuckTypeMigrationKey = "hkb.migration.stuckHighVolumeTypesFix.v1"

    /// Before this fix, `backfillType` treated ANY thrown error (not just genuine
    /// no-data windows) as "nothing to sync," raced through all chunks back to 2013,
    /// and let `runBackfill` mark the type `completedTypes` with zero rows synced —
    /// permanently, since `backfillNeeded` never re-fires once the global latch is set.
    /// StepCount, HeartRate, DistanceWalkingRunning, and ActiveEnergyBurned were
    /// confirmed stuck this way (0 rows, all-time, in the Supabase healthkit_metrics
    /// table) while every lower-volume type synced normally.
    /// Runs once per install: clears their false "completed" state + checkpoints so
    /// the next startBackfill() actually retries them, and un-latches the global
    /// completed flag if it had been wrongly set true on their account.
    func applyStuckTypeMigrationIfNeeded(syncState: SyncState) async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.stuckTypeMigrationKey) else { return }
        defaults.set(true, forKey: Self.stuckTypeMigrationKey)

        let knownStuckIdentifiers: Set<String> = [
            HKQuantityTypeIdentifier.stepCount.rawValue,
            HKQuantityTypeIdentifier.heartRate.rawValue,
            HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
            HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
        ]

        var completed = completedTypes
        let hadStuckType = !completed.intersection(knownStuckIdentifiers).isEmpty
        completed.subtract(knownStuckIdentifiers)
        completedTypes = completed

        for identifier in knownStuckIdentifiers {
            defaults.removeObject(forKey: Self.chunkCheckpointPrefix + identifier)
        }

        if hadStuckType {
            // These types never actually synced, so the prior "all done" latch was
            // wrong — clear it so startBackfill() runs again for the reset types.
            await MainActor.run { syncState.backfillCompleted = false }
            print("[BulkExport] Migration: reset stuck high-volume types for retry.")
        }
    }

    // MARK: - One-time re-send of double-counted activity history as merged hours

    private static let mergedHoursResendKeyPrefix = "hkb.migration.mergedHoursResend.v1."

    /// History for the double-counted activity types was imported as per-device samples, which
    /// every reader sums (+67% steps across 2021 on real data). Once the server confirms it
    /// replaces per-device rows with merged hours, those types are re-armed so the next import
    /// re-sends their history as merged hours, and the server removes the per-device rows hour by
    /// hour as each one arrives.
    ///
    /// Never before the server confirms: re-sending to an older function would ADD merged hours
    /// on top of the per-device rows. Once per endpoint, because a different endpoint is a
    /// different database. A failed check leaves the flag unset and is retried next launch; it is
    /// never read as "not supported". Register D361.
    func applyMergedHoursResendIfNeeded(syncState: SyncState) async {
        let serverURL = await MainActor.run { syncState.resolvedEndpointURL }
        let key = Self.mergedHoursResendKeyPrefix + serverURL
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            let token = try await SyncEngine.sharedAuthManager.validToken(serverURL: serverURL)
            guard try await syncEngine.mergedHoursAllowed(serverURL: serverURL, token: token) else { return }
        } catch {
            print("[BulkExport] Merged-hours check failed, retrying next launch: \(error)")
            return
        }
        // Check and reset in ONE main-actor step, and only with no import in flight. An import
        // snapshots completedTypes when it starts and writes it back as each type finishes, and
        // ends by latching backfillCompleted: running beside this reset it could re-mark the
        // re-armed types done, and the one-time flag below would then never let this run again.
        // Every startBackfill() call is on the main actor, so no import can start in between.
        let armed = await MainActor.run { () -> Bool in
            guard currentTask == nil, !syncState.isBackfilling else { return false }
            resetTypes(HealthKitManager.doubleCountedActivityIdentifiers, syncState: syncState)
            return true
        }
        guard armed else {
            print("[BulkExport] Import in flight; merged-hours re-send deferred to next launch.")
            return
        }
        UserDefaults.standard.set(true, forKey: key)
        print("[BulkExport] Re-armed \(HealthKitManager.doubleCountedActivityIdentifiers.count) activity types to re-send history as merged hours.")
    }

    /// Republishes the stored empty-type warning at launch, so the state survives a
    /// restart instead of only appearing in the run that first detected it.
    func publishEmptyExpectedTypes(syncState: SyncState) async {
        let names = emptyHighVolumeTypes.map(Self.displayName(for:)).sorted()
        await MainActor.run { syncState.emptyExpectedMetricNames = names }
    }

    /// Republishes the stored failed-import warning at launch, for the same reason.
    func publishFailedImportTypes(syncState: SyncState) async {
        let names = failedImportTypes.map(Self.displayName(for:)).sorted()
        await MainActor.run { syncState.importFailedMetricNames = names }
    }

    /// Re-arm ONLY these types, leaving every other type's progress intact.
    ///
    /// The full resetBackfill() is almost never what a user wants after fixing a
    /// permission: the four affected types need re-fetching, the other ~120 do not, and
    /// a blanket reset re-sends the entire history from 2013 — millions of samples the
    /// server already holds and will simply upsert over. Measured on a real account: a
    /// blanket reset spent hours re-posting ~4M rows without adding one.
    @MainActor
    func resetTypes(_ identifiers: Set<String>, syncState: SyncState) {
        guard !identifiers.isEmpty else { return }
        var completed = completedTypes
        completed.subtract(identifiers)
        completedTypes = completed
        let defaults = UserDefaults.standard
        for identifier in identifiers {
            defaults.removeObject(forKey: Self.chunkCheckpointPrefix + identifier)
            // A retry sweeps the type's whole current window, floor to now; an older-history
            // bound left behind would stop it a year short.
            defaults.removeObject(forKey: Self.chunkUntilPrefix + identifier)
        }
        // A re-armed type starts clean; if it fails again the run records it again.
        var failed = failedImportTypes
        failed.subtract(identifiers)
        failedImportTypes = failed
        syncState.importFailedMetricNames = failed.map(Self.displayName(for:)).sorted()
        var empties = emptyHighVolumeTypes
        empties.subtract(identifiers)
        emptyHighVolumeTypes = empties
        // Un-latch so backfillNeeded fires and startBackfill actually runs again.
        syncState.backfillCompleted = false
    }

    // MARK: - Reset backfill state (for re-running)

    func resetBackfill() {
        completedTypes = []
        UserDefaults.standard.removeObject(forKey: "hkb.backfillCompleted")
        UserDefaults.standard.removeObject(forKey: "hkb.backfillProgress")
        UserDefaults.standard.removeObject(forKey: Self.backfillInProgressKey)
        // Clears the stored list only; the published names are the caller's. Both callers are safe
        // today: ConnectionView erases SyncState right after, and Re-run Import only offers this
        // once backfillCompleted, which runBackfill latches only with the failed list empty.
        UserDefaults.standard.removeObject(forKey: Self.failedImportTypesKey)
        // Clear all per-type chunk checkpoints and window ends, and the persisted floor so
        // the fresh run computes one for whatever the horizon is now.
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.chunkCheckpointPrefix) || $0.hasPrefix(Self.chunkUntilPrefix) }
            .forEach { defaults.removeObject(forKey: $0) }
        defaults.removeObject(forKey: Self.horizonFloorKey)
        cancelBackfill()
    }
}
