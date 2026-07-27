import KitroomCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(model.hosts, selection: $model.selectedHostID) { host in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name)
                        Text(host.connection.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: host.connection.isRemote ? "server.rack" : "laptopcomputer")
                }
                .tag(host.id)
                .padding(.vertical, 4)
            }
            .navigationTitle("Hosts")
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if let host = model.selectedHost {
                HostOverview(host: host)
            } else {
                ContentUnavailableView(
                    "Select a host",
                    systemImage: "shippingbox"
                )
            }
        }
    }
}

private struct HostOverview: View {
    let host: ManagedHost

    private let columns = [
        GridItem(.adaptive(minimum: 280), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(AgentKind.allCases) { agent in
                        AgentCard(agent: agent)
                    }
                }

                safetyNote
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(host.name)
        .toolbar {
            ToolbarItem {
                Button {
                    // Inventory scanning is intentionally not wired in the scaffold.
                } label: {
                    Label("Scan", systemImage: "arrow.clockwise")
                }
                .disabled(true)
                .help("Inventory scanning is not implemented yet")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: host.connection.isRemote ? "server.rack" : "laptopcomputer")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 5) {
                Text(host.name)
                    .font(.largeTitle.bold())
                Text(host.connection.description)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label("Not scanned", systemImage: "questionmark.circle")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.secondary.opacity(0.1), in: Capsule())
        }
    }

    private var safetyNote: some View {
        Label {
            Text("Kitroom will preview and verify every change before considering an operation complete.")
        } icon: {
            Image(systemName: "checkmark.shield")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AgentCard: View {
    let agent: AgentKind

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "shippingbox")
                    .font(.title2)
                    .foregroundStyle(.tint)

                Text(agent.displayName)
                    .font(.title3.bold())

                Spacer()

                Text("Not scanned")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 24) {
                metric(title: "Skills")
                metric(title: "Plugins")
                metric(title: "MCP")
            }

            Button("View inventory") {}
                .buttonStyle(.bordered)
                .disabled(true)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
    }

    private func metric(title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("—")
                .font(.title2.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

