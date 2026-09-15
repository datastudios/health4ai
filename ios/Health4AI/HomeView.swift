import SwiftUI
import UIKit

struct HomeView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject var syncState: SyncState
    @Environment(\.scenePhase) private var scenePhase
    @State private var showMCPSetup = false
    @State private var isRequestingHealth = false
    @State private var healthAccessError: String?
    @State private var healthScope = HealthKitManager.selectedScope
    /// True while iOS would still show the permission sheet for the selected scope.
    /// Drives whether the primary button prompts or routes to Settings.
    @State private var needsHealthPrompt = false
    /// Set while programmatically restoring the picker after a failed request, so the
    /// restore does not re-enter onChange and fire a second request.
    @State private var isRevertingScope = false
    /// Drives the stall check. A computed property alone never re-evaluates, so a wedged
    /// import would keep showing a live progress card forever.
    @State private var tick = Date()
    @State private var confirmStartOver = false

    static let stallMinutes = 5

    /// Two claims, trustworthy one first.
    ///
    /// "Added" is what the server's `inserted` actually means. "Checked" honestly covers
    /// both "stored it" and "already had it", so a healthy re-sweep reads as nothing new
    /// here yet rather than as nothing is working — leading with the number we just
    /// declared worthless would trade a false green for a false red.
    /// Two stacked Texts rather than one concatenated string: at accessibility sizes a
    /// single line broke mid-number and rendered a different, wrong figure.
    @ViewBuilder
    private var progressLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            // lineLimit + minimumScaleFactor on every numeric line: a seven-digit count
            // is the normal magnitude here (the incident was 255,000; a full sweep is
            // ~4M), and at accessibility sizes SwiftUI character-wraps a long numeric
            // token and renders "1,284,91 / 3" — a different, wrong number. Shrink
            // rather than fracture. Splitting into stacked Texts did not fix this.
            if let stored = syncState.backfillStoredRecords {
                Text("\(stored.formatted()) records added")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(checkedLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                // The endpoint did not report what it wrote. Say only what we know.
                Text("\(syncState.backfillSyncedRecords.formatted()) records checked")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let at = syncState.backfillCurrentDate {
                    Text("now on \(at.formatted(.dateTime.month().year()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityProgressLabel)
    }

    private var checkedLine: String {
        let checked = "\(syncState.backfillSyncedRecords.formatted()) checked"
        guard let at = syncState.backfillCurrentDate else { return checked }
        return checked + " · now on \(at.formatted(.dateTime.month().year()))"
    }

    private var importActionLabel: String {
        if syncState.backfillCompleted { return "Import Again from Scratch" }
        return syncState.backfillSyncedRecords > 0 ? "Resume Import" : "Run Import"
    }

    private var accessibilityProgressLabel: String {
        let checked = syncState.backfillSyncedRecords.formatted()
        guard let stored = syncState.backfillStoredRecords else {
            return "\(checked) records checked"
        }
        return "\(stored.formatted()) records added, \(checked) checked"
    }

    /// Backfilling, but nothing has posted for a while. Reads backfillLastBatchAt rather
    /// than the record count, because a re-sweep legitimately stores zero new rows while
    /// still doing work — counting rows would cry stall on a healthy import.
    private var isImportStalled: Bool {
        guard syncState.isBackfilling, let last = syncState.backfillLastBatchAt else { return false }
        return tick.timeIntervalSince(last) > Double(Self.stallMinutes) * 60
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 20) {
                        statusCard
                        scopeCard
                        mcpCard
                        healthAccessCard
                        backfillCard
                            .id(Self.backfillCardID)
                        actionsCard
                    }
                    .padding()
                }
                #if DEBUG
                // Design-gate screenshots only: the import card sits below the fold, and simctl
                // cannot scroll. Paired with the launch arguments in SyncState.init.
                .onAppear {
                    let args = ProcessInfo.processInfo.arguments
                    if args.contains("-h4aiScreenshotImportFailed") || args.contains("-h4aiScreenshotImportFailedMany") {
                        proxy.scrollTo(Self.backfillCardID, anchor: .top)
                    }
                }
                #endif
                .background(Color(.systemGroupedBackground))
                .navigationTitle("health4ai")
                .navigationBarTitleDisplayMode(.large)
                .sheet(isPresented: $showMCPSetup) {
                    MCPSetupView()
                        .environmentObject(syncState)
                }
                .task { await refreshHealthPromptState() }
                .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { tick = $0 }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back from Settings or the Health app can change access.
                    if phase == .active {
                        Task { await refreshHealthPromptState() }
                    }
                }
            }
        }
    }

    private static let backfillCardID = "backfillCard"

    // MARK: - Status card

    private var statusCard: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync Status")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    statusLabel
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Decorative at accessibility sizes: the status label already carries the state's
                // symbol. Kept, the .title icon claimed a column and broke the headline mid-word
                // ("Serve / r / up- / date") at accessibilityXXXL on a 375pt width, measured
                // 2026-09-13 (design.md: verify at .accessibilityXXXL).
                if !dynamicTypeSize.isAccessibilitySize {
                    syncIcon
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last sync")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(syncState.formattedLastSync)
                        .font(.subheadline.weight(.medium))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    // "Earliest": the date is the floor iOS was given, not a promise.
                    Text("Next sync, earliest")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(syncState.formattedNextSync)
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(statusColor.opacity(0.35), lineWidth: 1)
        )
    }

    /// Drives every colored element in the status card from one signal, so "connected"
    /// is legible at a glance instead of only being implied by the label text.
    private static let updateGuideURL = URL(string: "https://github.com/jefflitt1/health4ai/blob/main/docs/SETUP.md#updating-an-existing-project")!

    private var statusColor: Color {
        if syncState.isSyncing { return .blue }
        if syncState.syncError != nil { return .red }
        // Metrics known to be missing outrank a healthy connection: the transport can be
        // fine while the data is not arriving, and the headline must not read green while
        // the app already knows core metrics returned nothing.
        // Both warnings apply only over a healthy connection, which is also the only time the
        // label names them. Unconditional, a disconnected card got an orange icon and border
        // under a "Disconnected" title: two colour signals for one state.
        let connected = syncState.connectionHealth == .connected
        if connected && !syncState.emptyExpectedMetricNames.isEmpty { return .orange }
        // Same rank as missing metrics: the connection works, and the totals it delivers are
        // wrong. A green headline over double-counted steps is the state this exists to end.
        if connected && syncState.serverLacksMergedHours { return .orange }
        // Below the two data warnings: the data is right, it just only moves while the app
        // is open. Register D335.
        if connected && !syncState.backgroundDeliveryFailedTypes.isEmpty { return .orange }
        switch syncState.connectionHealth {
        case .connected:    return .green
        case .stalled:      return .orange
        case .disconnected: return .secondary
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if syncState.isSyncing {
            Label("Syncing", systemImage: "arrow.2.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundStyle(statusColor)
        } else if let error = syncState.syncError {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(statusColor)
        } else {
            let missingCount = syncState.emptyExpectedMetricNames.count
            let isPartial = missingCount > 0 && syncState.connectionHealth == .connected
            let needsServerUpdate = !isPartial && syncState.serverLacksMergedHours
                && syncState.connectionHealth == .connected
            let backgroundUnavailable = !isPartial && !needsServerUpdate
                && !syncState.backgroundDeliveryFailedTypes.isEmpty
                && syncState.connectionHealth == .connected
            let title = isPartial ? "Partial data"
                : needsServerUpdate ? "Server update needed"
                : backgroundUnavailable ? "Background sync unavailable"
                : syncState.connectionHealth.title
            let symbol = (isPartial || needsServerUpdate || backgroundUnavailable)
                ? "exclamationmark.circle.fill" : syncState.connectionHealth.systemImage
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    // design.md colour rule 1: the semantic goes on the symbol, the words stay
                    // .primary. Orange title text measured 2.31:1 on the card ground.
                    Label {
                        Text(title).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: symbol).foregroundStyle(statusColor)
                    }
                    .font(.title3.weight(.semibold))
                    if isPartial {
                        Text("\(missingCount) core metric\(missingCount == 1 ? " is" : "s are") not being shared")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if needsServerUpdate {
                        // The flag says the SERVER lacks merged hours; it knows nothing about the
                        // user's devices. With no Watch nothing is double-counted, so the claim is
                        // stated as conditional rather than as a checked fact.
                        Text("With an Apple Watch, steps, distance and energy are counted twice.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if backgroundUnavailable {
                        // HealthKit refused background delivery, so observers fire only in the
                        // foreground. Was a print() until 2026-09-14; the user could not see it.
                        Text("Background sync is unavailable on this device; data syncs when you open the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if syncState.connectionHealth == .stalled {
                        // A stalled connection with background delivery refused has its likely
                        // cause in hand, so the caption names it instead of leaving a mystery.
                        Text(syncState.backgroundDeliveryFailedTypes.isEmpty
                             ? "Signed in, but no health records in the last 48 hours"
                             : "No health records in the last 48 hours. Background sync is unavailable on this device; data syncs when you open the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // One VoiceOver element for headline + caption. The link below stays separate so
                // it remains its own actionable element.
                .accessibilityElement(children: .combine)
                if needsServerUpdate {
                    // The function lives in the user's own project and the app cannot update it,
                    // so the card links to the steps that do (design.md: a recovery instruction
                    // leads to something usable). Register D361.
                    Link("How to update healthkit-ingest", destination: Self.updateGuideURL)
                        .font(.caption)
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var syncIcon: some View {
        if syncState.isSyncing {
            ProgressView()
                .scaleEffect(1.2)
        } else {
            // In a warning state the label's own symbol already says it in orange; a second orange
            // symbol in the same card repeats one fact twice. Healthy, stalled and disconnected
            // keep the status colour, where the antenna is the only symbol saying it.
            let isWarning = syncState.connectionHealth == .connected
                && (!syncState.emptyExpectedMetricNames.isEmpty
                    || syncState.serverLacksMergedHours
                    || !syncState.backgroundDeliveryFailedTypes.isEmpty)
            Image(systemName: syncState.connectionHealth == .disconnected
                  ? "antenna.radiowaves.left.and.right.slash"
                  : "antenna.radiowaves.left.and.right")
                .font(.title)
                .foregroundStyle(isWarning ? Color.secondary : statusColor)
        }
    }

    // MARK: - Data scope summary

    private var scopeCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.bar.fill")
                .font(.title2)
                .foregroundStyle(.purple)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Metric types")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(healthScope == .essentials ? "Core set" : "All supported")
                    .font(.title3.bold())
            }
            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - MCP / Claude card

    private var mcpCard: some View {
        Button { showMCPSetup = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Ask any AI", systemImage: "brain")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(syncState.backfillEarliestDate != nil || syncState.lastSyncDate != nil
                     ? "Your health data is live — query with Claude, Ollama, ChatGPT, or any MCP-compatible AI"
                     : "Sync your data, then ask any AI natural-language questions about any metric")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Health access card

    /// Apple Health read authorization status is not reliably queryable for read types,
    /// so this card is always available as a recovery path: for users who tapped
    /// "Skip for now" during onboarding, or who revoked access in iOS Settings later.
    private var healthAccessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Apple Health Access", systemImage: "heart.text.square")
                .font(.headline)
            Text(needsHealthPrompt
                 ? "Choose how much health data health4ai may read, then grant access."
                 : "health4ai has already asked for access. iOS only shows that prompt once, so changes are made in Settings or the Health app.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("Data scope") {
                Picker("Data scope", selection: $healthScope) {
                    ForEach(HealthKitManager.DataScope.allCases) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(isRequestingHealth)
            }
            Text(healthScope.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if isRequestingHealth {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Requesting access…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let healthAccessError {
                Label(healthAccessError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            // Prominence follows what the button actually does. Granting access is a
            // real primary action and is styled as one; once iOS has asked, the only
            // remaining actions are two ways to review a setting, and rendering either
            // as a full-width tinted button reads as an unresolved error on a screen
            // that is in fact healthy.
            if needsHealthPrompt {
                Button {
                    requestHealthAccess(scope: healthScope)
                } label: {
                    Text("Grant Health Access")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(isRequestingHealth)
            }
            // Per-type sharing lives in the Health app, and openURL already falls
            // back to iOS Settings when the scheme is declined — so a separate
            // Settings button would duplicate a fallback the code performs, and
            // land the user further from the toggles they came to change.
            // Before the grant there is nothing there to manage, so it stays hidden.
            if !needsHealthPrompt {
                Button {
                    openURL("x-apple-health://", fallback: UIApplication.openSettingsURLString)
                } label: {
                    Text("Open Health App")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // The scope picker is the only place a read scope is chosen, so it owns the
        // authorization request: HealthKitManager.requestAuthorization persists the
        // scope and asks iOS for any types not yet authorized under it.
        .onChange(of: healthScope) { oldScope, newScope in
            guard !isRevertingScope else {
                isRevertingScope = false
                return
            }
            requestHealthAccess(scope: newScope, revertingTo: oldScope)
        }
    }

    /// Opens `urlString`, falling back to `fallback` when the system declines the scheme.
    private func openURL(_ urlString: String, fallback: String? = nil) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened,
                  let fallback,
                  let fallbackURL = URL(string: fallback) else { return }
            UIApplication.shared.open(fallbackURL)
        }
    }

    /// - Parameter previousScope: restored into the picker if the request fails, so the
    ///   UI never shows a scope that was not actually authorized and persisted.
    private func requestHealthAccess(scope: HealthKitManager.DataScope,
                                     revertingTo previousScope: HealthKitManager.DataScope? = nil) {
        isRequestingHealth = true
        healthAccessError = nil
        Task {
            do {
                try await HealthKitManager.shared.requestAuthorization(scope: scope)
                await MainActor.run { isRequestingHealth = false }
            } catch {
                await MainActor.run {
                    isRequestingHealth = false
                    healthAccessError = error.localizedDescription
                    if let previousScope, previousScope != healthScope {
                        isRevertingScope = true
                        healthScope = previousScope
                    }
                }
            }
            await refreshHealthPromptState()
        }
    }

    private func refreshHealthPromptState() async {
        let needsPrompt = await HealthKitManager.shared.needsAuthorizationRequest(scope: healthScope)
        await MainActor.run { needsHealthPrompt = needsPrompt }
    }

    // MARK: - Backfill card

    private var backfillCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Import Health History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            if syncState.isBackfilling {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        // A spinner next to "nothing has moved" asserts activity and no
                        // activity at once, and the spinner is the stronger signal — it is
                        // exactly what made a wedged import look like work.
                        if isImportStalled {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .frame(width: 20)
                        } else {
                            ProgressView().scaleEffect(0.85)
                        }
                        if syncState.backfillSyncedRecords == 0 {
                            Text("Scanning HealthKit…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            progressLines
                        }
                        Spacer()
                    }
                    if isImportStalled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Nothing has moved in \(Self.stallMinutes) minutes.")
                                .font(.caption)
                            // The recovery lives here rather than in prose: the control
                            // this used to name is in a different card and is disabled
                            // while isBackfilling, so the instruction was unfollowable.
                            // Frame INSIDE the label. Outside, .bordered sizes its
                            // background to the label's intrinsic size and centres it,
                            // which rendered a 138x28pt pill in a 338pt box — below the
                            // 44pt minimum this file's own design.md sets.
                            Button {
                                // Await the actual stop. Restarting on a cancel REQUEST
                                // races two runBackfill tasks against the same
                                // UserDefaults-backed sets.
                                Task {
                                    await BulkExportManager.shared.cancelAndWait()
                                    syncState.isBackfilling = false
                                    BulkExportManager.shared.startBackfill(syncState: syncState)
                                }
                            } label: {
                                Text("Cancel and Resume")
                                    .font(.caption.weight(.medium))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10))
                    }
                    Button(role: .destructive) {
                        BulkExportManager.shared.cancelBackfill()
                    } label: {
                        Text("Cancel")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            } else if syncState.backfillCompleted {
                if syncState.emptyExpectedMetricNames.isEmpty {
                    Label("Complete", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                } else {
                    emptyMetricsWarning
                }
            } else {
                if !syncState.importFailedMetricNames.isEmpty {
                    // Replaces the first-run caption: that caption reads as if nothing has run,
                    // and it would sit between the warning and the button the warning names.
                    importFailedWarning
                } else {
                    // Says what the import setting will actually do; "all historical records"
                    // under the one-year default would be a claim the sweep does not honour.
                    Text(syncState.importHorizon == .everything
                         ? "Import all historical health records from HealthKit."
                         : "Import the last year of health records from HealthKit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // The failed-import warning names this button as the recovery, so it gets the
                // same 44pt bordered treatment as the card's other actions (design.md).
                Button {
                    BulkExportManager.shared.startBackfill(syncState: syncState)
                } label: {
                    Text("Run Import")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!syncState.isAuthenticated)
            }
        }
        .padding()
        // Without this the "Complete" branch has no width-expanding child, so the card
        // shrinks to its intrinsic width and centres — making this one card change
        // width depending on which state it is in.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// The last import stopped on an error for these metrics. Without this the card fell back
    /// to the plain "Run Import" prompt, identical to an import that never ran, while the
    /// failure sat in `backfillError`, which nothing displays.
    private var importFailedWarning: some View {
        let names = syncState.importFailedMetricNames
        // Any of ~120 types can fail; past five the list would push the button off screen.
        let shown = names.count > 5 ? Array(names.prefix(4)) + ["\(names.count - 4) more"] : names
        return VStack(alignment: .leading, spacing: 10) {
            // Orange on the symbol only, as in emptyMetricsWarning (orange text is 2.31:1).
            Label {
                Text("Import didn't finish for \(names.count) metric\(names.count == 1 ? "" : "s")")
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.subheadline.weight(.medium))
            Text(shown.formatted(.list(type: .and)))
                .font(.caption.weight(.medium))
            // Names Run Import only while it is enabled; signed out, the button is disabled.
            Text(syncState.isAuthenticated
                 ? "The import retries the next time you open the app, or tap Run Import now. Data already imported is kept."
                 : "The import retries after you sign in. Data already imported is kept.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Backfill finished, but metrics that cannot legitimately be empty came back with
    /// nothing. HealthKit never reports a denied read, so this is the only place the
    /// app can tell the user their data is missing instead of showing a green check.
    private var emptyMetricsWarning: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Orange on the symbol only. Measured, orange caption text on the card
            // background is 2.31:1 in light mode — below even the 3:1 large-text bar,
            // which made the least legible text on the card the only warning on it.
            Label {
                Text("Imported, but \(syncState.emptyExpectedMetricNames.count) metric\(syncState.emptyExpectedMetricNames.count == 1 ? "" : "s") returned no data")
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.subheadline.weight(.medium))
            Text(syncState.emptyExpectedMetricNames.formatted(.list(type: .and)))
                .font(.caption.weight(.medium))
            // Deliberately does not name a Health-app navigation path: Apple moves it
            // between releases, and a wrong path is worse than none.
            Text("These are almost certainly turned off for health4ai in the Health app. Turn them back on, then re-run the import.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The copy asks the user to run the backfill again, so the retry belongs
            // here rather than unlabelled in a separate card further down the screen.
            // Re-arms ONLY the metrics named above. Everything else keeps its progress,
            // so fixing a permission costs one short sweep rather than a full re-import.
            Button {
                // The SUBSET the card just named, not all four always-expected types.
                // The label promises "these metrics"; re-importing the other three would
                // make the label a lie and cost three unnecessary full sweeps.
                BulkExportManager.shared.resetTypes(
                    BulkExportManager.shared.emptyHighVolumeTypes, syncState: syncState)
                BulkExportManager.shared.startBackfill(syncState: syncState)
            } label: {
                Text("Retry These Metrics")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!syncState.isAuthenticated || syncState.isBackfilling)
        }
    }

    /// A re-run has to clear per-type completion first. `runBackfill` skips every type
    /// already in `completedTypes`, so calling startBackfill on a finished import swept
    /// zero types, latched "complete" again and returned instantly — leaving a user
    /// whose data is actually missing with no way to retry. Resuming an unfinished run
    /// must NOT reset, which is why this is only reachable once the import completed.
    private func rerunImport() {
        if syncState.backfillCompleted {
            BulkExportManager.shared.resetBackfill()
            syncState.backfillCompleted = false
        }
        BulkExportManager.shared.startBackfill(syncState: syncState)
    }

    // MARK: - Actions card

    private var actionsCard: some View {
        VStack(spacing: 0) {
            Button {
                SyncEngine.shared.performForegroundSync()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28)
                    Text("Sync Now")
                    Spacer()
                    if syncState.isSyncing {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .padding()
            }
            .disabled(syncState.isSyncing || !syncState.isAuthenticated)
            // Shown only when there is genuinely something to resume or re-run. On a
            // never-started import the Import card already offers "Run Import", and this
            // row rendered the identical words for the identical action 280pt away.
            if syncState.backfillCompleted || syncState.backfillSyncedRecords > 0 {
            Divider().padding(.leading, 44)
            Button {
                // Resuming and starting over are different actions with very different
                // costs, so they are no longer the same button. An unfinished import
                // resumes from its per-type checkpoints; only a FINISHED one offers to
                // start over, and that asks first, because it discards every checkpoint
                // and re-sends the whole history the import setting covers.
                if syncState.backfillCompleted {
                    confirmStartOver = true
                } else {
                    BulkExportManager.shared.startBackfill(syncState: syncState)
                }
            } label: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(width: 28)
                    // Three cases, not two. An import that has never run has nothing to
                    // resume, and calling it "Resume" duplicated the Import card's own
                    // "Run Import" with a different word for the identical action.
                    Text(importActionLabel)
                    Spacer()
                }
                .padding()
            }
            // .tint, not .foregroundStyle. The button style consults tint, so the
            // automatic disabled dimming composes OVER it; an explicit foregroundStyle
            // anywhere in the label subtree overrides that dimming instead, which left
            // this row full-strength blue and looking tappable while disabled
            // mid-import. Measured disabled rgb(197,197,199) with tint vs rgb(0,136,255)
            // with foregroundStyle. Deliberately not a conditional colour keyed off the
            // same predicate as .disabled — those two would drift apart.
            .tint(syncState.backfillCompleted ? Color.red : Color.accentColor)
            .disabled(!syncState.isAuthenticated || syncState.isBackfilling)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .confirmationDialog("Import again from scratch?",
                            isPresented: $confirmStartOver, titleVisibility: .visible) {
            Button("Import Again from Scratch", role: .destructive) { rerunImport() }
            Button("Cancel", role: .cancel) { }
        } message: {
            // The cost stated is the one the horizon sets. Under the one-year default the
            // re-send stops a year back, and "from 2013" would overstate it.
            Text(syncState.importHorizon == .everything
                 ? "This discards where the last import got to and re-sends your full "
                   + "history from 2013. It can take hours."
                 : "This discards where the last import got to and re-sends the last "
                   + "year of your history. It can take a while.")
        }
    }
}

// MARK: - MCP Setup Sheet

struct MCPSetupView: View {
    @EnvironmentObject var syncState: SyncState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    howItWorksCard
                    privacyNoteCard
                    stepsCard
                    exampleQuestionsCard
                    githubCard
                }
                .padding()
            }
            .navigationTitle("Ask Any AI")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: How it works

    private var howItWorksCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How it works")
                .font(.headline)
            Text("Your synced health data lives in your own database. The health4ai MCP server connects it to any AI you choose — local models like Ollama stay fully on-device. No SQL required.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                MCPFlowRow(icon: "iphone", label: "This app", sublabel: "syncs HealthKit → your database", color: .pink)
                MCPFlowArrow()
                MCPFlowRow(icon: "server.rack", label: "Your Supabase DB",
                           sublabel: syncState.backfillEarliestDate.map { "Your data since \(Calendar.current.component(.year, from: $0))" } ?? "your health records",
                           color: .green)
                MCPFlowArrow()
                MCPFlowRow(icon: "hammer", label: "health4ai MCP server", sublabel: "runs on your Mac (open source)", color: .orange)
                MCPFlowArrow()
                MCPFlowRow(icon: "brain", label: "Your AI", sublabel: "Claude, Ollama, ChatGPT, Gemini — your choice", color: .blue)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Steps

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("One-time setup")
                .font(.headline)

            MCPStep(
                number: 1,
                title: "Clone the repo",
                detail: "github.com/jefflitt1/health4ai — the MCP server is in the mcp-server/ folder."
            )
            Divider().padding(.leading, 36)
            MCPStep(
                number: 2,
                title: "Add your Supabase credentials",
                detail: "Copy SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY from your Supabase project settings into mcp-server/.env"
            )
            Divider().padding(.leading, 36)
            MCPStep(
                number: 3,
                title: "Connect your AI client",
                detail: "Works with any MCP-compatible client — Claude Desktop, Cursor, Continue, or a local Ollama setup. Config snippets for each in the README."
            )
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Privacy note

    private var privacyNoteCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Fully private with a local model")
                    .font(.subheadline.weight(.semibold))
                Text("Run Ollama locally and your health data never leaves your Mac — the app syncs to your own database, and the AI runs on your own hardware.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.green.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.green.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: Example questions

    private var exampleQuestionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask your AI things like…")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ExampleQuestion(text: "\"Show me my worst HRV days this year\"")
                ExampleQuestion(text: "\"Is my resting HR unusually high today?\"")
                ExampleQuestion(text: "\"Did my sleep improve after I started lifting?\"")
                ExampleQuestion(text: "\"Compare my steps this month vs last month\"")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: GitHub

    private var githubCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source & docs")
                .font(.headline)
            Text("Open source under the MIT License. Full setup guide, MCP tool reference, and troubleshooting in the README.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Link(destination: URL(string: "https://github.com/jefflitt1/health4ai")!) {
                HStack {
                    Image(systemName: "arrow.up.right.square")
                    Text("health4ai on GitHub")
                        .fontWeight(.medium)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - MCPSetupView sub-components

private struct MCPFlowRow: View {
    let icon: String
    let label: String
    let sublabel: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Text(sublabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(color.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MCPFlowArrow: View {
    var body: some View {
        HStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1.5, height: 16)
                .padding(.leading, 23)
            Spacer()
        }
    }
}

private struct MCPStep: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.pink)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ExampleQuestion: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.pink)
                .padding(.top, 2)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .italic()
        }
    }
}
