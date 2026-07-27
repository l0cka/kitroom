import KitroomCore
import SwiftUI

struct CatalogueProductView: View {
    @EnvironmentObject private var model: AppModel

    @State private var mode = CatalogueMode.browse
    @State private var searchText = ""
    @State private var selectedAgent: AgentKind?
    @State private var leftHostID: ManagedHost.ID?
    @State private var rightHostID: ManagedHost.ID?
    @State private var showMatches = false
    @State private var sourceTrustConfirmation: SourceTrustConfirmation?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            switch mode {
            case .browse:
                browseContent
            case .compare:
                comparisonContent
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Catalogue")
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: mode == .browse
                ? "Search native catalogues"
                : "Search host differences"
        )
        .task {
            initializeComparisonHosts()
        }
        .alert(item: $sourceTrustConfirmation) { confirmation in
            let reference = (
                try? PackageSourceTrustPolicy.validatedReference(
                    for: confirmation.source
                )
            ) ?? "Unavailable"
            return Alert(
                title: Text(
                    confirmation.approve
                        ? "Allow this package source?"
                        : "Remove this source allowance?"
                ),
                message: Text(
                    confirmation.approve
                        ? "Future install and update plans may introduce digest-backed code from this exact source. Every package operation still requires its own review and approval."
                            + "\n\nExact source reference:\n"
                            + reference
                        : "This blocks future install and update plans from this source. Installed packages are not changed."
                            + "\n\nExact source reference:\n"
                            + reference
                ),
                primaryButton: confirmation.approve
                    ? .default(Text("Allow source")) {
                        Task {
                            await model.approvePackageSource(
                                confirmation.source
                            )
                        }
                    }
                    : .destructive(Text("Remove allowance")) {
                        Task {
                            await model.revokePackageSource(
                                confirmation.source
                            )
                        }
                    },
                secondaryButton: .cancel()
            )
        }
    }

    private var selectedHost: ManagedHost? {
        model.selectedHost ?? model.hosts.first
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Catalogue")
                        .font(.largeTitle.bold())
                    Text(
                        "Browse agent-native marketplaces and compare "
                            + "installed state between hosts."
                    )
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if mode == .browse, let host = selectedHost {
                    if model.catalogueScanningHostIDs.contains(host.id) {
                        ProgressView()
                            .controlSize(.small)
                        Button("Cancel") {
                            model.cancelCatalogueScan(host)
                        }
                        .keyboardShortcut(.cancelAction)
                    } else {
                        Button {
                            model.scanCatalogue(host)
                        } label: {
                            Label(
                                hasCatalogue(for: host)
                                    ? "Refresh catalogues"
                                    : "Check catalogues",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .keyboardShortcut("r", modifiers: .command)
                    }
                }
            }

            Picker("Catalogue mode", selection: $mode) {
                ForEach(CatalogueMode.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            if mode == .browse {
                Text(
                    "Refreshing reads marketplace metadata. It does not "
                        + "update, install, enable, or remove any package."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let message = model.operationMessage,
               model.pendingOperationPlan == nil {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        .secondary.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
            }
        }
    }

    private var browseContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                browseFilters

                if let host = selectedHost {
                    ForEach(browseAgents) { agent in
                        catalogueSection(
                            agent: agent,
                            snapshot: model.catalogue(for: host, agent: agent)
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "No host selected",
                        systemImage: "books.vertical",
                        description: Text(
                            "Select a host before checking native catalogues."
                        )
                    )
                }
            }
            .padding(28)
        }
    }

    private var browseFilters: some View {
        HStack(spacing: 16) {
            if !model.hosts.isEmpty {
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
            }

            Picker("Agent", selection: $selectedAgent) {
                Text("All agents").tag(AgentKind?.none)
                ForEach(AgentKind.allCases) { agent in
                    Text(agent.displayName).tag(Optional(agent))
                }
            }
            .pickerStyle(.menu)
            Spacer()
        }
    }

    private var browseAgents: [AgentKind] {
        selectedAgent.map { [$0] } ?? AgentKind.allCases
    }

    @ViewBuilder
    private func catalogueSection(
        agent: AgentKind,
        snapshot: CatalogueSnapshot?
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
                    Text(snapshot?.status.displayName ?? "Not checked")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.secondary.opacity(0.1), in: Capsule())
                }

                if let snapshot {
                    catalogueFreshness(snapshot)
                    catalogueIssues(snapshot.issues)
                    sourceStrip(snapshot.sources)

                    let packages = filteredPackages(snapshot)
                    if packages.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty
                                ? "No marketplace packages reported"
                                : "No matching packages",
                            systemImage: "books.vertical",
                            description: Text(
                                searchText.isEmpty
                                    ? "The selected agent returned no native "
                                        + "catalogue entries."
                                    : "Try a different search."
                            )
                        )
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(packages) { package in
                                CataloguePackageRow(
                                    package: package,
                                    state: snapshot.packageStates.first {
                                        $0.packageID == package.id
                                    },
                                    source: package.sourceID.flatMap { sourceID in
                                        snapshot.sources.first {
                                            $0.id == sourceID
                                        }
                                    },
                                    capabilities: snapshot.providedCapabilities
                                        .filter { $0.packageID == package.id },
                                    evidence: snapshot.evidence,
                                    catalogue: snapshot
                                )
                            }
                        }
                    }

                    Text(
                        "Captured "
                            + snapshot.capturedAt.formatted(
                                date: .abbreviated,
                                time: .standard
                            )
                            + " · \(snapshot.packages.count) packages · "
                            + "\(snapshot.sources.count) sources"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text(
                        "Not checked. Kitroom has not asked this agent for "
                            + "its native marketplace catalogue on this host."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func catalogueFreshness(_ snapshot: CatalogueSnapshot) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let freshness = InventoryFreshness.evaluate(
                capturedAt: snapshot.capturedAt,
                now: timeline.date
            )
            if freshness != .current {
                Label(
                    freshness == .stale
                        ? "Marketplace metadata is stale. Refresh before "
                            + "relying on versions or availability."
                        : "Marketplace metadata is future-dated. Check host clocks.",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .orange.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        }
    }

    @ViewBuilder
    private func catalogueIssues(_ issues: [InventoryIssue]) -> some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
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
            .padding(10)
            .background(
                .orange.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }

    private func sourceStrip(_ sources: [CatalogSource]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(sources) { source in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name)
                            .font(.callout.weight(.medium))
                        Text(source.kind.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let reference = try? PackageSourceTrustPolicy
                            .validatedReference(for: source) {
                            Text(reference)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                                .accessibilityLabel(
                                    "Exact source reference: \(reference)"
                                )
                        }
                        if let revision = source.revision {
                            Text(revision)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Label(
                            model.isPackageSourceApproved(source)
                                ? "Allowed for changes"
                                : "Read-only source",
                            systemImage: model.isPackageSourceApproved(source)
                                ? "checkmark.shield"
                                : "eye"
                        )
                        .font(.caption2)
                        .foregroundStyle(
                            model.isPackageSourceApproved(source)
                                ? .green
                                : .secondary
                        )
                        Button(
                            model.isPackageSourceApproved(source)
                                ? "Remove allowance…"
                                : "Allow for changes…"
                        ) {
                            sourceTrustConfirmation = SourceTrustConfirmation(
                                source: source,
                                approve: !model.isPackageSourceApproved(source)
                            )
                        }
                        .buttonStyle(.borderless)
                        .disabled(
                            (try? PackageSourceTrustPolicy
                                .validatedReference(for: source)) == nil
                        )
                    }
                    .padding(10)
                    .background(
                        .secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func filteredPackages(
        _ snapshot: CatalogueSnapshot
    ) -> [PackageRecord] {
        let needle = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !needle.isEmpty else {
            return snapshot.packages.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }
        }
        return snapshot.packages.filter { package in
            let source = package.sourceID.flatMap { sourceID in
                snapshot.sources.first { $0.id == sourceID }
            }
            let values = [
                package.name,
                package.displayName,
                package.publisher,
                package.description,
                package.repository,
                source?.name
            ]
            .compactMap { $0 }
            .joined(separator: " ")
            return values.localizedCaseInsensitiveContains(needle)
        }
        .sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                == .orderedAscending
        }
    }

    private var comparisonContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                comparisonControls

                if model.hosts.count < 2 {
                    ContentUnavailableView(
                        "Two hosts are required",
                        systemImage: "arrow.left.arrow.right",
                        description: Text(
                            "Add and inventory another host before comparing state."
                        )
                    )
                } else if let leftHost, let rightHost {
                    let items = filteredComparison(
                        model.comparison(
                            leftHost: leftHost,
                            rightHost: rightHost
                        )
                    )
                    if !hasInventory(for: leftHost)
                        || !hasInventory(for: rightHost) {
                        Label(
                            "One or both hosts have not been inventoried. "
                                + "Comparison is incomplete.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                        .padding(12)
                        .background(
                            .orange.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }

                    if items.isEmpty {
                        ContentUnavailableView(
                            showMatches
                                ? "No comparable items"
                                : "No differences found",
                            systemImage: "checkmark.circle",
                            description: Text(
                                showMatches
                                    ? "Inventory both hosts or adjust the search."
                                    : "Matching items are hidden."
                            )
                        )
                    } else {
                        ForEach(items) { item in
                            ComparisonRow(
                                item: item,
                                leftName: leftHost.name,
                                rightName: rightHost.name
                            )
                        }
                    }
                }
            }
            .padding(28)
        }
    }

    private var comparisonControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                hostPicker("Left host", selection: $leftHostID)
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                hostPicker("Right host", selection: $rightHostID)
                Spacer()
                Toggle("Show matches", isOn: $showMatches)
                    .toggleStyle(.switch)
                    .fixedSize()
            }

            HStack {
                Text(
                    "Comparison is read-only and uses the latest retained "
                        + "inventory for each host."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Button("Open Inventory") {
                    model.selectedSection = .inventory
                }
            }
        }
    }

    private func hostPicker(
        _ title: String,
        selection: Binding<ManagedHost.ID?>
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Choose host").tag(ManagedHost.ID?.none)
            ForEach(model.hosts) { host in
                Text(host.name).tag(Optional(host.id))
            }
        }
        .pickerStyle(.menu)
        .frame(minWidth: 180)
    }

    private var leftHost: ManagedHost? {
        model.hosts.first { $0.id == leftHostID }
    }

    private var rightHost: ManagedHost? {
        model.hosts.first { $0.id == rightHostID }
    }

    private func initializeComparisonHosts() {
        if leftHostID == nil {
            leftHostID = model.hosts.first?.id
        }
        if rightHostID == nil {
            rightHostID = model.hosts.dropFirst().first?.id
        }
    }

    private func filteredComparison(
        _ items: [HostComparisonItem]
    ) -> [HostComparisonItem] {
        let needle = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return items.filter { item in
            let matchVisibility = showMatches
                || item.findings != [.matching]
            let searchMatches = needle.isEmpty
                || item.name.localizedCaseInsensitiveContains(needle)
                || item.agent.displayName
                    .localizedCaseInsensitiveContains(needle)
            return matchVisibility && searchMatches
        }
    }

    private func hasCatalogue(for host: ManagedHost) -> Bool {
        AgentKind.allCases.contains {
            model.catalogue(for: host, agent: $0) != nil
        }
    }

    private func hasInventory(for host: ManagedHost) -> Bool {
        AgentKind.allCases.contains {
            model.inventory(for: host, agent: $0) != nil
        }
    }
}

