import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject var syncState: SyncState
    @State private var showMCPSetup = false
    @State private var isRequestingHealth = false
    @State private var healthAccessError: String?
    @State private var healthScope = HealthKitManager.selectedScope

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    metricsGrid
                    mcpCard
                    healthAccessCard
                    backfillCard
                    actionsCard
                }
                .padding()
            }
            .navigationTitle("health4ai")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showMCPSetup) {
                MCPSetupView()
                    .environmentObject(syncState)
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
    }

    @ViewBuilder
    private var statusLabel: some View {
        if syncState.isSyncing {
            Label("Syncing", systemImage: "arrow.2.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.blue)
        } else if let error = syncState.syncError {
            Label(error, systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else if syncState.isAuthenticated {
            Label("Active", systemImage: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
        } else {
            Label("Not connected", systemImage: "circle.slash")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var syncIcon: some View {
        if syncState.isSyncing {
            ProgressView()
                .scaleEffect(1.2)
        } else {
            Image(systemName: syncState.isAuthenticated ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .font(.title)
                .foregroundStyle(syncState.isAuthenticated ? .pink : .secondary)
        }
    }

    // MARK: - Metrics grid

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricTile(
                icon: "calendar",
                color: .blue,
                label: "Tracking since",
                value: syncState.trackingSinceLabel
            )
            MetricTile(
                icon: "chart.bar.fill",
                color: .purple,
                label: "Metric types",
                value: HealthKitManager.selectedScope == .essentials ? "Core set" : "All supported"
            )
        }
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
            Text("If health data isn't syncing, grant access here or enable it in Settings. Already connected? This is a safe no-op.")
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
            }
            Text(healthScope.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let healthAccessError {
                Label(healthAccessError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button {
                    requestHealthAccess(scope: healthScope)
                } label: {
                    HStack(spacing: 6) {
                        if isRequestingHealth { ProgressView().scaleEffect(0.7) }
                        Text(isRequestingHealth ? "Requesting…" : "Request \(healthScope == .essentials ? "Core" : "All") Access")
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(isRequestingHealth)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open Settings")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func requestHealthAccess(scope: HealthKitManager.DataScope) {
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
                }
            }
        }
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
                Label("Complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
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
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
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

// MARK: - MetricTile

private struct MetricTile: View {
    let icon: String
    let color: Color
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Spacer()
            Text(value)
                .font(.title2.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
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
