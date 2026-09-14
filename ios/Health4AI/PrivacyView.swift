import SwiftUI

struct PrivacyView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    dataFlowDiagram
                    guaranteesSection
                    openSourceSection
                }
                .padding()
            }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Data flow diagram

    private var dataFlowDiagram: some View {
        VStack(spacing: 0) {
            Text("Where your data goes")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)

            VStack(spacing: 0) {
                FlowNode(icon: "applewatch", label: "Apple Watch / Wearables", color: .primary)
                FlowArrow(label: "HealthKit API")
                FlowNode(icon: "iphone", label: "Your iPhone", color: .primary)
                FlowArrow(label: "HTTPS — your endpoint only")
                FlowNode(icon: "server.rack", label: "Your Supabase / API", color: .green)
                FlowArrow(label: "MCP protocol")
                FlowNode(icon: "brain", label: "Your AI agent (Claude, etc.)", color: .blue)
            }

            Text("health4ai is not a shared health-data backend. Your chosen database and AI provider remain separate privacy decisions.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Guarantees

    private var guaranteesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What we guarantee")
                .font(.headline)

            GuaranteeRow(
                icon: "xmark.shield.fill",
                color: .red,
                title: "No data collection",
                detail: "health4ai does not operate a shared health-data backend. Your health data goes only to the database endpoint you configure."
            )
            GuaranteeRow(
                icon: "eye.slash.fill",
                color: .orange,
                title: "No analytics",
                detail: "The app contains no analytics or crash-reporting SDKs. Your chosen database and any cloud AI provider have their own privacy practices."
            )
            GuaranteeRow(
                icon: "lock.open.fill",
                color: .green,
                title: "Open source",
                detail: "Every line of code is publicly auditable on GitHub. What you see is what runs."
            )
            GuaranteeRow(
                icon: "arrow.triangle.2.circlepath",
                color: .indigo,
                title: "Sync status is visible",
                detail: "health4ai syncs every time you open the app, and in the background when iOS allows it. The Home screen shows the last completed sync, and says so if background sync is unavailable on this device."
            )
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Open source

    private var openSourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open source")
                .font(.headline)
            Text("health4ai is MIT-licensed. Fork it, audit it, self-host it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Link(destination: URL(string: "https://github.com/jefflitt1/health4ai")!) {
                HStack {
                    Image(systemName: "arrow.up.right.square")
                    Text("View on GitHub")
                }
                .font(.subheadline.weight(.medium))
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Sub-components

private struct FlowNode: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 32)
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct FlowArrow: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1.5, height: 24)
                .padding(.leading, 27)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

private struct GuaranteeRow: View {
    let icon: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
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