private enum CatalogueMode: String, CaseIterable, Identifiable {
    case browse
    case compare

    var id: Self { self }

    var title: String {
        switch self {
        case .browse:
            "Browse"
        case .compare:
            "Compare hosts"
        }
    }
}

private struct CataloguePackageRow: View {
    @EnvironmentObject private var model: AppModel

    let package: PackageRecord
    let state: CataloguePackageState?
    let source: CatalogSource?
    let capabilities: [ProvidedCapability]
    let evidence: [EvidenceRecord]
    let catalogue: CatalogueSnapshot

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if let description = package.description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("Marketplace")
                        Text(source?.name ?? "Unknown")
                    }
                    GridRow {
                        Text("Publisher")
                        Text(package.publisher ?? "Not declared")
                    }
                    GridRow {
                        Text("Repository")
                        Text(package.repository ?? "Not declared")
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Compatibility")
                        Text(state?.compatibility.displayName ?? "Unknown")
                    }
                    GridRow {
                        Text("Management")
                        Text(state?.restriction.displayName ?? "Unknown")
                    }
                    GridRow {
                        Text("Integrity")
                        Text(state?.integrity.displayName ?? "Unknown")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()
                Text("Declared components")
                    .font(.callout.weight(.semibold))
                if capabilities.isEmpty {
                    Text(
                        "Components were not reported by the marketplace or "
                            + "could not be inspected from its local snapshot."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(capabilities) { capability in
                        Label(
                            "\(capability.displayName) · "
                                + capability.kind.displayName,
                            systemImage: capability.kind.systemImage
                        )
                        .font(.caption)
                    }
                }

                let linkedEvidence = evidence.filter {
                    package.evidenceIDs.contains($0.id)
                        || (state?.evidenceIDs.contains($0.id) ?? false)
                }
                if !linkedEvidence.isEmpty {
                    Divider()
                    ForEach(linkedEvidence) { record in
                        Label(
                            "\(record.probeName) · \(record.status.displayName)",
                            systemImage: "doc.text.magnifyingglass"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if let source,
                   let action = model.cataloguePluginAction(
                       package: package,
                       state: state,
                       source: source,
                       catalogue: catalogue
                   ) {
                    Divider()
                    Button(action.catalogueButtonTitle) {
                        Task {
                            await model.planCataloguePluginAction(
                                package: package,
                                state: state,
                                source: source,
                                catalogue: catalogue
                            )
                        }
                    }
                    .help(
                        "Review the exact native command, configuration "
                            + "backup, rollback limits, and fresh verification."
                    )
                } else if let source,
                          let updateStatus = state?.updateStatus,
                          updateStatus == .notInstalled
                            || updateStatus == .updateAvailable {
                    Divider()
                    if !model.isPackageSourceApproved(source) {
                        Label(
                            "Install and update are blocked until this exact source is allowed.",
                            systemImage: "lock.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    } else if !model.packageHasRequiredIntegrity(
                        package: package,
                        state: state,
                        source: source
                    ) {
                        Label(
                            "Install and update are blocked because no package digest evidence was reported.",
                            systemImage: "exclamationmark.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(package.displayName)
                        .font(.headline)
                    Text(source?.name ?? "Source unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(state?.updateStatus.displayName ?? "Update unknown")
                        .font(.caption.weight(.medium))
                    Text(versionSummary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            .secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(package.displayName)
        .accessibilityValue(
            "\(state?.updateStatus.displayName ?? "Update unknown"), "
                + versionSummary
        )
    }

    private var versionSummary: String {
        let installed = state?.installedVersion ?? "not installed"
        let available: String
        if let state {
            available = state.availableVersion ?? "not reported"
        } else {
            available = package.version ?? "unknown"
        }
        return "\(installed) → \(available)"
    }
}

private struct SourceTrustConfirmation: Identifiable {
    let source: CatalogSource
    let approve: Bool

    var id: String {
        "\(source.id):\(approve)"
    }
}

private struct ComparisonRow: View {
    let item: HostComparisonItem
    let leftName: String
    let rightName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    item.name,
                    systemImage: item.entityKind == .package
                        ? "shippingbox"
                        : "puzzlepiece.extension"
                )
                .font(.headline)
                Spacer()
                Text(item.agent.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(item.findings, id: \.self) { finding in
                    Text(finding.displayName)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            finding == .matching
                                ? Color.green.opacity(0.1)
                                : Color.orange.opacity(0.1),
                            in: Capsule()
                        )
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                GridRow {
                    Text(leftName)
                        .font(.caption.weight(.semibold))
                    Text(item.leftSummary ?? "Not present or unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    Text(rightName)
                        .font(.caption.weight(.semibold))
                    Text(item.rightSummary ?? "Not present or unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor))
        }
        .accessibilityElement(children: .combine)
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

private extension PackageSourceKind {
    var displayName: String {
        switch self {
        case .marketplace:
            "Marketplace"
        case .local:
            "Local"
        case .git:
            "Git"
        case .url:
            "URL"
        case .bundled:
            "Bundled"
        case .managed:
            "Managed"
        case .unknown:
            "Unknown"
        }
    }
}

private extension CatalogueCompatibility {
    var displayName: String {
        switch self {
        case .compatible:
            "Compatible"
        case .incompatible:
            "Incompatible"
        case .unknown:
            "Unknown"
        }
    }
}

private extension CatalogueIntegrity {
    var displayName: String {
        switch self {
        case .digestVerified:
            "Digest verified"
        case .digestDeclared:
            "Digest declared"
        case .unverified:
            "Unverified"
        case .unknown:
            "Unknown"
        }
    }
}

private extension ManagementRestriction {
    var displayName: String {
        switch self {
        case .userManaged:
            "User managed"
        case .agentManaged:
            "Agent managed"
        case .administratorManaged:
            "Administrator managed"
        case .readOnly:
            "Read-only"
        case .unknown:
            "Unknown"
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

private extension NativePluginAction {
    var catalogueButtonTitle: String {
        switch self {
        case .install:
            "Plan install"
        case .update:
            "Plan update"
        case .enable:
            "Plan enable"
        case .disable:
            "Plan disable"
        case .uninstall:
            "Plan uninstall"
        }
    }
}

private extension ComparisonFindingKind {
    var displayName: String {
        switch self {
        case .onlyOnLeft:
            "Only on left"
        case .onlyOnRight:
            "Only on right"
        case .versionMismatch:
            "Version mismatch"
        case .enabledStateMismatch:
            "State mismatch"
        case .sourceMismatch:
            "Source mismatch"
        case .digestMismatch:
            "Digest mismatch"
        case .matching:
            "Matches"
        case .incomparable:
            "Not comparable"
        case .unknown:
            "Unknown"
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
    var displayName: String {
        rawValue
            .replacingOccurrences(
                of: "([a-z])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .capitalized
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
