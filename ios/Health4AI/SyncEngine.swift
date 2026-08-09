import Foundation
import HealthKit
import UIKit

// MARK: - SyncEngine

/// Orchestrates all sync pathways:
/// - BGTaskScheduler (hourly background task)
/// - HKObserverQuery (push-triggered on new data for each type)
/// - Workout completion observer (immediate sync on workout end)
/// - Foreground launch sync (on every app open)
///
/// Also handles batched HTTP POST with retry logic.
final class SyncEngine {

    @MainActor static let shared = SyncEngine()

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

    // MARK: - BGTaskScheduler Registration (disabled on iOS 27 Beta)
    // BackgroundTasks.framework triggers _libxpc_initializer XPC crash on iOS 27 Beta.
    // Restore these when the beta is fixed. HKObserverQuery background delivery still works.

    // MARK: - HKObserverQuery registration

    /// Registers background delivery and observer queries for all HealthKit types.
    /// Call after authorization is granted.
    func startObserving() {
        let types = HealthKitManager.sampleTypes()

        for sampleType in types {
            // Enable background delivery (fires our app when new data is written)
            hkManager.store.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
                if let error = error {
                    print("[SyncEngine] Background delivery enable failed for \(sampleType.identifier): \(error)")
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
        Task {
            await MainActor.run { self.syncState.isSyncing = true }
            do {
                let count = try await performFullSync()
                await MainActor.run { self.syncState.recordSyncComplete(count: count) }
            } catch {
                await MainActor.run { self.syncState.recordSyncError(error.localizedDescription) }
            }
        }
    }

    // MARK: - Full sync (all types, anchored)

    @discardableResult
    func performFullSync() async throws -> Int {
        let types = HealthKitManager.sampleTypes()
        var totalCount = 0

        // Sync each type sequentially to keep memory usage bounded
        for sampleType in types {
            let count = try await syncType(sampleType)
            totalCount += count
        }
        return totalCount
    }

    // MARK: - Per-type anchored sync

    /// Queries new samples since the last anchor for `sampleType`, posts them,
    /// and saves the new anchor.
    func syncType(_ sampleType: HKSampleType) async throws -> Int {
        let serverURL = await MainActor.run { syncState.resolvedEndpointURL }
        let token: String
        do {
            token = try await authManager.validToken(serverURL: serverURL)
        } catch {
            throw SyncError.authFailed(error.localizedDescription)
        }

        let anchor = syncAnchors[sampleType.identifier]
        let (samples, newAnchor) = try await queryAnchoredSamples(type: sampleType, anchor: anchor)

        guard !samples.isEmpty else { return 0 }

        let healthSamples = samples.compactMap { hkManager.convert(sample: $0) }
        guard !healthSamples.isEmpty else {
            if let newAnchor = newAnchor {
                syncAnchors[sampleType.identifier] = newAnchor
                saveAnchors()
            }
            return 0
        }

        // Post in batches
        let batches = stride(from: 0, to: healthSamples.count, by: Self.batchSize).map {
            Array(healthSamples[$0..<min($0 + Self.batchSize, healthSamples.count)])
        }

        for batch in batches {
            try await postSamples(batch, token: token, serverURL: serverURL)
        }

        if let newAnchor = newAnchor {
            syncAnchors[sampleType.identifier] = newAnchor
            saveAnchors()
        }

        return healthSamples.count
    }

    // MARK: - Anchored HKSample query

    private func queryAnchoredSamples(
        type sampleType: HKSampleType,
        anchor: HKQueryAnchor?
    ) async throws -> ([HKSample], HKQueryAnchor?) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: nil,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
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
    func postSamples(
        _ samples: [HealthSample],
        token: String,
        serverURL: String
    ) async throws {
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
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SyncError.invalidResponse
                }

                switch httpResponse.statusCode {
                case 200...299:
                    return // success
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
    func resetAnchors() {
        syncAnchors.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.anchorsKey)
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
