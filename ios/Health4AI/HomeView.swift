import SwiftUI
import UIKit

struct HomeView: View {
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    scopeCard
                    mcpCard
                    healthAccessCard
                    backfillCard
                    actionsCard
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("health4ai")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showMCPSetup) {
                MCPSetupView()
                    .environmentObject(syncState)
            }
            .task { await refreshHealthPromptState() }
            .onChange(of: scenePhase) { _, phase in
                // Coming back from Settings or the Health app can change access.
                if phase == .active {
                    Task { await refreshHealthPromptState() }
                }
            }
        }
    }

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
                Spacer()
                syncIcon
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
                    Text("Next sync")
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
    private var statusColor: Color {
        if syncState.isSyncing { return .blue }
        if syncState.syncError != nil { return .red }
        // Metrics known to be missing outrank a healthy connection: the transport can be
        // fine while the data is not arriving, and the headline must not read green while
        // the app already knows core metrics returned nothing.
        if !syncState.emptyExpectedMetricNames.isEmpty { return .orange }
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
            VStack(alignment: .leading, spacing: 2) {
                Label(isPartial ? "Partial data" : syncState.connectionHealth.title,
                      systemImage: isPartial ? "exclamationmark.circle.fill" : syncState.connectionHealth.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(statusColor)
                if isPartial {
                    Text("\(missingCount) core metric\(missingCount == 1 ? " is" : "s are") not being shared")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if syncState.connectionHealth == .stalled {
                    Text("Signed in, but no health records in the last 48 hours")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            Image(systemName: syncState.connectionHealth == .disconnected
                  ? "antenna.radiowaves.left.and.right.slash"
                  : "antenna.radiowaves.left.and.right")
                .font(.title)
                .foregroundStyle(statusColor)
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
            VStack(spacing: 10) {
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
                        ProgressView().scaleEffect(0.85)
                        if syncState.backfillSyncedRecords == 0 {
                            Text("Scanning HealthKit…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(syncState.backfillSyncedRecords.formatted()) records synced")
                                    .font(.subheadline.weight(.medium))
                                if let date = syncState.backfillEarliestDate {
                                    Text("back to \(date.formatted(.dateTime.month().year()))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Spacer()
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
                Text("Import all historical health records from HealthKit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Run Backfill") {
                    BulkExportManager.shared.startBackfill(syncState: syncState)
                }
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

    /// Backfill finished, but metrics that cannot legitimately be empty came back with
    /// nothing. HealthKit never reports a denied read, so this is the only place the
    /// app can tell the user their data is missing instead of showing a green check.
    private var emptyMetricsWarning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Imported, but \(syncState.emptyExpectedMetricNames.count) metric\(syncState.emptyExpectedMetricNames.count == 1 ? "" : "s") returned no data",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            Text(syncState.emptyExpectedMetricNames.formatted(.list(type: .and)))
                .font(.caption.weight(.medium))
            // Deliberately does not name a Health-app navigation path: Apple moves it
            // between releases, and a wrong path is worse than none.
            Text("These are almost certainly turned off for health4ai in the Health app. Turn them back on, then re-run the import.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // The copy asks the user to run the backfill again, so the retry belongs
            // here rather than unlabelled in a separate card further down the screen.
            Button {
                BulkExportManager.shared.resetBackfill()
                syncState.backfillCompleted = false
                BulkExportManager.shared.startBackfill(syncState: syncState)
            } label: {
                Text("Re-run Import")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!syncState.isAuthenticated || syncState.isBackfilling)
        }
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
            Divider().padding(.leading, 44)
            Button {
                // A re-run has to clear per-type completion first. `runBackfill` skips
                // every type already in `completedTypes`, so calling startBackfill on a
                // finished backfill swept zero types, latched "complete" again, and
                // returned instantly — leaving a user whose data is actually missing
                // with no way to retry. Resuming an unfinished run must NOT reset.
                if syncState.backfillCompleted {
                    BulkExportManager.shared.resetBackfill()
                    syncState.backfillCompleted = false
                }
                BulkExportManager.shared.startBackfill(syncState: syncState)
            } label: {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(width: 28)
                    Text(syncState.backfillCompleted ? "Re-run Backfill" : "Run Backfill")
                    Spacer()
                }
                .padding()
            }
            .disabled(!syncState.isAuthenticated || syncState.isBackfilling)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
