import KitroomCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        List(selection: $model.selectedSection) {
            Section {
                NavigationLink(value: AppSection.hosts) {
                    Label(AppSection.hosts.title, systemImage: AppSection.hosts.systemImage)
                }

                NavigationLink(value: AppSection.inventory) {
                    Label(AppSection.inventory.title, systemImage: AppSection.inventory.systemImage)
                }

                NavigationLink(value: AppSection.catalogue) {
                    Label(AppSection.catalogue.title, systemImage: AppSection.catalogue.systemImage)
                }

                NavigationLink(value: AppSection.activity) {
                    Label(AppSection.activity.title, systemImage: AppSection.activity.systemImage)
                }
            } header: {
                BrandLabel()
                    .textCase(nil)
                    .padding(.bottom, 8)
            }

            Section {
                NavigationLink(value: AppSection.settings) {
                    Label(AppSection.settings.title, systemImage: AppSection.settings.systemImage)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 300)
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selectedSection ?? .hosts {
        case .hosts:
            HostsView()
        case .inventory:
            FeaturePlaceholder(
                title: "Inventory",
                systemImage: "shippingbox",
                message: "Inventory scanning is not implemented yet. Future scans will show verified skills, plugins, and MCP servers for each host."
            )
        case .catalogue:
            FeaturePlaceholder(
                title: "Catalogue",
                systemImage: "books.vertical",
                message: "Catalogue browsing is not implemented yet. Sources and provenance will appear here before installation is enabled."
            )
        case .activity:
            FeaturePlaceholder(
                title: "Activity",
                systemImage: "clock.arrow.circlepath",
                message: "There are no operations to show. Kitroom does not execute inventory or mutation commands in this build."
            )
        case .settings:
            FeaturePlaceholder(
                title: "Settings",
                systemImage: "gear",
                message: "Settings are not implemented yet. OpenSSH configuration and credentials remain outside Kitroom."
            )
        }
    }
}

private struct BrandLabel: View {
    var body: some View {
        HStack(spacing: 10) {
            brandImage
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("Kitroom")
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }

    private var brandImage: Image {
#if SWIFT_PACKAGE
        Image("KitroomLogo", bundle: .module)
#else
        Image("KitroomLogo")
#endif
    }
}

private struct HostsView: View {
    @EnvironmentObject private var model: AppModel

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(model.hosts) { host in
                        HostCard(
                            host: host,
                            isSelected: host.id == model.selectedHostID
                        ) {
                            model.selectedHostID = host.id
                        }
                    }

                    if model.remoteHostCount == 0 {
                        RemoteHostPlaceholder()
                    }
                }

                SafetyNote()
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Hosts")
        .toolbar {
            ToolbarItem {
                Button {
                    // Remote-host setup is intentionally unavailable in this slice.
                } label: {
                    Label("Add remote host", systemImage: "plus")
                }
                .disabled(true)
                .help("Remote-host setup is not implemented yet")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hosts")
                .font(.largeTitle.bold())

            Text("Choose where Kitroom will inspect and manage coding-agent extensions.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct HostCard: View {
    let host: ManagedHost
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: host.connection.isRemote ? "server.rack" : "laptopcomputer")
                        .font(.system(size: 24))
                        .foregroundStyle(.tint)
                        .frame(width: 46, height: 46)
                        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.name)
                            .font(.title3.weight(.semibold))
                        Text(host.connection.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    StatusBadge(title: "Not scanned", systemImage: "circle.dashed")
                }

                Divider()

                HStack(spacing: 24) {
                    AgentSummary(name: "Codex")
                    AgentSummary(name: "Claude Code")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Selects this host")
    }
}

private struct AgentSummary: View {
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.callout.weight(.medium))
            Text("Not scanned")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatusBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.secondary.opacity(0.1), in: Capsule())
    }
}

private struct RemoteHostPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                Text("No remote hosts")
                    .font(.title3.weight(.semibold))
                Text("Remote hosts will use aliases and trust decisions from your existing OpenSSH configuration.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label("Setup is not implemented yet", systemImage: "hammer")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 164, alignment: .leading)
        .background(.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                )
        }
    }
}

private struct SafetyNote: View {
    var body: some View {
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

private struct FeaturePlaceholder: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
                .frame(maxWidth: 480)
        }
        .navigationTitle(title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}
