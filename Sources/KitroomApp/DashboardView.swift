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
        .sheet(item: $model.pendingOperationPlan) { plan in
            OperationPlanReviewView(plan: plan)
                .environmentObject(model)
        }
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
            InventoryProductView()
        case .catalogue:
            CatalogueProductView()
        case .activity:
            ActivityProductView()
        case .settings:
            SettingsProductView()
        }
    }
}

private struct InventoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let host = selectedHost {
                    ForEach(AgentKind.allCases) { agent in
                        AgentInventorySection(
                            agent: agent,
                            snapshot: model.inventory(for: host, agent: agent)
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "No host selected",
                        systemImage: "shippingbox",
                        description: Text("Select a host before checking inventory.")
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Inventory")
    }

    private var selectedHost: ManagedHost? {
        model.selectedHost ?? model.hosts.first
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Inventory")
                        .font(.largeTitle.bold())
                    Text("Evidence-backed packages and capabilities reported by each agent.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let host = selectedHost,
                   model.inventoryScanningHostIDs.contains(host.id) {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") {
                        model.cancelInventoryScan(host)
                    }
                } else if let host = selectedHost {
                    Button {
                        model.scanInventory(host)
                    } label: {
                        Label(
                            hasAnySnapshot(for: host)
                                ? "Check again"
                                : "Check inventory",
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
            }

            if !model.hosts.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    Picker(
                        "Host",
                        selection: Binding(
                            get: { selectedHost?.id ?? model.hosts[0].id },
                            set: { model.selectedHostID = $0 }
                        )
                    ) {
                        ForEach(model.hosts) { host in
                            Text(host.name).tag(host.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280, alignment: .leading)

                    if let host = selectedHost {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(
                                "Project directory (optional)",
                                text: Binding(
                                    get: {
                                        model.projectDirectory(for: host)
                                    },
                                    set: {
                                        model.setProjectDirectory($0, for: host)
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .disabled(
                                model.inventoryScanningHostIDs.contains(host.id)
                            )
                            .accessibilityHint(
                                "Enter an absolute path on the selected host to include repository-scoped skills and configuration."
                            )

                            Text(
                                "Optional absolute path on this host. Kitroom inspects parent layers up to the Git root."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 440)
                    }
                }
            }
        }
    }

    private func hasAnySnapshot(for host: ManagedHost) -> Bool {
        AgentKind.allCases.contains {
            model.inventory(for: host, agent: $0) != nil
        }
    }
}

private struct AgentInventorySection: View {
    let agent: AgentKind
    let snapshot: InventorySnapshot?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(agent.displayName)
                            .font(.title3.weight(.semibold))
                        Text(snapshot?.agentVersion ?? "Version not checked")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    InventoryStatusBadge(status: snapshot?.status)
                }

                if let snapshot {
                    if !snapshot.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(snapshot.issues) { issue in
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(issue.summary)
                                        Text(issue.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "exclamationmark.circle")
                                }
                            }
                        }
                        .padding(12)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if snapshot.packages.isEmpty
                        && snapshot.providedCapabilities.isEmpty {
                        Text(
                            snapshot.status == .complete
                                ? "No packages or capabilities were reported."
                                : "No verified items are available from this scan."
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(snapshot.packages) { package in
                            PackageInventoryRow(
                                package: package,
                                capabilities: snapshot.providedCapabilities.filter {
                                    $0.packageID == package.id
                                },
                                installations: snapshot.installations.filter {
                                    $0.packageID == package.id
                                },
                                evidence: snapshot.evidence,
                                capturedAt: snapshot.capturedAt
                            )
                        }

                        let standalone = snapshot.providedCapabilities.filter {
                            $0.packageID == nil
                        }
                        if !standalone.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Directly configured")
                                    .font(.headline)
                                ForEach(standalone) { capability in
                                    CapabilityLabel(
                                        capability: capability,
                                        installation: snapshot.installations.first {
                                            $0.capabilityID == capability.id
                                        },
                                        evidence: snapshot.evidence,
                                        capturedAt: snapshot.capturedAt
                                    )
                                }
                            }
                            .padding(.top, 4)
                        }
                    }

                    Divider()
                    Text(
                        "Captured \(snapshot.capturedAt.formatted(date: .abbreviated, time: .standard)) · \(snapshot.evidence.count) evidence records"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Not checked. Kitroom has not asked this agent for inventory on the selected host.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct PackageInventoryRow: View {
    let package: PackageRecord
    let capabilities: [ProvidedCapability]
    let installations: [InstallationRecord]
    let evidence: [EvidenceRecord]
    let capturedAt: Date

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if capabilities.isEmpty {
                    Text("No components were declared or discovered.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(capabilities) { capability in
                        CapabilityLabel(
                            capability: capability,
                            installation: installations.first {
                                $0.capabilityID == capability.id
                            },
                            evidence: evidence,
                            capturedAt: capturedAt
                        )
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(package.displayName)
                        .font(.headline)
                    if let version = package.version {
                        Text("Version \(version)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                InventoryMetadataLine(
                    installation: packageInstallation,
                    evidenceStatus: evidenceStatus(
                        ids: package.evidenceIDs
                            + (packageInstallation?.evidenceIDs ?? []),
                        evidence: evidence
                    ),
                    capturedAt: capturedAt
                )
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var packageInstallation: InstallationRecord? {
        installations.first { $0.capabilityID == nil }
            ?? installations.first
    }
}

private struct CapabilityLabel: View {
    let capability: ProvidedCapability
    let installation: InstallationRecord?
    let evidence: [EvidenceRecord]
    let capturedAt: Date

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(capability.displayName)
                    Spacer()
                    Text(capability.kind.displayName)
                        .foregroundStyle(.secondary)
                }
                InventoryMetadataLine(
                    installation: installation,
                    evidenceStatus: evidenceStatus(
                        ids: capability.evidenceIDs
                            + (installation?.evidenceIDs ?? []),
                        evidence: evidence
                    ),
                    capturedAt: capturedAt
                )
            }
        } icon: {
            Image(systemName: capability.kind.systemImage)
        }
        .font(.callout)
    }
}

private struct InventoryMetadataLine: View {
    let installation: InstallationRecord?
    let evidenceStatus: EvidenceStatus?
    let capturedAt: Date

    var body: some View {
        HStack(spacing: 8) {
            if let installation {
                Text(installation.scope.displayName)
                Text(installation.origin.displayName)
                Text(installation.state.displayName)
            } else {
                Text("Scope unknown")
                Text("Origin unknown")
                Text("State unknown")
            }
            Text("Evidence \(evidenceStatus?.displayName ?? "unknown")")
            Text(capturedAt, style: .relative)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private func evidenceStatus(
    ids: [EvidenceRecord.ID],
    evidence: [EvidenceRecord]
) -> EvidenceStatus? {
    let statuses = evidence
        .filter { ids.contains($0.id) }
        .map(\.status)
    if statuses.contains(.failure) {
        return .failure
    }
    if statuses.contains(.partial) {
        return .partial
    }
    if statuses.contains(.success) {
        return .success
    }
    return nil
}

private struct InventoryStatusBadge: View {
    let status: InventoryStatus?

    var body: some View {
        Text(status?.displayName ?? "Not checked")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.secondary.opacity(0.1), in: Capsule())
    }
}

private extension InventoryStatus {
    var displayName: String {
        switch self {
        case .complete:
            "Complete"
        case .partial:
            "Partial"
        case .unavailable:
            "Unavailable"
        }
    }
}

private extension EffectiveState {
    var displayName: String {
        rawValue
            .replacingOccurrences(
                of: "([a-z])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .capitalized
    }
}

private extension InventoryScope {
    var displayName: String {
        switch self {
        case .user:
            "User"
        case .repository:
            "Repository"
        case .localProject:
            "Local project"
        case .managed:
            "Managed"
        case .system:
            "System"
        case .session:
            "Session"
        case .unknown:
            "Scope unknown"
        }
    }
}

private extension InstallationOrigin {
    var displayName: String {
        switch self {
        case .standalone:
            "Standalone"
        case .marketplace:
            "Marketplace"
        case .pluginProvided:
            "Plugin-provided"
        case .shared:
            "Shared"
        case .legacy:
            "Legacy"
        case .runtimeInjected:
            "Runtime-injected"
        case .bundled:
            "Bundled"
        case .unknown:
            "Origin unknown"
        }
    }
}

private extension EvidenceStatus {
    var displayName: String {
        switch self {
        case .success:
            "verified"
        case .partial:
            "partial"
        case .failure:
            "failed"
        }
    }
}

private extension CapabilityKind {
    var displayName: String {
        switch self {
        case .skill:
            "Skill"
        case .mcpServer:
            "MCP server"
        case .hook:
            "Hook"
        case .subagent:
            "Subagent"
        case .connector:
            "Connector"
        case .lspServer:
            "LSP server"
        case .command:
            "Command"
        case .executable:
            "Executable"
        case .other:
            "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .skill:
            "sparkles"
        case .mcpServer:
            "point.3.connected.trianglepath.dotted"
        case .hook:
            "arrow.triangle.branch"
        case .subagent:
            "person.2"
        case .connector:
            "link"
        case .lspServer:
            "text.and.command.macwindow"
        case .command:
            "terminal"
        case .executable:
            "shippingbox"
        case .other:
            "puzzlepiece.extension"
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
    @State private var isShowingAddHost = false

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
                            isSelected: host.id == model.selectedHostID,
                            discovery: model.discovery(for: host),
                            lastSuccessfulAt: model.lastSuccessfulDiscovery(
                                for: host
                            ),
                            resolvedHost: model.resolvedHostByID[host.id],
                            scan: {
                                model.scan(host)
                            },
                            cancelScan: {
                                model.cancelScan(host)
                            }
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
                    isShowingAddHost = true
                } label: {
                    Label("Add remote host", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isShowingAddHost) {
            AddRemoteHostView()
                .environmentObject(model)
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
    let discovery: HostDiscoverySnapshot?
    let lastSuccessfulAt: Date?
    let resolvedHost: String?
    let scan: () -> Void
    let cancelScan: () -> Void
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Button(action: select) {
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

                        if let resolvedHost, host.connection.isRemote {
                            Text(resolvedHost)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Selects this host")

                Spacer()

                StatusBadge(
                    title: discovery?.connectionState.title ?? "Not checked",
                    systemImage: discovery?.connectionState.systemImage ?? "circle.dashed"
                )
            }

            Divider()

            if let platform = discovery?.platform {
                HStack(spacing: 18) {
                    Label(platform.operatingSystem, systemImage: "desktopcomputer")
                    if let architecture = platform.architecture {
                        Text(architecture)
                    }
                    if let latency = discovery?.latencyMilliseconds {
                        Text("\(Int(latency.rounded())) ms")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let identity = discovery?.identity {
                Label(
                    "Identity verified via \(identity.kind.displayName)",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if discovery != nil || lastSuccessfulAt != nil {
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last attempt")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let attemptedAt = discovery?.attemptedAt {
                            Text(attemptedAt, style: .relative)
                                .font(.caption)
                        } else {
                            Text("Not checked")
                                .font(.caption)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last successful")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let lastSuccessfulAt {
                            Text(lastSuccessfulAt, style: .relative)
                                .font(.caption)
                        } else {
                            Text("None recorded")
                                .font(.caption)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if let issues = discovery?.issues, !issues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(issues) { issue in
                        Label(issue.summary, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .accessibilityLabel(
                    "Host scan issues: "
                        + issues.map(\.summary).joined(separator: ", ")
                )
            }

            HStack(spacing: 24) {
                AgentSummary(
                    name: "Codex",
                    discovery: discovery?.agents.first { $0.agent == .codex }
                )
                AgentSummary(
                    name: "Claude Code",
                    discovery: discovery?.agents.first { $0.agent == .claude }
                )

                Spacer()

                if discovery?.connectionState == .connecting {
                    Button("Cancel", action: cancelScan)
                } else {
                    Button {
                        scan()
                    } label: {
                        Label(
                            discovery == nil ? "Check host" : "Check again",
                            systemImage: "arrow.clockwise"
                        )
                    }
                }
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
}

private struct AgentSummary: View {
    let name: String
    let discovery: DiscoveredAgent?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.callout.weight(.medium))
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var status: String {
        guard let discovery else {
            return "Not checked"
        }

        switch discovery.availability {
        case .available:
            return discovery.version ?? "Available · version unknown"
        case .notInstalled:
            return "Not installed"
        case .unknown:
            return "Unknown"
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

            Label("Add an OpenSSH alias to begin", systemImage: "plus.circle")
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

private struct AddRemoteHostView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var name = ""
    @State private var alias = ""
    @State private var errorMessage: String?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add remote host")
                    .font(.title2.bold())
                Text("Kitroom uses a concrete alias from your existing OpenSSH configuration. It does not copy keys or change host trust.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Display name", text: $name)
                TextField("OpenSSH alias", text: $alias)
                    .textContentType(.URL)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isAdding {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("Add host") {
                    isAdding = true
                    errorMessage = nil

                    Task {
                        do {
                            try await model.addRemoteHost(name: name, alias: alias)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                            isAdding = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isAdding || name.isEmpty || alias.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 480)
    }
}

private extension HostConnectionState {
    var title: String {
        switch self {
        case .notChecked:
            "Not checked"
        case .connecting:
            "Connecting"
        case .reachable:
            "Reachable"
        case .authenticationRequired:
            "Authentication required"
        case .hostIdentityChanged:
            "Host identity changed"
        case .unreachable:
            "Unreachable"
        case .partialDiscovery:
            "Partial discovery"
        case .cancelled:
            "Cancelled"
        }
    }

    var systemImage: String {
        switch self {
        case .notChecked:
            "circle.dashed"
        case .connecting:
            "arrow.triangle.2.circlepath"
        case .reachable:
            "checkmark.circle"
        case .authenticationRequired:
            "person.badge.key"
        case .hostIdentityChanged:
            "exclamationmark.shield"
        case .unreachable:
            "wifi.slash"
        case .partialDiscovery:
            "exclamationmark.circle"
        case .cancelled:
            "xmark.circle"
        }
    }
}

private extension HostIdentityKind {
    var displayName: String {
        switch self {
        case .platformUUID:
            "platform UUID"
        case .machineID:
            "machine ID"
        case .derived:
            "bounded platform evidence"
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
