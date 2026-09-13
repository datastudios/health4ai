import Foundation
import Combine

// MARK: - Connection configuration

enum ConnectionType: String, CaseIterable {
    case supabase = "supabase"
    case rest     = "rest"     // any REST endpoint

    var displayName: String {
        switch self {
        case .supabase: return "Supabase"
        case .rest:     return "REST / Webhook"
        }
    }
}

enum RestAuthType: String, CaseIterable {
    case none    = "none"
    case bearer  = "bearer"
    case apiKey  = "apiKey"

    var displayName: String {
        switch self {
        case .none:   return "No Auth"
        case .bearer: return "Bearer Token"
        case .apiKey: return "API Key Header"
        }
    }
}

// MARK: - Connection health

/// Combined state of "signed in to your backend" and "health records are actually arriving".
enum ConnectionHealth {
    /// Signed in and health data is landing.
    case connected
    /// Signed in, but nothing has synced inside the freshness window.
    case stalled
    /// No backend account is connected.
    case disconnected

    var title: String {
        switch self {
        case .connected:    return "Active"
        case .stalled:      return "No recent data"
        case .disconnected: return "Not connected"
        }
    }

    var systemImage: String {
        switch self {
        case .connected:    return "checkmark.circle.fill"
        case .stalled:      return "exclamationmark.circle.fill"
        case .disconnected: return "circle.slash"
        }
    }
}

// MARK: - SyncState

/// Central ObservableObject driving all SwiftUI state.
@MainActor
final class SyncState: ObservableObject {

    // MARK: - Sync status

    @Published var lastSyncDate: Date? {
        didSet { UserDefaults.standard.set(lastSyncDate, forKey: Keys.lastSyncDate) }
    }

    @Published var lastSyncRecordCount: Int = 0 {
        didSet { UserDefaults.standard.set(lastSyncRecordCount, forKey: Keys.lastSyncRecordCount) }
    }

    @Published var nextScheduledSync: Date? = nil
    @Published var isSyncing: Bool = false
    @Published var syncError: String? = nil

    // MARK: - Backfill status

    @Published var isBackfilling: Bool = false
    @Published var backfillTotalRecords: Int = 0
    @Published var backfillSyncedRecords: Int = 0
    @Published var backfillCompleted: Bool = false {
        didSet { UserDefaults.standard.set(backfillCompleted, forKey: Keys.backfillCompleted) }
    }
    @Published var backfillError: String? = nil
    @Published var backfillEarliestDate: Date? = nil
    @Published var backfillLatestDate: Date? = nil
    /// Rows the SERVER reported writing, or nil if it never said.
    ///
    /// Optional on purpose. health4ai is a bring-your-own-backend conduit, so an endpoint
    /// that predates `{"inserted": N}` is the architecture, not an edge case. A
    /// non-optional 0 here would render "0 new" as a definite claim against an endpoint
    /// that reported nothing — the reviewed bug with its sign flipped, over-claiming
    /// failure instead of success.
    @Published var backfillStoredRecords: Int? = nil
    /// Where the sweep is right now. NOT monotonic: types run sequentially and each
    /// restarts at the 2013 floor, so a running max would pin to the present after the
    /// first type finishes and stay there for the remaining ~119.
    @Published var backfillCurrentDate: Date? = nil
    /// When the last batch completed. A backfill that stops posting shows a live
    /// progress card and a frozen number forever, which is indistinguishable from work.
    @Published var backfillLastBatchAt: Date? = nil
    /// Human-readable names of always-expected metrics whose last full sweep returned
    /// nothing — the only detectable symptom of a denied per-type Health permission.
    /// See `BulkExportManager.alwaysExpectedIdentifiers`.
    @Published var emptyExpectedMetricNames: [String] = []

    /// The server answered without `merged_hours_v1`, so step, distance and energy totals are
    /// still sent per device and summed twice wherever an iPhone and a Watch both counted.
    /// Register D361.
    @Published var serverLacksMergedHours = false

    // MARK: - Connection configuration

    @Published var connectionType: ConnectionType {
        didSet { UserDefaults.standard.set(connectionType.rawValue, forKey: Keys.connectionType) }
    }

    /// Supabase: base project URL, e.g. https://abc123.supabase.co
    @Published var supabaseProjectURL: String {
        didSet {
            UserDefaults.standard.set(supabaseProjectURL, forKey: Keys.supabaseProjectURL)
            // A verdict about the previous server says nothing about this one; the next sync asks.
            if supabaseProjectURL != oldValue { serverLacksMergedHours = false }
        }
    }

    /// Generic REST: full endpoint URL
    @Published var serverURL: String {
        didSet {
            UserDefaults.standard.set(serverURL, forKey: Keys.serverURL)
            if serverURL != oldValue { serverLacksMergedHours = false }
        }
    }

    @Published var restAuthType: RestAuthType {
        didSet { UserDefaults.standard.set(restAuthType.rawValue, forKey: Keys.restAuthType) }
    }

    @Published var restApiKeyHeader: String {
        didSet { UserDefaults.standard.set(restApiKeyHeader, forKey: Keys.restApiKeyHeader) }
    }

