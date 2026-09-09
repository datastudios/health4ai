import Foundation
import HealthKit
import UIKit

// MARK: - BulkExportManager

/// Manages the one-time historical backfill of all HealthKit data.
/// On first launch after auth, queries ALL historical HKSamples (no date limit)
/// and POSTs them in batches of 500, tracking progress in UserDefaults.
final class BulkExportManager {

    @MainActor static let shared = BulkExportManager()

    private let hkManager = HealthKitManager.shared
    private let syncEngine: SyncEngine

    // Tracks which types have been fully backfilled
    private static let completedTypesKey = "hkb.backfill.completedTypes"
    private static let backfillInProgressKey = "hkb.backfill.inProgress"
    // Per-type chunk checkpoint: saves the last completed chunkEnd so restarts resume mid-type
    private static let chunkCheckpointPrefix = "hkb.backfill.chunk."
    // Types that finished a full 2013→now sweep having returned zero samples
    private static let emptyHighVolumeTypesKey = "hkb.backfill.emptyHighVolumeTypes"

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
        default:                                                        return identifier
        }
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
            }
            await self.runBackfill(syncState: syncState)
            self.currentTask = nil
        }
    }

    func cancelBackfill() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - Backfill execution

    private func runBackfill(syncState: SyncState) async {
        let allTypes = HealthKitManager.sampleTypes()
        let remainingTypes = allTypes.filter { !completedTypes.contains($0.identifier) }

        // Estimate total by querying counts (fast path: just run the sync and count)
        var totalSynced = 0
        let totalTypes = remainingTypes.count
        var typesCompleted = 0

        let serverURL = await MainActor.run { syncState.resolvedEndpointURL }

        for sampleType in remainingTypes {
            if Task.isCancelled { break }

            do {
                let count = try await backfillType(
                    sampleType: sampleType,
                    serverURL: serverURL,
                    onBatch: { batchCount, earliestDate, latestDate in
                        totalSynced += batchCount
                        Task { @MainActor in
                            syncState.recordBackfillProgress(
                                synced: totalSynced,
                                total: max(totalSynced, syncState.backfillTotalRecords),
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

                // A full sweep of a type that cannot legitimately be empty, returning
                // nothing, is the app's only observable symptom of a denied read
                // permission. Record it rather than latching a silent "complete".
                if Self.alwaysExpectedIdentifiers.contains(sampleType.identifier) {
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
                print("[BulkExport] Error on \(sampleType.identifier): \(error)")
                await MainActor.run {
                    syncState.backfillError = "\(sampleType.identifier): \(error.localizedDescription)"
                }
            }
        }

        let emptyNames = emptyHighVolumeTypes.map(Self.displayName(for:)).sorted()
        await MainActor.run { syncState.emptyExpectedMetricNames = emptyNames }

        if !Task.isCancelled {
            if typesCompleted == totalTypes {
                // Every outstanding type actually succeeded this run — safe to latch
                // the global "done" flag so future launches skip backfill entirely.
                await MainActor.run {
                    syncState.recordBackfillComplete()
                }
                print("[BulkExport] Backfill complete. Total records: \(totalSynced)")
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
    private func backfillType(
        sampleType: HKSampleType,
        serverURL: String,
        onBatch: @escaping (_ count: Int, _ earliest: Date?, _ latest: Date?) -> Void
    ) async throws -> Int {
        let token: String
        do {
            token = try await SyncEngine.sharedAuthManager.validToken(serverURL: serverURL)
        } catch {
            throw SyncError.authFailed(error.localizedDescription)
        }

        let calendar = Calendar.current
        let floor = DateComponents(calendar: calendar, year: 2013, month: 1, day: 1).date!
        let now = Date()
        let chunkDays = 90
        var totalCount = 0

        // Resume from last saved checkpoint if the app was killed mid-type
        let checkpointKey = Self.chunkCheckpointPrefix + sampleType.identifier
        let checkpointTS = UserDefaults.standard.double(forKey: checkpointKey)
        var chunkStart = checkpointTS > 0 ? Date(timeIntervalSince1970: checkpointTS) : floor

        while chunkStart < now {
            if Task.isCancelled { break }

            let chunkEnd = min(calendar.date(byAdding: .day, value: chunkDays, to: chunkStart)!, now)

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
                let healthSamples = samples.compactMap { hkManager.convert(sample: $0) }

                if !healthSamples.isEmpty {
                    let batchSize = SyncEngine.batchSize
                    let batches = stride(from: 0, to: healthSamples.count, by: batchSize).map {
                        Array(healthSamples[$0..<min($0 + batchSize, healthSamples.count)])
                    }

                    for batch in batches {
                        if Task.isCancelled { break }
                        try await syncEngine.postSamples(batch, token: token, serverURL: serverURL)
                        onBatch(batch.count, nil, nil)
                        totalCount += batch.count
                    }
                }
            }

            chunkStart = chunkEnd
            // Save checkpoint after each chunk so kills resume here, not from 2013
            UserDefaults.standard.set(chunkEnd.timeIntervalSince1970, forKey: checkpointKey)
        }

        // Clear checkpoint once type is fully complete
        UserDefaults.standard.removeObject(forKey: checkpointKey)
        return totalCount
    }

    // MARK: - Background task support (disabled on iOS 27 Beta)
    // BackgroundTasks.framework triggers _libxpc_initializer XPC crash on iOS 27 Beta.
    // Restore registerBackgroundBackfillTask() + scheduleBackgroundBackfill() when fixed.

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

    /// Republishes the stored empty-type warning at launch, so the state survives a
    /// restart instead of only appearing in the run that first detected it.
    func publishEmptyExpectedTypes(syncState: SyncState) async {
        let names = emptyHighVolumeTypes.map(Self.displayName(for:)).sorted()
        await MainActor.run { syncState.emptyExpectedMetricNames = names }
    }

    // MARK: - Reset backfill state (for re-running)

    func resetBackfill() {
        completedTypes = []
        UserDefaults.standard.removeObject(forKey: "hkb.backfillCompleted")
        UserDefaults.standard.removeObject(forKey: "hkb.backfillProgress")
        UserDefaults.standard.removeObject(forKey: Self.backfillInProgressKey)
        // Clear all per-type chunk checkpoints
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.chunkCheckpointPrefix) }
            .forEach { defaults.removeObject(forKey: $0) }
        cancelBackfill()
    }
}
