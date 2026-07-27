import KitroomCore
import SwiftUI
import UniformTypeIdentifiers

struct InventoryProductView: View {
    @EnvironmentObject private var model: AppModel

    @State private var query = InventoryQuery()
    @State private var evidenceSelection: InventoryEvidenceSelection?
    @State private var diagnosticDocument: DiagnosticDocument?
    @State private var isExportingDiagnostics = false
    @State private var exportError: String?
    @State private var isChoosingLocalSkill = false
    @State private var isAddingCodexMCP = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let warning = model.persistenceWarning {
                    warningBanner(
                        title: "History is not being saved",
                        detail: warning
                    )
                }
                if let message = model.operationMessage,
                   model.pendingOperationPlan == nil {
                    statusBanner(message)
                }

                filters

                if let host = selectedHost {
                    TimelineView(.periodic(from: .now, by: 60)) { timeline in
                        ForEach(filteredAgents) { agent in
                            agentSection(
                                agent: agent,
                                snapshot: model.inventory(
                                    for: host,
                                    agent: agent
                                ),
                                now: timeline.date
                            )
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No host selected",
                        systemImage: "shippingbox",
                        description: Text(
                            "Select a host before checking inventory."
                        )
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Inventory")
        .searchable(
            text: $query.searchText,
            placement: .toolbar,
            prompt: "Search packages and capabilities"
        )
        .sheet(item: $evidenceSelection) {
            EvidenceInspector(selection: $0)
        }
        .sheet(isPresented: $isChoosingLocalSkill) {
            LocalSkillInstallSheet(
                availableAgents: localInstallAgents
            ) { url, agent in
                Task {
                    await model.planSkillInstall(
                        sourceDirectory: url,
                        agent: agent
                    )
                }
            }
        }
        .sheet(isPresented: $isAddingCodexMCP) {
            CodexMCPAddSheet { name, url in
                Task {
                    await model.planAddCodexHTTPServer(
                        name: name,
                        url: url
                    )
                }
            }
        }
        .fileExporter(
            isPresented: $isExportingDiagnostics,
            document: diagnosticDocument,
            contentType: .json,
            defaultFilename: "kitroom-diagnostics"
        ) { result in
            if case let .failure(error) = result {
                exportError = error.localizedDescription
            }
        }
        .alert(
            "Diagnostic export failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "The report could not be created.")
        }
    }

    private var selectedHost: ManagedHost? {
        model.selectedHost ?? model.hosts.first
    }

    private var filteredAgents: [AgentKind] {
        query.agent.map { [$0] } ?? AgentKind.allCases
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Inventory")
                        .font(.largeTitle.bold())
                    Text(
                        "Evidence-backed packages and capabilities reported by each agent."
                    )
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if selectedHost?.connection == .local {
                    Button {
                        isChoosingLocalSkill = true
                    } label: {
                        Label(
                            "Install or update skill",
                            systemImage: "plus.square.on.square"
                        )
                    }
                    .disabled(localInstallAgents.isEmpty)
                    .help(
                        localInstallAgents.isEmpty
                            ? "Run a complete local inventory scan before "
                                + "planning an install."
                            : "Choose a local skill directory and review its "
                                + "exact install or update plan."
                    )
                }

                if selectedHost?.connection == .local {
                    Button {
                        isAddingCodexMCP = true
                    } label: {
                        Label(
                            "Add MCP server",
                            systemImage: "network.badge.shield.half.filled"
                        )
                    }
                    .disabled(!model.canPlanCodexMCPAdd)
                    .help(
                        model.canPlanCodexMCPAdd
                            ? "Configure a credential-free HTTPS server "
                                + "through a reviewed Codex plan."
                            : "Run a complete local Codex inventory scan "
                                + "before planning an MCP server."
                    )
                }

                Button {
                    prepareDiagnosticExport()
                } label: {
                    Label("Export diagnostics", systemImage: "square.and.arrow.up")
                }
                .help(
                    "Exports counts, versions, statuses, and issue summaries. "
                        + "Aliases, paths, command output, and configuration values are omitted."
                )

                if let host = selectedHost,
                   model.inventoryScanningHostIDs.contains(host.id) {
                    ProgressView()
                        .controlSize(.small)
                    Button("Cancel") {
                        model.cancelInventoryScan(host)
                    }
                    .keyboardShortcut(.cancelAction)
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
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Refresh inventory (Command-R)")
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
                                "Enter an absolute path on the selected host "
                                    + "to include repository-scoped skills "
                                    + "and configuration."
                            )

                            Text(
                                "Optional absolute path on this host. "
                                    + "Kitroom inspects parent layers up to "
                                    + "the Git root."
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

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                optionalPicker(
                    title: "Agent",
                    allTitle: "All agents",
                    selection: $query.agent,
                    values: AgentKind.allCases,
                    label: \.displayName
                )
                optionalPicker(
                    title: "Kind",
                    allTitle: "All kinds",
                    selection: $query.kind,
                    values: CapabilityKind.allCases,
                    label: \.displayName
                )
                optionalPicker(
                    title: "Scope",
                    allTitle: "All scopes",
                    selection: $query.scope,
                    values: InventoryScope.allCases,
                    label: \.displayName
                )
                optionalPicker(
                    title: "Origin",
                    allTitle: "All origins",
                    selection: $query.origin,
                    values: InstallationOrigin.allCases,
                    label: \.displayName
                )
                optionalPicker(
                    title: "State",
                    allTitle: "All states",
                    selection: $query.state,
                    values: EffectiveState.allCases,
                    label: \.displayName
                )
                optionalPicker(
                    title: "Updates",
                    allTitle: "All update states",
                    selection: $query.updateStatus,
                    values: UpdateStatus.allCases,
                    label: \.displayName
                )

                if query != InventoryQuery() {
                    Button("Clear filters") {
                        query = InventoryQuery()
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inventory filters")
    }

    private func optionalPicker<Value>(
        title: String,
        allTitle: String,
        selection: Binding<Value?>,
        values: [Value],
        label: KeyPath<Value, String>
    ) -> some View where Value: Hashable {
        Picker(title, selection: selection) {
            Text(allTitle).tag(Value?.none)
            ForEach(values, id: \.self) { value in
                Text(value[keyPath: label]).tag(Optional(value))
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    @ViewBuilder
    private func agentSection(
        agent: AgentKind,
        snapshot: InventorySnapshot?,
        now: Date
    ) -> some View {
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
                    InventoryProductStatusBadge(status: snapshot?.status)
                }

                if let snapshot {
                    freshnessBanner(snapshot, now: now)
                    issues(snapshot.issues)

                    let packageRows = filteredPackages(snapshot)
                    let standaloneRows = filteredStandalone(snapshot)
                    if packageRows.isEmpty && standaloneRows.isEmpty {
                        ContentUnavailableView(
                            isFiltering
                                ? "No matching inventory"
                                : "No verified inventory",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text(
                                isFiltering
                                    ? "Adjust or clear the filters."
                                    : emptyMessage(for: snapshot)
                            )
                        )
                    } else {
                        ForEach(packageRows, id: \.package.id) { row in
                            InventoryPackageRow(
                                package: row.package,
                                capabilities: row.capabilities,
                                installations: row.installations,
                                snapshot: snapshot,
                                sources: snapshot.catalogSources,
                                evidence: snapshot.evidence,
                                capturedAt: snapshot.capturedAt,
                                selectEvidence: {
                                    evidenceSelection = $0
                                }
                            )
                        }

                        if !standaloneRows.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Directly configured")
                                    .font(.headline)
                                ForEach(standaloneRows, id: \.capability.id) { row in
                                    HStack(spacing: 12) {
                                        InventoryCapabilityButton(
                                            capability: row.capability,
                                            installation: row.installation,
                                            evidence: snapshot.evidence,
                                            capturedAt: snapshot.capturedAt
                                        ) {
                                            evidenceSelection = selection(
                                                title: row.capability.displayName,
                                                source: nil,
                                                installation: row.installation,
                                                evidenceIDs: row.capability.evidenceIDs
                                                    + (row.installation?.evidenceIDs ?? []),
                                                allEvidence: snapshot.evidence
                                            )
                                        }
                                        if let installation = row.installation,
                                           model.canPlanCodexMCPRemove(
                                               capability: row.capability,
                                               installation: installation,
                                               snapshot: snapshot
                                           ) {
                                            Button(
                                                "Plan MCP removal",
                                                role: .destructive
                                            ) {
                                                Task {
                                                    await model
                                                        .planRemoveCodexMCPServer(
                                                            capability: row.capability,
                                                            installation: installation,
                                                            snapshot: snapshot
                                                        )
                                                }
                                            }
                                            .buttonStyle(.borderless)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }

                    Divider()
                    Text(
                        "Captured "
                            + snapshot.capturedAt.formatted(
                                date: .abbreviated,
                                time: .standard
                            )
                            + " · \(snapshot.evidence.count) evidence records"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Not checked. Kitroom has not asked this agent for "
                            + "inventory on the selected host."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func freshnessBanner(
        _ snapshot: InventorySnapshot,
        now: Date
    ) -> some View {
        let freshness = InventoryFreshness.evaluate(
            capturedAt: snapshot.capturedAt,
            now: now
        )
        if freshness != .current {
            warningBanner(
                title: freshness == .stale
                    ? "This inventory is stale"
                    : "This inventory is future-dated",
                detail: freshness == .stale
                    ? "Refresh before relying on it for a decision."
                    : "Check the clocks on this Mac and the selected host."
            )
        }
    }

    @ViewBuilder
    private func issues(_ issues: [InventoryIssue]) -> some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(issues) { issue in
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
            .background(
                .orange.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }

    private func warningBanner(title: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.orange)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private func statusBanner(_ message: String) -> some View {
        Label(message, systemImage: "info.circle")
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 10)
            )
    }

    private var isFiltering: Bool {
        query != InventoryQuery()
    }

    private func emptyMessage(for snapshot: InventorySnapshot) -> String {
        snapshot.status == .complete
            ? "No packages or capabilities were reported."
            : "No verified items are available from this scan."
    }

    private func filteredPackages(
        _ snapshot: InventorySnapshot
    ) -> [InventoryPackageRowData] {
        snapshot.packages.compactMap { package in
            let installations = snapshot.installations.filter {
                $0.packageID == package.id
            }
            let packageInstallation = installations.first {
                $0.capabilityID == nil
            } ?? installations.first
            let allCapabilities = snapshot.providedCapabilities.filter {
                $0.packageID == package.id
            }
            let packageMatches = query.kind == nil
                && query.matches(
                    package: package,
                    capability: nil,
                    installation: packageInstallation
                )
            let matchingCapabilities = allCapabilities.filter { capability in
                query.matches(
                    package: package,
                    capability: capability,
                    installation: installations.first {
                        $0.capabilityID == capability.id
                    }
                )
            }
            guard packageMatches || !matchingCapabilities.isEmpty else {
                return nil
            }
            return InventoryPackageRowData(
                package: package,
                capabilities: packageMatches
                    ? allCapabilities
                    : matchingCapabilities,
                installations: installations
            )
        }
    }

    private func filteredStandalone(
        _ snapshot: InventorySnapshot
    ) -> [InventoryStandaloneRowData] {
        snapshot.providedCapabilities.compactMap { capability in
            guard capability.packageID == nil else {
                return nil
            }
            let installation = snapshot.installations.first {
                $0.capabilityID == capability.id
            }
            guard query.matches(
                package: nil,
                capability: capability,
                installation: installation
            ) else {
                return nil
            }
            return InventoryStandaloneRowData(
                capability: capability,
                installation: installation
            )
        }
    }

    private func hasAnySnapshot(for host: ManagedHost) -> Bool {
        AgentKind.allCases.contains {
            model.inventory(for: host, agent: $0) != nil
        }
    }

    private var localInstallAgents: [AgentKind] {
        AgentKind.allCases.filter {
            model.canPlanSkillInstall(agent: $0)
        }
    }

    private func prepareDiagnosticExport() {
        do {
            diagnosticDocument = DiagnosticDocument(
                data: try model.makeDiagnosticReport()
            )
            isExportingDiagnostics = true
        } catch {
            exportError = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
        }
    }
}

private struct InventoryPackageRowData {
    let package: PackageRecord
    let capabilities: [ProvidedCapability]
    let installations: [InstallationRecord]
}

private struct InventoryStandaloneRowData {
    let capability: ProvidedCapability
    let installation: InstallationRecord?
}

private struct InventoryPackageRow: View {
    @EnvironmentObject private var model: AppModel

    let package: PackageRecord
    let capabilities: [ProvidedCapability]
    let installations: [InstallationRecord]
    let snapshot: InventorySnapshot
    let sources: [CatalogSource]
    let evidence: [EvidenceRecord]
    let capturedAt: Date
    let selectEvidence: (InventoryEvidenceSelection) -> Void

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if capabilities.isEmpty {
                    Text("No components were declared or discovered.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(capabilities) { capability in
                        let installation = installations.first {
                            $0.capabilityID == capability.id
                        }
                        HStack(spacing: 12) {
                            InventoryCapabilityButton(
                                capability: capability,
                                installation: installation,
                                evidence: evidence,
                                capturedAt: capturedAt
                            ) {
                                selectEvidence(
                                    selection(
                                        title: capability.displayName,
                                        source: source,
                                        installation: installation,
                                        evidenceIDs: capability.evidenceIDs
                                            + (installation?.evidenceIDs ?? []),
                                        allEvidence: evidence
                                    )
                                )
                            }

                            if let installation,
                               model.canPlanSkillUninstall(
                                   capability: capability,
                                   installation: installation,
                                   snapshot: snapshot
                               ) {
                                Button(
                                    "Plan uninstall",
                                    role: .destructive
                                ) {
                                    Task {
                                        await model.planSkillUninstall(
                                            capability: capability,
                                            installation: installation,
                                            snapshot: snapshot
                                        )
                                    }
                                }
                                .buttonStyle(.borderless)
                                .help(
                                    "Review an exact-target backup, uninstall, "
                                        + "and verification plan."
                                )
                            }
                        }
                    }
                }

                Button {
                    selectEvidence(
                        selection(
                            title: package.displayName,
                            source: source,
                            installation: packageInstallation,
                            evidenceIDs: package.evidenceIDs
                                + (packageInstallation?.evidenceIDs ?? []),
                            allEvidence: evidence
                        )
                    )
                } label: {
                    Label("Show package evidence", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.link)

                if let packageInstallation,
                   let source,
                   let action = model.claudePluginToggleAction(
                       package: package,
                       installation: packageInstallation,
                       source: source,
                       snapshot: snapshot
                   ) {
                    Button(
                        action == .enable
                            ? "Plan enable"
                            : "Plan disable"
                    ) {
                        Task {
                            await model.planClaudePluginToggle(
                                package: package,
                                installation: packageInstallation,
                                source: source,
                                snapshot: snapshot
                            )
                        }
                    }
                    .help(
                        "Review the exact native Claude Code command, "
                        + "configuration backup, rollback, and verification."
                    )
                }

                if let packageInstallation,
                   let source,
                   model.canPlanPluginUninstall(
                       package: package,
                       installation: packageInstallation,
                       source: source,
                       snapshot: snapshot
                   ) {
                    Button("Plan plugin uninstall", role: .destructive) {
                        Task {
                            await model.planPluginUninstall(
                                package: package,
                                installation: packageInstallation,
                                source: source,
                                snapshot: snapshot
                            )
                        }
                    }
                    .help(
                        "Review the native uninstall command, exact "
                            + "configuration backup, rollback, and verification."
                    )
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
                InventoryProductMetadataLine(
                    installation: packageInstallation,
                    evidenceStatus: inventoryEvidenceStatus(
                        ids: package.evidenceIDs
                            + (packageInstallation?.evidenceIDs ?? []),
                        evidence: evidence
                    ),
                    capturedAt: capturedAt
                )
            }
        }
        .padding(12)
        .background(
            .secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(package.displayName)
    }

    private var packageInstallation: InstallationRecord? {
        installations.first { $0.capabilityID == nil }
            ?? installations.first
    }

    private var source: CatalogSource? {
        guard let sourceID = package.sourceID else {
            return nil
        }
        return sources.first { $0.id == sourceID }
    }
}

private struct InventoryCapabilityButton: View {
    let capability: ProvidedCapability
    let installation: InstallationRecord?
    let evidence: [EvidenceRecord]
    let capturedAt: Date
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(capability.displayName)
                        Spacer()
                        Text(capability.kind.displayName)
                            .foregroundStyle(.secondary)
                    }
                    InventoryProductMetadataLine(
                        installation: installation,
                        evidenceStatus: status,
                        capturedAt: capturedAt
                    )
                }
            } icon: {
                Image(systemName: capability.kind.systemImage)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibility.label)
        .accessibilityValue(accessibility.value)
        .accessibilityHint(accessibility.hint)
    }

    private var status: EvidenceStatus? {
        inventoryEvidenceStatus(
            ids: capability.evidenceIDs
                + (installation?.evidenceIDs ?? []),
            evidence: evidence
        )
    }

    private var accessibility: InventoryAccessibilityDescription {
        InventoryAccessibilityDescription(
            package: nil,
            capability: capability,
            installation: installation,
            evidenceStatus: status
        )
    }
}

private struct InventoryProductMetadataLine: View {
    let installation: InstallationRecord?
    let evidenceStatus: EvidenceStatus?
    let capturedAt: Date

    var body: some View {
        HStack(spacing: 8) {
            if let installation {
                Text(installation.scope.displayName)
                Text(installation.origin.displayName)
                Text(installation.state.displayName)
                Text((installation.updateStatus ?? .unknown).displayName)
            } else {
                Text("Scope unknown")
                Text("Origin unknown")
                Text("State unknown")
                Text("Update unknown")
            }
            Text("Evidence \(evidenceStatus?.displayName ?? "unknown")")
            Text(capturedAt, style: .relative)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct InventoryProductStatusBadge: View {
    let status: InventoryStatus?

    var body: some View {
        Text(status?.displayName ?? "Not checked")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.secondary.opacity(0.1), in: Capsule())
    }
}

private struct InventoryEvidenceSelection: Identifiable {
    let id = UUID()
    let title: String
    let source: CatalogSource?
    let installation: InstallationRecord?
    let evidence: [EvidenceRecord]
}

private struct EvidenceInspector: View {
    @Environment(\.dismiss) private var dismiss
    let selection: InventoryEvidenceSelection

    var body: some View {
        NavigationStack {
            List {
                Section("Inventory item") {
                    LabeledContent("Name", value: selection.title)
                    LabeledContent(
                        "Scope",
                        value: selection.installation?.scope.displayName
                            ?? "Unknown"
                    )
                    LabeledContent(
                        "Origin",
                        value: selection.installation?.origin.displayName
                            ?? "Unknown"
                    )
                    LabeledContent(
                        "State",
                        value: selection.installation?.state.displayName
                            ?? "Unknown"
                    )
                    if let path = selection.installation?.physicalOrigin {
                        LabeledContent("Location") {
                            Text(path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                if let source = selection.source {
                    Section("Source") {
                        LabeledContent("Name", value: source.name)
                        LabeledContent("Kind", value: source.kind.rawValue)
                        if let reference = source.reference {
                            LabeledContent("Reference") {
                                Text(reference)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        if let revision = source.revision {
                            LabeledContent("Revision", value: revision)
                        }
                    }
                }

                Section("Evidence") {
                    if selection.evidence.isEmpty {
                        Text(
                            "No linked evidence record was retained for this item."
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(selection.evidence) { evidence in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(evidence.probeName)
                                        .font(.headline)
                                    Spacer()
                                    Text(evidence.status.displayName)
                                        .foregroundStyle(.secondary)
                                }
                                Text(evidence.sourceReference)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Text(
                                    "Parser \(evidence.parserVersion) · "
                                        + evidence.capturedAt.formatted(
                                            date: .abbreviated,
                                            time: .standard
                                        )
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                if let diagnostic = evidence.diagnostic {
                                    Text(diagnostic)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Source and evidence")
            .toolbar {
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}

private struct DiagnosticDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(
        configuration: WriteConfiguration
    ) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private func selection(
    title: String,
    source: CatalogSource?,
    installation: InstallationRecord?,
    evidenceIDs: [EvidenceRecord.ID],
    allEvidence: [EvidenceRecord]
) -> InventoryEvidenceSelection {
    InventoryEvidenceSelection(
        title: title,
        source: source,
        installation: installation,
        evidence: allEvidence.filter { evidenceIDs.contains($0.id) }
    )
}

private func inventoryEvidenceStatus(
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
    static var allCases: [EffectiveState] {
        [
            .configured,
            .enabled,
            .disabled,
            .pendingApproval,
            .unavailable,
            .unhealthy,
            .unknown
        ]
    }

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
    static var allCases: [InventoryScope] {
        [.user, .repository, .localProject, .managed, .system, .session, .unknown]
    }

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
    static var allCases: [InstallationOrigin] {
        [
            .standalone,
            .marketplace,
            .pluginProvided,
            .shared,
            .legacy,
            .runtimeInjected,
            .bundled,
            .unknown
        ]
    }

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
            "Verified"
        case .partial:
            "Partial"
        case .failure:
            "Failed"
        }
    }
}

private extension CapabilityKind {
    static var allCases: [CapabilityKind] {
        [
            .skill,
            .mcpServer,
            .hook,
            .subagent,
            .connector,
            .lspServer,
            .command,
            .executable,
            .other
        ]
    }

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

private extension UpdateStatus {
    var displayName: String {
        switch self {
        case .notInstalled:
            "Not installed"
        case .upToDate:
            "Up to date"
        case .updateAvailable:
            "Update available"
        case .unknown:
            "Update unknown"
        case .incomparable:
            "Not comparable"
        }
    }
}