    // MARK: - Auth

    @Published var isAuthenticated: Bool = false
    @Published var userEmail: String? = nil

    // MARK: - Computed endpoint

    var resolvedEndpointURL: String {
        switch connectionType {
        case .supabase:
            let base = supabaseProjectURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return base.isEmpty ? serverURL : "\(base)/functions/v1/healthkit-ingest"
        case .rest:
            return serverURL
        }
    }

    // MARK: - Lifetime record count

    @Published var lifetimeSyncedRecords: Int = 0 {
        didSet { UserDefaults.standard.set(lifetimeSyncedRecords, forKey: Keys.lifetimeSyncedRecords) }
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        let typeRaw = defaults.string(forKey: Keys.connectionType) ?? ConnectionType.supabase.rawValue
        // `.rest` is not selectable in 1.0 (see ConnectionView "Backend type"). Anyone
        // holding a stored `rest` selection is coerced to Supabase rather than left on a
        // path that has never synced a row and offers no way back to the picker.
        let storedType = ConnectionType(rawValue: typeRaw) ?? .supabase
        self.connectionType = storedType == .rest ? .supabase : storedType
        // Write the coercion through. `didSet` does not fire during init, so without this
        // UserDefaults keeps "rest" forever and the persisted state contradicts the live
        // one — harmless, since every launch re-coerces, but it is a lie on disk.
        if storedType == .rest {
            defaults.set(ConnectionType.supabase.rawValue, forKey: Keys.connectionType)
        }
        let savedProjectURL = defaults.string(forKey: Keys.supabaseProjectURL) ?? ""
        self.supabaseProjectURL = savedProjectURL

        // Migration guard: if the persisted type is unknown (e.g. an old value no longer
        // in the enum) and no project URL was configured, reset so the app shows setup flow.
        if ConnectionType(rawValue: typeRaw) == nil && savedProjectURL.isEmpty {
            defaults.removeObject(forKey: Keys.connectionType)
        }

        self.serverURL = defaults.string(forKey: Keys.serverURL) ?? ""
        let authRaw = defaults.string(forKey: Keys.restAuthType) ?? RestAuthType.bearer.rawValue
        self.restAuthType = RestAuthType(rawValue: authRaw) ?? .bearer
        self.restApiKeyHeader = defaults.string(forKey: Keys.restApiKeyHeader) ?? "X-API-Key"
        self.lastSyncDate = defaults.object(forKey: Keys.lastSyncDate) as? Date
        self.lastSyncRecordCount = defaults.integer(forKey: Keys.lastSyncRecordCount)
        self.backfillCompleted = defaults.bool(forKey: Keys.backfillCompleted)
        self.lifetimeSyncedRecords = defaults.integer(forKey: Keys.lifetimeSyncedRecords)
        self.backfillSyncedRecords = defaults.integer(forKey: Keys.backfillProgress)

        #if DEBUG
        // Screenshot state for the design gate: signed in, data flowing, server without merged
        // hours. The real state needs a keychain session and an old server, which a simulator
        // does not have. DEBUG builds only, launch argument only, and nothing is persisted:
        // didSet does not fire during init. Xcode Cloud archives Release, which never compiles it.
        if ProcessInfo.processInfo.arguments.contains("-h4aiScreenshotServerUpdateNeeded") {
            self.isAuthenticated = true
            self.lifetimeSyncedRecords = max(self.lifetimeSyncedRecords, 1)
            self.lastSyncDate = Date()
            self.serverLacksMergedHours = true
        }
        #endif
    }

    // MARK: - Mutators (called from background threads via MainActor dispatch)

    func recordSyncComplete(count: Int) {
        lastSyncDate = Date()
        lastSyncRecordCount = count
        lifetimeSyncedRecords += count
        isSyncing = false
        syncError = nil
    }

    func recordSyncError(_ message: String) {
        isSyncing = false
        syncError = message
    }

    /// Some types synced, some did not.
    ///
    /// Needed because per-type error isolation created a path where every type could fail
    /// and the pass still reported success: `recordSyncComplete(count: 0)` stamps a fresh
    /// `lastSyncDate` and clears `syncError`, so a total failure rendered as "synced, 0
    /// records". That is the vacuous-success shape this app has already been bitten by
    /// once, when a denied HealthKit permission showed a green Complete tick for months.
    func recordSyncPartial(count: Int, failed: Int, ofTypes total: Int) {
        lastSyncDate = Date()
        lastSyncRecordCount = count
        lifetimeSyncedRecords += count
        isSyncing = false
        syncError = "\(failed) of \(total) data types failed to sync."
    }

    func recordBackfillProgress(posted: Int, stored: Int?, total: Int,
                                earliest: Date?, latest: Date?) {
        let delta = posted - backfillSyncedRecords
        backfillSyncedRecords = posted
        backfillTotalRecords = total
        // Assigned, not merged: nil means the run can no longer justify a stored figure,
        // and must clear the old one rather than leave a stale number looking current.
        backfillStoredRecords = stored
        // Earliest keeps the MINIMUM so "back to <date>" stays true as the sweep advances.
        // Current is assigned plainly — it is a position, not a high-water mark.
        if let e = earliest { backfillEarliestDate = min(e, backfillEarliestDate ?? e) }
        if let l = latest {
            backfillCurrentDate = l
            backfillLatestDate = max(l, backfillLatestDate ?? l)
        }
        // Any batch at all is proof of life. The stall check reads this and nothing else,
        // so it stays true even while a re-sweep is storing zero new rows.
        backfillLastBatchAt = Date()
        if delta > 0 { lifetimeSyncedRecords += delta }
        UserDefaults.standard.set(backfillSyncedRecords, forKey: Keys.backfillProgress)
    }

    func recordBackfillComplete() {
        isBackfilling = false
        backfillCompleted = true
        backfillError = nil
    }

    func recordBackfillError(_ message: String) {
        isBackfilling = false
        backfillError = message
    }

    /// Removes all locally retained account, endpoint, progress, and credential state.
    /// Use this before handing a device to another person or switching backends.
    func eraseLocalDataAndConfiguration() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("hkb.") {
            defaults.removeObject(forKey: key)
        }
        CredentialKeychain.deleteAll()
        connectionType = .supabase
        supabaseProjectURL = ""
        serverURL = ""
        restAuthType = .bearer
        restApiKeyHeader = "X-API-Key"
        lastSyncDate = nil
        lastSyncRecordCount = 0
        backfillCompleted = false
        backfillSyncedRecords = 0
        backfillTotalRecords = 0
        backfillEarliestDate = nil
        backfillLatestDate = nil
        backfillStoredRecords = nil
        backfillCurrentDate = nil
        backfillLastBatchAt = nil
        lifetimeSyncedRecords = 0
        isAuthenticated = false
        userEmail = nil
        serverLacksMergedHours = false
    }

    // MARK: - Computed helpers

    var backfillProgressFraction: Double {
        guard backfillTotalRecords > 0 else { return 0 }
        return Double(backfillSyncedRecords) / Double(backfillTotalRecords)
    }

    /// How recently health data must have landed for the connection to read as healthy.
    /// Background delivery is scheduled by iOS, so a gap of a few hours is normal;
    /// two days without a record means something is actually broken.
    nonisolated static let freshDataWindow: TimeInterval = 48 * 60 * 60

    /// Pure decision function — `now` is injected so the 48-hour boundary is testable
    /// without waiting on the clock.
    nonisolated static func connectionHealth(isAuthenticated: Bool,
                                             isSyncing: Bool,
                                             isBackfilling: Bool,
                                             lifetimeSyncedRecords: Int,
                                             lastSyncDate: Date?,
                                             now: Date = Date()) -> ConnectionHealth {
        guard isAuthenticated else { return .disconnected }
        if isBackfilling || isSyncing { return .connected }
        guard lifetimeSyncedRecords > 0, let last = lastSyncDate else { return .stalled }
        return now.timeIntervalSince(last) < freshDataWindow ? .connected : .stalled
    }

    /// True while health records are actually moving — not merely while an account is signed in.
    var isHealthDataFlowing: Bool {
        Self.connectionHealth(isAuthenticated: true,
                              isSyncing: isSyncing,
                              isBackfilling: isBackfilling,
                              lifetimeSyncedRecords: lifetimeSyncedRecords,
                              lastSyncDate: lastSyncDate) == .connected
    }

    /// Single signal combining backend auth and HealthKit delivery. Being signed in
    /// while no health data arrives is the failure mode users could not previously see.
    ///
    /// Known limit: HealthKit never reports read authorization, and
    /// `statusForAuthorizationRequest` returns `.unnecessary` after the first ask whether
    /// the user granted or later revoked access. So access revoked in Settings cannot be
    /// detected directly — it surfaces here only once delivery goes quiet past
    /// `freshDataWindow`, which is the strongest signal the platform allows.
    var connectionHealth: ConnectionHealth {
        Self.connectionHealth(isAuthenticated: isAuthenticated,
                              isSyncing: isSyncing,
                              isBackfilling: isBackfilling,
                              lifetimeSyncedRecords: lifetimeSyncedRecords,
                              lastSyncDate: lastSyncDate)
    }

    var formattedLastSync: String {
        guard let date = lastSyncDate else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var formattedNextSync: String {
        guard let date = nextScheduledSync else { return "Not scheduled" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - UserDefaults Keys

private enum Keys {
    static let connectionType       = "hkb.connectionType"
    static let supabaseProjectURL   = "hkb.supabaseProjectURL"
    static let serverURL            = "hkb.serverURL"
    static let restAuthType         = "hkb.restAuthType"
    static let restApiKeyHeader     = "hkb.restApiKeyHeader"
    static let lastSyncDate         = "hkb.lastSyncDate"
    static let lastSyncRecordCount  = "hkb.lastSyncRecordCount"
    static let backfillCompleted    = "hkb.backfillCompleted"
    static let backfillProgress     = "hkb.backfillProgress"
    static let lifetimeSyncedRecords = "hkb.lifetimeSyncedRecords"
}
