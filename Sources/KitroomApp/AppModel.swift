import Foundation
import KitroomCore

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection? = .hosts
    @Published var selectedHostID: ManagedHost.ID?

    @Published private(set) var hosts: [ManagedHost]
    @Published private(set) var discoveryByHost: [ManagedHost.ID: HostDiscoverySnapshot] = [:]
    @Published private(set) var discoveryHistory: [HostDiscoverySnapshot] = []
    @Published private(set) var resolvedHostByID: [ManagedHost.ID: String] = [:]
    @Published private(set) var inventoryByKey: [InventoryKey: InventorySnapshot] = [:]
    @Published private(set) var inventoryScanningHostIDs: Set<ManagedHost.ID> = []
    @Published private(set) var catalogueByKey: [InventoryKey: CatalogueSnapshot] = [:]
    @Published private(set) var catalogueScanningHostIDs: Set<ManagedHost.ID> = []
    @Published private(set) var operationRecords: [OperationRecord] = []
    @Published var pendingOperationPlan: OperationPlan?
    @Published private(set) var applyingOperationIDs: Set<OperationPlan.ID> = []
    @Published var operationMessage: String?
    @Published var projectDirectoryByHost: [ManagedHost.ID: String] = [:]
    @Published private(set) var persistenceWarning: String?

    let dependencies: AppDependencies

    private var hasStarted = false
    private var scanTasks: [ManagedHost.ID: Task<Void, Never>] = [:]
    private var inventoryTasks: [ManagedHost.ID: Task<Void, Never>] = [:]
    private var catalogueTasks: [ManagedHost.ID: Task<Void, Never>] = [:]

    init(
        hosts: [ManagedHost] = [ManagedHost(name: "This Mac", connection: .local)],
        dependencies: AppDependencies = .live()
    ) {
        self.hosts = hosts
        self.dependencies = dependencies
        persistenceWarning = dependencies.persistenceIssue
        selectedHostID = hosts.first?.id
    }

    var selectedHost: ManagedHost? {
        hosts.first { $0.id == selectedHostID }
    }

    var remoteHostCount: Int {
        hosts.filter(\.connection.isRemote).count
    }

    func discovery(for host: ManagedHost) -> HostDiscoverySnapshot? {
        discoveryByHost[host.id]
    }

    func lastSuccessfulDiscovery(for host: ManagedHost) -> Date? {
        discoveryHistory
            .filter {
                $0.hostID == host.id
                    && $0.connectionState == .reachable
                    && $0.completedAt != nil
            }
            .compactMap(\.completedAt)
            .max()
    }

    func inventory(
        for host: ManagedHost,
        agent: AgentKind
    ) -> InventorySnapshot? {
        let key = InventoryKey(hostID: host.id, agent: agent)
        return inventoryByKey[key]?.annotated(with: catalogueByKey[key])
    }

    func catalogue(
        for host: ManagedHost,
        agent: AgentKind
    ) -> CatalogueSnapshot? {
        catalogueByKey[InventoryKey(hostID: host.id, agent: agent)]
    }

    func projectDirectory(for host: ManagedHost) -> String {
        projectDirectoryByHost[host.id] ?? ""
    }

    func setProjectDirectory(_ value: String, for host: ManagedHost) {
        projectDirectoryByHost[host.id] = value
    }

    func start() async {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        dependencies.logger.record(
            KitroomLogEvent(
                level: .info,
                category: "lifecycle",
                name: "app-started",
                publicMetadata: ["hostCount": String(hosts.count)]
            )
        )

        do {
            let persistedHosts = try await dependencies.persistence.loadHosts()

            if persistedHosts.isEmpty {
                try await dependencies.persistence.saveHosts(hosts)
            } else {
                hosts = persistedHosts
                selectedHostID = persistedHosts.first?.id
            }

            let persistedSnapshots = try await dependencies.persistence
                .loadInventorySnapshots()
            inventoryByKey = Dictionary(
                uniqueKeysWithValues: persistedSnapshots.map {
                    (
                        InventoryKey(hostID: $0.hostID, agent: $0.agent),
                        $0
                    )
                }
            )
            let persistedCatalogues = try await dependencies.persistence
                .loadCatalogueSnapshots()
            catalogueByKey = Dictionary(
                uniqueKeysWithValues: persistedCatalogues.map {
                    (
                        InventoryKey(hostID: $0.hostID, agent: $0.agent),
                        $0
                    )
                }
            )
            operationRecords = try await dependencies.persistence
                .loadOperationRecords(limit: 200)

            discoveryHistory = try await dependencies.persistence
                .loadHostDiscoveryHistory(hostID: nil, limit: 500)
            let latestDiscovery = try await dependencies.persistence
                .loadHostDiscoverySnapshots()
            discoveryByHost = Dictionary(
                uniqueKeysWithValues: latestDiscovery.map {
                    ($0.hostID, $0)
                }
            )
            resolvedHostByID = Dictionary(
                uniqueKeysWithValues: latestDiscovery.compactMap {
                    guard let resolvedHost = $0.resolvedHost else {
                        return nil
                    }
                    return ($0.hostID, resolvedHost)
                }
            )
        } catch {
            persistenceWarning = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
            dependencies.logger.record(
                KitroomLogEvent(
                    level: .error,
                    category: "persistence",
                    name: "host-load-failed",
                    privateContext: String(describing: error)
                )
            )
        }
    }

    func addRemoteHost(name: String, alias: String) async throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedName.isEmpty else {
            throw HostSetupError.missingName
        }
        guard HostAliasValidator.isValid(normalizedAlias) else {
            throw HostSetupError.invalidAlias
        }
        guard !hosts.contains(where: {
            if case let .ssh(existingAlias) = $0.connection {
                existingAlias == normalizedAlias
            } else {
                false
            }
        }) else {
            throw HostSetupError.duplicateAlias
        }

        let summary = try await dependencies.sshConfigurationResolver.resolve(
            alias: normalizedAlias
        )
        let host = ManagedHost(
            name: normalizedName,
            connection: .ssh(alias: normalizedAlias)
        )

        hosts.append(host)
        resolvedHostByID[host.id] = summary.resolvedDescription
        selectedHostID = host.id
        try await dependencies.persistence.saveHosts(hosts)

        dependencies.logger.record(
            KitroomLogEvent(
                level: .notice,
                category: "hosts",
                name: "remote-host-added",
                publicMetadata: ["hostID": host.id.uuidString],
                privateContext: summary.resolvedDescription
            )
        )
    }

    func scan(_ host: ManagedHost) {
        guard scanTasks[host.id] == nil else {
            return
        }

        discoveryByHost[host.id] = HostDiscoverySnapshot(
            hostID: host.id,
            attemptedAt: dependencies.clock.now,
            connectionState: .connecting,
            resolvedHost: resolvedHostByID[host.id]
        )

        scanTasks[host.id] = Task { [weak self] in
            guard let self else {
                return
            }

            var resolvedHost = resolvedHostByID[host.id]
            if case let .ssh(alias) = host.connection, resolvedHost == nil {
                resolvedHost = try? await dependencies.sshConfigurationResolver
                    .resolve(alias: alias)
                    .resolvedDescription
            }

            let snapshot = await dependencies.hostDiscovery.discover(
                host: host,
                resolvedHost: resolvedHost
            )
            guard !Task.isCancelled else {
                let cancelled = HostDiscoverySnapshot(
                    hostID: host.id,
                    attemptedAt: snapshot.attemptedAt,
                    completedAt: dependencies.clock.now,
                    connectionState: .cancelled,
                    resolvedHost: resolvedHost,
                    issues: [
                        InventoryIssue(
                            summary: "Host discovery cancelled",
                            detail: "No inventory result was recorded."
                        )
                    ]
                )
                discoveryByHost[host.id] = cancelled
                discoveryHistory.append(cancelled)
                try? await dependencies.persistence
                    .saveHostDiscoverySnapshot(cancelled)
                scanTasks[host.id] = nil
                return
            }

            if let resolvedHost {
                resolvedHostByID[host.id] = resolvedHost
            }
            discoveryByHost[host.id] = snapshot
            discoveryHistory.append(snapshot)
            do {
                try await dependencies.persistence
                    .saveHostDiscoverySnapshot(snapshot)
            } catch {
                persistenceWarning = SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            }
            scanTasks[host.id] = nil

            dependencies.logger.record(
                KitroomLogEvent(
                    level: snapshot.connectionState == .reachable ? .info : .notice,
                    category: "hosts",
                    name: "host-discovery-finished",
                    publicMetadata: [
                        "hostID": host.id.uuidString,
                        "state": snapshot.connectionState.rawValue
                    ],
                    privateContext: snapshot.issues.first?.detail
                )
            )
        }
    }

    func cancelScan(_ host: ManagedHost) {
        scanTasks[host.id]?.cancel()
    }

    func scanInventory(_ host: ManagedHost) {
        guard inventoryTasks[host.id] == nil else {
            return
        }

        inventoryScanningHostIDs.insert(host.id)
        inventoryTasks[host.id] = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                let session = try await dependencies.hostConnectionFactory
                    .connect(to: host)
                let context = InventoryContext(
                    workingDirectory: projectDirectory(for: host)
                )

                for agent in dependencies.adapterRegistry.supportedAgents {
                    guard !Task.isCancelled,
                          let adapter = dependencies.adapterRegistry.adapter(for: agent)
                    else {
                        break
                    }

                    let snapshot = try await adapter.inspect(
                        context: context,
                        using: session
                    )
                    guard !Task.isCancelled else {
                        break
                    }
                    inventoryByKey[
                        InventoryKey(hostID: host.id, agent: agent)
                    ] = snapshot
                    do {
                        try await dependencies.persistence.saveInventorySnapshot(
                            snapshot
                        )
                    } catch {
                        persistenceWarning = SensitiveValueRedactor.redact(
                            error.localizedDescription
                        )
                    }
                }
            } catch is CancellationError {
                // Cancellation preserves the last completed snapshots.
            } catch {
                let detail = SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
                for agent in dependencies.adapterRegistry.supportedAgents {
                    let snapshot = InventorySnapshot(
                        hostID: host.id,
                        agent: agent,
                        capturedAt: dependencies.clock.now,
                        status: .unavailable,
                        issues: [
                            InventoryIssue(
                                summary: "Inventory scan failed",
                                detail: detail
                            )
                        ]
                    )
                    inventoryByKey[
                        InventoryKey(hostID: host.id, agent: agent)
                    ] = snapshot
                    try? await dependencies.persistence
                        .saveInventorySnapshot(snapshot)
                }
            }

            inventoryScanningHostIDs.remove(host.id)
            inventoryTasks[host.id] = nil
        }
    }

    func cancelInventoryScan(_ host: ManagedHost) {
        inventoryTasks[host.id]?.cancel()
    }

    func scanCatalogue(_ host: ManagedHost) {
        guard catalogueTasks[host.id] == nil else {
            return
        }
        catalogueScanningHostIDs.insert(host.id)
        catalogueTasks[host.id] = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                catalogueScanningHostIDs.remove(host.id)
                catalogueTasks[host.id] = nil
            }

            do {
                let session = try await dependencies.hostConnectionFactory
                    .connect(to: host)
                for agent in dependencies.adapterRegistry.supportedAgents {
                    guard !Task.isCancelled,
                          let adapter = dependencies.adapterRegistry.adapter(
                            for: agent
                          )
                    else {
                        break
                    }
                    let key = InventoryKey(hostID: host.id, agent: agent)
                    do {
                        let snapshot = try await adapter.inspectCatalogue(
                            installed: inventoryByKey[key],
                            using: session
                        )
                        guard !Task.isCancelled else {
                            break
                        }
                        catalogueByKey[key] = snapshot
                        try await dependencies.persistence
                            .saveCatalogueSnapshot(snapshot)
                    } catch is CancellationError {
                        break
                    } catch {
                        let snapshot = CatalogueSnapshot(
                            hostID: host.id,
                            agent: agent,
                            capturedAt: dependencies.clock.now,
                            status: .unavailable,
                            evidence: [],
                            issues: [
                                InventoryIssue(
                                    summary: "Catalogue refresh failed",
                                    detail: SensitiveValueRedactor.redact(
                                        error.localizedDescription
                                    )
                                )
                            ]
                        )
                        catalogueByKey[key] = snapshot
                        try? await dependencies.persistence
                            .saveCatalogueSnapshot(snapshot)
                    }
                }
            } catch is CancellationError {
                // Cancellation preserves the last completed catalogue.
            } catch {
                persistenceWarning = SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            }
        }
    }

    func cancelCatalogueScan(_ host: ManagedHost) {
        catalogueTasks[host.id]?.cancel()
    }

    func comparison(
        leftHost: ManagedHost,
        rightHost: ManagedHost
    ) -> [HostComparisonItem] {
        HostComparisonEngine.compare(
            leftHostID: leftHost.id,
            rightHostID: rightHost.id,
            left: inventoryByKey.values.filter {
                $0.hostID == leftHost.id
            },
            right: inventoryByKey.values.filter {
                $0.hostID == rightHost.id
            }
        )
    }

    func canPlanSkillInstall(agent: AgentKind) -> Bool {
        guard let host = selectedHost else {
            return false
        }
        if host.connection == .local {
            do {
                _ = try localMutationContext(agent: agent)
                return true
            } catch {
                return false
            }
        }
        return remoteMutationContext(agent: agent) != nil
    }

    func canPlanLocalSkillUninstall(
        capability: ProvidedCapability,
        installation: InstallationRecord?,
        snapshot: InventorySnapshot
    ) -> Bool {
        guard capability.kind == .skill,
              let installation,
              installation.scope == .user,
              installation.origin == .standalone,
              installation.restriction == .userManaged,
              installation.physicalOrigin != nil,
              snapshot.status == .complete,
              InventoryFreshness.evaluate(
                capturedAt: snapshot.capturedAt,
                now: dependencies.clock.now
              ) == .current,
              let host = selectedHost,
              host.connection == .local,
              installation.hostID == host.id
        else {
            return false
        }
        return true
    }

    func planSkillInstall(
        sourceDirectory: URL,
        agent: AgentKind
    ) async {
        operationMessage = nil
        let accessed = sourceDirectory.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceDirectory.stopAccessingSecurityScopedResource()
            }
        }
        do {
            if selectedHost?.connection.isRemote == true {
                try await planRemoteSkillInstall(
                    sourceDirectory: sourceDirectory,
                    agent: agent
                )
                return
            }
            let context = try localMutationContext(agent: agent)
            let plan: OperationPlan
            do {
                plan = try await context.engine.planInstall(
                    host: context.host,
                    hostIdentity: context.discovery.identity?.value,
                    agent: agent,
                    sourceDirectory: sourceDirectory,
                    destinationRoot: context.destinationRoot,
                    basedOnSnapshotAt: context.snapshot.capturedAt,
                    createdAt: dependencies.clock.now
                )
            } catch LocalSkillOperationError.destinationExists {
                plan = try await context.engine.planUpdate(
                    host: context.host,
                    hostIdentity: context.discovery.identity?.value,
                    agent: agent,
                    sourceDirectory: sourceDirectory,
                    destinationRoot: context.destinationRoot,
                    basedOnSnapshotAt: context.snapshot.capturedAt,
                    createdAt: dependencies.clock.now
                )
            }
            try await presentOperationPlan(plan)
        } catch {
            operationMessage = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
        }
    }

    func planLocalSkillUninstall(
        capability: ProvidedCapability,
        installation: InstallationRecord,
        snapshot: InventorySnapshot
    ) async {
        operationMessage = nil
        do {
            guard canPlanLocalSkillUninstall(
                capability: capability,
                installation: installation,
                snapshot: snapshot
            ) else {
                throw OperationProductError.unsupportedInventoryItem
            }
            let context = try localMutationContext(agent: capability.agent)
            guard let physicalOrigin = installation.physicalOrigin else {
                throw OperationProductError.missingExactTarget
            }
            let destination = URL(
                fileURLWithPath: physicalOrigin
            ).standardizedFileURL
            guard destination.deletingLastPathComponent()
                == context.destinationRoot.standardizedFileURL else {
                throw OperationProductError.targetOutsideUserSkillRoot
            }
            let plan = try await context.engine.planUninstall(
                host: context.host,
                hostIdentity: context.discovery.identity?.value,
                agent: capability.agent,
                skillName: destination.lastPathComponent,
                destinationDirectory: destination,
                basedOnSnapshotAt: snapshot.capturedAt,
                createdAt: dependencies.clock.now
            )
            try await presentOperationPlan(plan)
        } catch {
            operationMessage = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
        }
    }

    func claudePluginToggleAction(
        package: PackageRecord,
        installation: InstallationRecord?,
        source: CatalogSource?,
        snapshot: InventorySnapshot
    ) -> NativePluginAction? {
        guard package.agent == .claude,
              let installation,
              let source,
              source.agent == .claude,
              installation.agent == .claude,
              installation.scope == .user,
              installation.origin == .marketplace,
              installation.restriction == .agentManaged,
              snapshot.status == .complete,
              InventoryFreshness.evaluate(
                capturedAt: snapshot.capturedAt,
                now: dependencies.clock.now
              ) == .current,
              let host = selectedHost,
              installation.hostID == host.id,
              let discovery = discoveryByHost[host.id],
              discovery.connectionState == .reachable,
              discovery.identity != nil,
              discovery.agents.contains(where: {
                  $0.agent == .claude
                      && $0.availability == .available
                      && $0.executablePath?.hasPrefix("/") == true
              })
        else {
            return nil
        }
        if host.connection == .local {
            guard dependencies.nativePluginOperations != nil,
                  nativePluginPlanningContext(agent: .claude) != nil else {
                return nil
            }
        } else {
            guard dependencies.remotePluginOperations != nil,
                  remoteAgentMutationContext(agent: .claude) != nil else {
                return nil
            }
        }
        switch installation.state {
        case .enabled:
            return .disable
        case .disabled:
            return .enable
        default:
            return nil
        }
    }

    func planClaudePluginToggle(
        package: PackageRecord,
        installation: InstallationRecord,
        source: CatalogSource,
        snapshot: InventorySnapshot
    ) async {
        operationMessage = nil
        do {
            guard let action = claudePluginToggleAction(
                package: package,
                installation: installation,
                source: source,
                snapshot: snapshot
            ) else {
                throw OperationProductError.unsupportedInventoryItem
            }
            guard let host = selectedHost,
                  let discovery = discoveryByHost[host.id],
                  let homeDirectory = discovery.platform?.homeDirectory,
                  let executablePath = discovery.agents.first(where: {
                      $0.agent == .claude
                  })?.executablePath else {
                throw OperationProductError.hostDiscoveryRequired
            }
            let configurationPath = URL(
                fileURLWithPath: homeDirectory
            )
            .appendingPathComponent(".claude/settings.json")
            .standardizedFileURL
            .path
            let plan: OperationPlan
            if host.connection.isRemote {
                guard let context = remoteAgentMutationContext(
                    agent: .claude
                ), let engine = dependencies.remotePluginOperations else {
                    throw OperationProductError.hostDiscoveryRequired
                }
                let session = try await dependencies.hostConnectionFactory
                    .connect(to: host)
                plan = try await engine.planClaudeToggle(
                    host: host,
                    hostIdentity: context.identity,
                    agentVersion: context.agentVersion,
                    action: action,
                    package: package,
                    source: source,
                    installation: installation,
                    executablePath: context.executablePath,
                    configurationPath: configurationPath,
                    remoteHomeDirectory: homeDirectory,
                    session: session,
                    basedOnSnapshotAt: snapshot.capturedAt,
                    createdAt: dependencies.clock.now
                )
            } else {
                guard let hostIdentity = discovery.identity?.value,
                      let engine = dependencies.nativePluginOperations else {
                    throw OperationProductError.operationEngineUnavailable(
                        dependencies.operationIssue
                    )
                }
                plan = try await engine.planClaudeToggle(
                    host: host,
                    hostIdentity: hostIdentity,
                    action: action,
                    package: package,
                    source: source,
                    installation: installation,
                    executablePath: executablePath,
                    configurationPaths: [configurationPath],
                    basedOnSnapshotAt: snapshot.capturedAt,
                    createdAt: dependencies.clock.now
                )
            }
            try await presentOperationPlan(plan)
        } catch {
            operationMessage = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
        }
    }

    func cataloguePluginAction(
        package: PackageRecord,
        state: CataloguePackageState?,
        source: CatalogSource?,
        catalogue: CatalogueSnapshot
    ) -> NativePluginAction? {
        guard let source,
              source.kind == .marketplace,
              catalogue.status == .complete,
              InventoryFreshness.evaluate(
                  capturedAt: catalogue.capturedAt,
                  now: dependencies.clock.now
              ) == .current,
              let host = selectedHost,
              host.connection == .local,
              catalogue.hostID == host.id,
              catalogue.agent == package.agent,
              let inventory = inventory(for: host, agent: package.agent),
              inventory.status == .complete,
              InventoryFreshness.evaluate(
                  capturedAt: inventory.capturedAt,
                  now: dependencies.clock.now
              ) == .current,
              nativePluginPlanningContext(
                  agent: package.agent
              ) != nil
        else {
            return nil
        }
        switch state?.updateStatus ?? .notInstalled {
        case .notInstalled:
            guard supports(
                .installPlugin,
                in: catalogue.capabilities
            ), state?.compatibility != .incompatible,
               state?.restriction != .administratorManaged,
               !inventory.installations.contains(where: {
                   $0.packageID == package.id
               }) else {
                return nil
            }
            return .install
        case .updateAvailable:
            guard package.agent == .claude,
                  supports(
                      .updatePlugin,
                      in: catalogue.capabilities
                  ),
                  state?.restriction == .agentManaged,
                  inventory.installations.contains(where: {
                      $0.packageID == package.id
                          && $0.scope == .user
                  }) else {
                return nil
            }
            return .update
        case .upToDate, .unknown, .incomparable:
            return nil
        }
    }

    func planCataloguePluginAction(
        package: PackageRecord,
        state: CataloguePackageState?,
        source: CatalogSource,
        catalogue: CatalogueSnapshot
    ) async {
        operationMessage = nil
        do {
            guard let action = cataloguePluginAction(
                package: package,
                state: state,
                source: source,
                catalogue: catalogue
            ) else {
                throw OperationProductError.unsupportedInventoryItem
            }
            guard let host = selectedHost,
                  let inventory = inventory(
                      for: host,
                      agent: package.agent
                  ),
                  let context = nativePluginPlanningContext(
                      agent: package.agent
                  ),
                  let engine = dependencies.nativePluginOperations else {
                throw OperationProductError.hostDiscoveryRequired
            }
            let installation = inventory.installations.first {
                $0.packageID == package.id && $0.capabilityID == nil
            } ?? inventory.installations.first {
                $0.packageID == package.id
            }
            let plan = try await engine.planPluginAction(
                host: host,
                hostIdentity: context.hostIdentity,
                agent: package.agent,
                action: action,
                package: package,
                source: source,
                installation: installation,
                executablePath: context.executablePath,
                configurationPaths: context.configurationPaths,
                basedOnSnapshotAt: max(
                    inventory.capturedAt,
                    catalogue.capturedAt
                ),
                createdAt: dependencies.clock.now
            )
            try await presentOperationPlan(plan)
        } catch {
            operationMessage = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
        }
    }

    func canPlanPluginUninstall(
        package: PackageRecord,
        installation: InstallationRecord?,
        source: CatalogSource?,
        snapshot: InventorySnapshot
    ) -> Bool {
        guard let installation,
              let source,
              source.kind == .marketplace,
              installation.scope == .user,
              installation.origin == .marketplace,
              installation.restriction == .agentManaged,
              snapshot.status == .complete,
              InventoryFreshness.evaluate(
                  capturedAt: snapshot.capturedAt,
                  now: dependencies.clock.now
              ) == .current,
              supports(.uninstallPlugin, in: snapshot.capabilities),
              nativePluginPlanningContext(agent: package.agent) != nil
        else {
            return false
        }
        return true
    }

    func planPluginUninstall(
        package: PackageRecord,
        installation: InstallationRecord,
        source: CatalogSource,
        snapshot: InventorySnapshot
    ) async {
        operationMessage = nil
        do {
            guard canPlanPluginUninstall(
                package: package,
                installation: installation,
                source: source,
                snapshot: snapshot
            ), let host = selectedHost,
               let context = nativePluginPlanningContext(
                   agent: package.agent
               ),
               let engine = dependencies.nativePluginOperations else {
                throw OperationProductError.unsupportedInventoryItem
            }
            let plan = try await engine.planPluginAction(
                host: host,
                hostIdentity: context.hostIdentity,
                agent: package.agent,
                action: .uninstall,
                package: package,
                source: source,
                installation: installation,
                executablePath: context.executablePath,
                configurationPaths: context.configurationPaths,
                basedOnSnapshotAt: snapshot.capturedAt,
                createdAt: dependencies.clock.now
            )
            try await presentOperationPlan(plan)
        } catch {
            operationMessage = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
        }
    }

    var canPlanCodexMCPAdd: Bool {
        guard dependencies.nativeMCPOperations != nil,
              let host = selectedHost,
              host.connection == .local,
              let snapshot = inventory(for: host, agent: .codex),
              snapshot.status == .complete,
              InventoryFreshness.evaluate(
                  capturedAt: snapshot.capturedAt,
                  now: dependencies.clock.now
              ) == .current,
              supports(.mcpInventory, in: snapshot.capabilities),
              nativePluginPlanningContext(agent: .codex) != nil else {
            return false
        }
        return true
    }

    func planAddCodexHTTPServer(
        name: String,
        url: String
    ) async {
        operationMessage = nil
        do {
            guard canPlanCodexMCPAdd,
                  let host = selectedHost,
                  let snapshot = inventory(for: host, agent: .codex),
                  let context = nativePluginPlanningContext(agent: .codex),
                  let configurationPath = context.configurationPaths.first,
                  let engine = dependencies.nativeMCPOperations else {
                throw OperationProductError.freshCompleteInventoryRequired
            }
            let existing = snapshot.providedCapabilities.first {
                $0.packageID == nil
                    && $0.kind == .mcpServer
                    && $0.name == name
            }
            let plan = try await engine.planAddCodexHTTPServer(
                host: host,
                hostIdentity: context.hostIdentity,
                serverName: name,
                serverURL: url,
                executablePath: context.executablePath,
                configurationPath: configurationPath,
                existingCapability: existing,
                basedOnSnapshotAt: snapshot.capturedAt,
                createdAt: dependencies.clock.now
            )
            try await presentOperationPlan(plan)
        } catch {
            operationMessage = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
        }
    }

    func canPlanCodexMCPRemove(
        capability: ProvidedCapability,
        installation: InstallationRecord?,
        snapshot: InventorySnapshot
    ) -> Bool {
        guard dependencies.nativeMCPOperations != nil,
              capability.agent == .codex,
              capability.kind == .mcpServer,
              capability.packageID == nil,
              let installation,
              installation.scope == .user,
              installation.origin == .standalone,
              installation.restriction == .agentManaged,
              snapshot.status == .complete,
              InventoryFreshness.evaluate(
                  capturedAt: snapshot.capturedAt,
                  now: dependencies.clock.now
              ) == .current,
              supports(.mcpInventory, in: snapshot.capabilities),
              nativePluginPlanningContext(agent: .codex) != nil else {
            return false
        }
        return true
    }

    func planRemoveCodexMCPServer(
        capability: ProvidedCapability,
        installation: InstallationRecord,
        snapshot: InventorySnapshot
    ) async {
        operationMessage = nil
        do {
            guard canPlanCodexMCPRemove(
                capability: capability,
                installation: installation,
                snapshot: snapshot
            ), let host = selectedHost,
               let context = nativePluginPlanningContext(agent: .codex),
               let configurationPath = context.configurationPaths.first,
               let engine = dependencies.nativeMCPOperations else {
                throw OperationProductError.unsupportedInventoryItem
            }
            let plan = try await engine.planRemoveCodexServer(
                host: host,
                hostIdentity: context.hostIdentity,
                capability: capability,
                installation: installation,
                executablePath: context.executablePath,
                configurationPath: configurationPath,
                basedOnSnapshotAt: snapshot.capturedAt,
                createdAt: dependencies.clock.now
            )
            try await presentOperationPlan(plan)
        } catch {
            operationMessage = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
        }
    }

    func applyPendingOperation() async {
        guard let plan = pendingOperationPlan,
              !applyingOperationIDs.contains(plan.id)
        else {
            return
        }
        operationMessage = nil
        applyingOperationIDs.insert(plan.id)
        defer {
            applyingOperationIDs.remove(plan.id)
        }

        do {
            guard let host = hosts.first(where: { $0.id == plan.hostID }) else {
                throw OperationProductError.hostDiscoveryRequired
            }
            if host.connection.isRemote {
                try await verifyRemotePlanTarget(
                    plan: plan,
                    host: host
                )
            }
            guard discoveryByHost[host.id]?.identity?.value
                    == plan.hostIdentity else {
                throw OperationProductError.hostIdentityChanged
            }
            guard let adapter = dependencies.adapterRegistry.adapter(
                for: plan.agent
            ) else {
                throw OperationProductError.adapterUnavailable
            }
            let session = try await dependencies.hostConnectionFactory
                .connect(to: host)

            let preflightSnapshot = try await adapter.inspect(
                context: .hostOnly,
                using: session
            )
            let key = InventoryKey(hostID: host.id, agent: plan.agent)
            inventoryByKey[key] = preflightSnapshot
            try await dependencies.persistence.saveInventorySnapshot(
                preflightSnapshot
            )
            var preflightMatches = operationTargetMatches(
                plan: plan,
                snapshot: preflightSnapshot,
                phase: .beforeApply
            )
            if case let .nativePlugin(spec) = plan.execution,
               spec.requiresCataloguePreflight {
                let freshCatalogue = try await adapter.inspectCatalogue(
                    installed: preflightSnapshot,
                    using: session
                )
                catalogueByKey[key] = freshCatalogue
                try await dependencies.persistence.saveCatalogueSnapshot(
                    freshCatalogue
                )
                preflightMatches = preflightMatches
                    && catalogueTargetMatches(
                        plan: plan,
                        catalogue: freshCatalogue
                    )
            }
            let approval = OperationApproval(
                plan: plan,
                approvedAt: dependencies.clock.now
            )
            await dependencies.approvalStore.save(approval)
            let preflight = OperationPreflight(
                inspectedAt: preflightSnapshot.capturedAt,
                targetStateMatchesPlan: preflightMatches
            )
            let persistence = dependencies.persistence
            let result: OperationRecord
            switch plan.execution {
            case .localSkill:
                guard let engine = dependencies.localSkillOperations else {
                    throw OperationProductError.operationEngineUnavailable(
                        dependencies.operationIssue
                    )
                }
                result = await engine.apply(
                    plan: plan,
                    approval: approval,
                    preflight: preflight,
                    now: dependencies.clock.now
                ) { [weak self] in
                    await inspectOperationTarget(
                        adapter: adapter,
                        session: session,
                        persistence: persistence,
                        plan: plan,
                        key: key,
                        phase: .afterApply,
                        update: { verified in
                            await MainActor.run {
                                self?.inventoryByKey[key] = verified
                            }
                        }
                    )
                }
            case .nativePlugin:
                guard let engine = dependencies.nativePluginOperations else {
                    throw OperationProductError.operationEngineUnavailable(
                        dependencies.operationIssue
                    )
                }
                result = await engine.apply(
                    plan: plan,
                    approval: approval,
                    preflight: preflight,
                    session: session,
                    now: dependencies.clock.now,
                    verifyExpectedState: { [weak self] in
                        await inspectOperationTarget(
                            adapter: adapter,
                            session: session,
                            persistence: persistence,
                            plan: plan,
                            key: key,
                            phase: .afterApply,
                            update: { verified in
                                await MainActor.run {
                                    self?.inventoryByKey[key] = verified
                                }
                            }
                        )
                    },
                    verifyRolledBackState: { [weak self] in
                        await inspectOperationTarget(
                            adapter: adapter,
                            session: session,
                            persistence: persistence,
                            plan: plan,
                            key: key,
                            phase: .beforeApply,
                            update: { verified in
                                await MainActor.run {
                                    self?.inventoryByKey[key] = verified
                                }
                            }
                        )
                    }
                )
            case .nativeMCP:
                guard let engine = dependencies.nativeMCPOperations else {
                    throw OperationProductError.operationEngineUnavailable(
                        dependencies.operationIssue
                    )
                }
                result = await engine.apply(
                    plan: plan,
                    approval: approval,
                    preflight: preflight,
                    session: session,
                    now: dependencies.clock.now,
                    verifyExpectedState: { [weak self] in
                        await inspectOperationTarget(
                            adapter: adapter,
                            session: session,
                            persistence: persistence,
                            plan: plan,
                            key: key,
                            phase: .afterApply,
                            update: { verified in
                                await MainActor.run {
                                    self?.inventoryByKey[key] = verified
                                }
                            }
                        )
                    },
                    verifyRolledBackState: { [weak self] in
                        await inspectOperationTarget(
                            adapter: adapter,
                            session: session,
                            persistence: persistence,
                            plan: plan,
                            key: key,
                            phase: .beforeApply,
                            update: { verified in
                                await MainActor.run {
                                    self?.inventoryByKey[key] = verified
                                }
                            }
                        )
                    }
                )
            case .remoteSkill:
                guard let engine = dependencies.remoteSkillOperations else {
                    throw OperationProductError.operationEngineUnavailable(
                        dependencies.operationIssue
                    )
                }
                result = await engine.apply(
                    plan: plan,
                    approval: approval,
                    preflight: preflight,
                    session: session,
                    now: dependencies.clock.now,
                    verifyExpectedState: { [weak self] in
                        await inspectOperationTarget(
                            adapter: adapter,
                            session: session,
                            persistence: persistence,
                            plan: plan,
                            key: key,
                            phase: .afterApply,
                            update: { verified in
                                await MainActor.run {
                                    self?.inventoryByKey[key] = verified
                                }
                            }
                        )
                    },
                    verifyRolledBackState: { [weak self] in
                        await inspectOperationTarget(
                            adapter: adapter,
                            session: session,
                            persistence: persistence,
                            plan: plan,
                            key: key,
                            phase: .beforeApply,
                            update: { verified in
                                await MainActor.run {
                                    self?.inventoryByKey[key] = verified
                                }
                            }
                        )
                    }
                )
            case .remotePlugin:
                guard let engine = dependencies.remotePluginOperations else {
                    throw OperationProductError.operationEngineUnavailable(
                        dependencies.operationIssue
                    )
                }
                result = await engine.apply(
                    plan: plan,
                    approval: approval,
                    preflight: preflight,
                    session: session,
                    now: dependencies.clock.now,
                    verifyExpectedState: { [weak self] in
                        await inspectOperationTarget(
                            adapter: adapter,
                            session: session,
                            persistence: persistence,
                            plan: plan,
                            key: key,
                            phase: .afterApply,
                            update: { verified in
                                await MainActor.run {
                                    self?.inventoryByKey[key] = verified
                                }
                            }
                        )
                    },
                    verifyRolledBackState: { [weak self] in
                        await inspectOperationTarget(
                            adapter: adapter,
                            session: session,
                            persistence: persistence,
                            plan: plan,
                            key: key,
                            phase: .beforeApply,
                            update: { verified in
                                await MainActor.run {
                                    self?.inventoryByKey[key] = verified
                                }
                            }
                        )
                    }
                )
            case nil:
                throw OperationProductError.unsupportedInventoryItem
            }

            upsertOperationRecord(result)
            try await dependencies.persistence.saveOperationRecord(result)
            await dependencies.approvalStore.removeApproval(for: plan.id)
            pendingOperationPlan = nil

            if result.rollbackState == .succeeded
                || result.state == .rolledBack {
                let restored = try? await adapter.inspect(
                    context: .hostOnly,
                    using: session
                )
                if let restored {
                    inventoryByKey[key] = restored
                    try? await dependencies.persistence.saveInventorySnapshot(
                        restored
                    )
                }
            }
            selectedSection = .activity
            operationMessage = result.state == .completed
                ? "The operation completed with fresh matching evidence."
                : result.failure
        } catch {
            let detail = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
            operationMessage = detail
            if let pending = pendingOperationPlan,
               pending.id == plan.id {
                let existing = operationRecords.first {
                    $0.id == plan.id
                } ?? awaitingRecord(for: plan)
                let invalidated = existing.transitioned(
                    to: .invalidated,
                    at: dependencies.clock.now,
                    message: "Fresh preflight checks invalidated the operation before apply.",
                    failure: detail
                )
                upsertOperationRecord(invalidated)
                try? await dependencies.persistence.saveOperationRecord(
                    invalidated
                )
                await dependencies.approvalStore.removeApproval(for: plan.id)
                pendingOperationPlan = nil
                selectedSection = .activity
            }
        }
    }

    func dismissPendingOperation() async {
        guard let plan = pendingOperationPlan else {
            return
        }
        await dependencies.approvalStore.removeApproval(for: plan.id)
        let existing = operationRecords.first { $0.id == plan.id }
            ?? awaitingRecord(for: plan)
        let dismissed = existing.transitioned(
            to: .invalidated,
            at: dependencies.clock.now,
            message: "The plan review was dismissed without applying a change.",
            failure: "Not approved."
        )
        upsertOperationRecord(dismissed)
        try? await dependencies.persistence.saveOperationRecord(dismissed)
        pendingOperationPlan = nil
    }

    func makeDiagnosticReport() throws -> Data {
        try DiagnosticReportBuilder.makeReport(
            generatedAt: dependencies.clock.now,
            hosts: hosts,
            discoveries: Array(discoveryByHost.values),
            inventories: Array(inventoryByKey.values),
            catalogues: Array(catalogueByKey.values)
        )
    }

    private func localMutationContext(
        agent: AgentKind
    ) throws -> LocalMutationContext {
        guard let engine = dependencies.localSkillOperations else {
            throw OperationProductError.operationEngineUnavailable(
                dependencies.operationIssue
            )
        }
        guard let host = selectedHost, host.connection == .local else {
            throw OperationProductError.localHostRequired
        }
        guard let discovery = discoveryByHost[host.id],
              discovery.connectionState == .reachable,
              discovery.identity != nil,
              let homeDirectory = discovery.platform?.homeDirectory else {
            throw OperationProductError.hostDiscoveryRequired
        }
        guard let snapshot = inventory(for: host, agent: agent),
              snapshot.status == .complete,
              InventoryFreshness.evaluate(
                capturedAt: snapshot.capturedAt,
                now: dependencies.clock.now
              ) == .current else {
            throw OperationProductError.freshCompleteInventoryRequired
        }
        guard let adapter = dependencies.adapterRegistry.adapter(for: agent),
              let relativePath = adapter.userSkillRelativePath else {
            throw OperationProductError.adapterUnavailable
        }
        let destinationRoot = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(relativePath, isDirectory: true)
            .standardizedFileURL
        return LocalMutationContext(
            engine: engine,
            host: host,
            discovery: discovery,
            snapshot: snapshot,
            destinationRoot: destinationRoot
        )
    }

    private func planRemoteSkillInstall(
        sourceDirectory: URL,
        agent: AgentKind
    ) async throws {
        guard let context = remoteMutationContext(agent: agent),
              let engine = dependencies.remoteSkillOperations else {
            throw OperationProductError.freshCompleteInventoryRequired
        }
        let session = try await dependencies.hostConnectionFactory
            .connect(to: context.host)
        let rootResult = try await session.execute(
            CommandRequest(
                executable: "/bin/test",
                arguments: [
                    "-d",
                    context.destinationRoot,
                    "-a",
                    "-w",
                    context.destinationRoot
                ],
                environment: ["LC_ALL": "C"],
                timeout: .seconds(10),
                maximumOutputBytes: 16_384
            )
        )
        let createsDestinationRoot: Bool
        if rootResult.succeeded {
            createsDestinationRoot = false
        } else if rootResult.exitCode == 1 {
            let parent = URL(
                fileURLWithPath: context.destinationRoot
            ).deletingLastPathComponent().path
            let parentResult = try await session.execute(
                CommandRequest(
                    executable: "/bin/test",
                    arguments: ["-d", parent, "-a", "-w", parent],
                    environment: ["LC_ALL": "C"],
                    timeout: .seconds(10),
                    maximumOutputBytes: 16_384
                )
            )
            guard parentResult.succeeded else {
                throw OperationProductError.remoteTargetUnavailable
            }
            createsDestinationRoot = true
        } else {
            throw OperationProductError.remoteTargetUnavailable
        }
        let plan = try await engine.planInstall(
            host: context.host,
            hostIdentity: context.identity,
            agent: agent,
            agentVersion: context.agentVersion,
            localSourceDirectory: sourceDirectory,
            remoteDestinationRoot: context.destinationRoot,
            remoteHomeDirectory: context.homeDirectory,
            createsDestinationRoot: createsDestinationRoot,
            basedOnSnapshotAt: context.snapshot.capturedAt,
            createdAt: dependencies.clock.now
        )
        guard case let .remoteSkill(spec) = plan.execution else {
            throw OperationProductError.unsupportedInventoryItem
        }
        let diskTarget = createsDestinationRoot
            ? URL(fileURLWithPath: context.destinationRoot)
                .deletingLastPathComponent().path
            : context.destinationRoot
        let disk = try await session.execute(
            CommandRequest(
                executable: "/bin/df",
                arguments: ["-Pk", diskTarget],
                environment: ["LC_ALL": "C"],
                timeout: .seconds(10),
                maximumOutputBytes: 32_768
            )
        )
        guard disk.succeeded,
              remoteAvailableBytes(from: disk.standardOutput)
                >= Int64(spec.archiveByteCount * 2 + 1_048_576) else {
            throw OperationProductError.insufficientRemoteDiskSpace
        }
        try await presentOperationPlan(plan)
    }

    private func remoteMutationContext(
        agent: AgentKind
    ) -> RemoteMutationContext? {
        guard dependencies.remoteSkillOperations != nil,
              let base = remoteAgentMutationContext(agent: agent),
              let adapter = dependencies.adapterRegistry.adapter(for: agent),
              let relativePath = adapter.userSkillRelativePath else {
            return nil
        }
        let destinationRoot = URL(
            fileURLWithPath: base.homeDirectory
        )
        .appendingPathComponent(relativePath, isDirectory: true)
        .standardizedFileURL
        .path
        return RemoteMutationContext(
            host: base.host,
            identity: base.identity,
            homeDirectory: base.homeDirectory,
            agentVersion: base.agentVersion,
            snapshot: base.snapshot,
            destinationRoot: destinationRoot
        )
    }

    private func remoteAgentMutationContext(
        agent: AgentKind
    ) -> RemoteAgentMutationContext? {
        guard let host = selectedHost,
              host.connection.isRemote,
              let discovery = discoveryByHost[host.id],
              discovery.connectionState == .reachable,
              let identity = discovery.identity,
              identity.kind != .derived,
              let homeDirectory = discovery.platform?.homeDirectory,
              let discoveredAgent = discovery.agents.first(where: {
                  $0.agent == agent
                      && $0.availability == .available
              }),
              let agentVersion = discoveredAgent.version,
              let executablePath = discoveredAgent.executablePath,
              executablePath.hasPrefix("/"),
              let snapshot = inventory(for: host, agent: agent),
              snapshot.status == .complete,
              InventoryFreshness.evaluate(
                  capturedAt: snapshot.capturedAt,
                  now: dependencies.clock.now
              ) == .current else {
            return nil
        }
        return RemoteAgentMutationContext(
            host: host,
            identity: identity,
            homeDirectory: homeDirectory,
            agentVersion: agentVersion,
            executablePath: executablePath,
            snapshot: snapshot
        )
    }

    private func verifyRemotePlanTarget(
        plan: OperationPlan,
        host: ManagedHost
    ) async throws {
        let discovery = await dependencies.hostDiscovery.discover(
            host: host,
            resolvedHost: resolvedHostByID[host.id]
        )
        discoveryByHost[host.id] = discovery
        discoveryHistory.append(discovery)
        try await dependencies.persistence.saveHostDiscoverySnapshot(
            discovery
        )
        guard discovery.connectionState == .reachable else {
            throw OperationProductError.remoteTargetUnavailable
        }
        guard let identity = discovery.identity,
              identity.kind != .derived,
              identity.value == plan.hostIdentity else {
            throw OperationProductError.hostIdentityChanged
        }
        guard let expectedVersion = plan.agentVersion,
              discovery.agents.contains(where: {
                  $0.agent == plan.agent
                      && $0.availability == .available
                      && $0.version == expectedVersion
              }) else {
            throw OperationProductError.agentVersionChanged
        }

        if case let .remotePlugin(spec) = plan.execution {
            guard discovery.agents.contains(where: {
                $0.agent == plan.agent
                    && $0.executablePath == spec.executablePath
            }) else {
                throw OperationProductError.agentVersionChanged
            }
            let parent = URL(
                fileURLWithPath: spec.configurationState.path
            ).deletingLastPathComponent().path
            let session = try await dependencies.hostConnectionFactory
                .connect(to: host)
            let permission = try await session.execute(
                CommandRequest(
                    executable: "/bin/test",
                    arguments: ["-d", parent, "-a", "-w", parent],
                    environment: ["LC_ALL": "C"],
                    timeout: .seconds(10),
                    maximumOutputBytes: 16_384
                )
            )
            guard permission.succeeded else {
                throw OperationProductError.remoteTargetUnavailable
            }
            return
        }
        guard case let .remoteSkill(spec) = plan.execution else {
            return
        }
        let session = try await dependencies.hostConnectionFactory
            .connect(to: host)
        let parentURL = URL(
            fileURLWithPath: spec.remoteDestinationPath
        ).deletingLastPathComponent()
        let permissionTarget = spec.createsDestinationRoot
            ? parentURL.deletingLastPathComponent().path
            : parentURL.path
        let parentExists = try await session.execute(
            CommandRequest(
                executable: "/bin/test",
                arguments: [
                    "-d",
                    permissionTarget,
                    "-a",
                    "-w",
                    permissionTarget
                ],
                environment: ["LC_ALL": "C"],
                timeout: .seconds(10),
                maximumOutputBytes: 16_384
            )
        )
        guard parentExists.succeeded else {
            throw OperationProductError.remoteTargetUnavailable
        }
        let disk = try await session.execute(
            CommandRequest(
                executable: "/bin/df",
                arguments: ["-Pk", permissionTarget],
                environment: ["LC_ALL": "C"],
                timeout: .seconds(10),
                maximumOutputBytes: 32_768
            )
        )
        guard disk.succeeded,
              remoteAvailableBytes(from: disk.standardOutput)
                >= Int64(spec.archiveByteCount * 2 + 1_048_576) else {
            throw OperationProductError.insufficientRemoteDiskSpace
        }
    }

    private func nativePluginPlanningContext(
        agent: AgentKind
    ) -> NativePluginPlanningContext? {
        guard let host = selectedHost,
              host.connection == .local,
              let discovery = discoveryByHost[host.id],
              discovery.connectionState == .reachable,
              let hostIdentity = discovery.identity?.value,
              let homeDirectory = discovery.platform?.homeDirectory,
              let executablePath = discovery.agents.first(where: {
                  $0.agent == agent
                      && $0.availability == .available
              })?.executablePath,
              executablePath.hasPrefix("/") else {
            return nil
        }
        let configurationRelativePath = agent == .claude
            ? ".claude/settings.json"
            : ".codex/config.toml"
        return NativePluginPlanningContext(
            hostIdentity: hostIdentity,
            executablePath: executablePath,
            configurationPaths: [
                URL(fileURLWithPath: homeDirectory)
                    .appendingPathComponent(configurationRelativePath)
                    .standardizedFileURL
                    .path
            ]
        )
    }

    private func presentOperationPlan(_ plan: OperationPlan) async throws {
        let record = awaitingRecord(for: plan)
        upsertOperationRecord(record)
        try await dependencies.persistence.saveOperationRecord(record)
        pendingOperationPlan = plan
    }

    private func awaitingRecord(
        for plan: OperationPlan
    ) -> OperationRecord {
        OperationRecord(
            plan: plan,
            state: .awaitingApproval,
            updatedAt: dependencies.clock.now,
            events: [
                OperationEvent(
                    state: .planned,
                    occurredAt: plan.createdAt,
                    message: "The immutable operation plan was created."
                ),
                OperationEvent(
                    state: .awaitingApproval,
                    occurredAt: dependencies.clock.now,
                    message: "Review the exact target and expected effect."
                )
            ]
        )
    }

    private func upsertOperationRecord(_ record: OperationRecord) {
        operationRecords.removeAll { $0.id == record.id }
        operationRecords.append(record)
        operationRecords.sort { $0.updatedAt > $1.updatedAt }
    }
}

private struct LocalMutationContext {
    let engine: LocalSkillOperationEngine
    let host: ManagedHost
    let discovery: HostDiscoverySnapshot
    let snapshot: InventorySnapshot
    let destinationRoot: URL
}

private struct NativePluginPlanningContext {
    let hostIdentity: String
    let executablePath: String
    let configurationPaths: [String]
}

private struct RemoteMutationContext {
    let host: ManagedHost
    let identity: HostIdentityEvidence
    let homeDirectory: String
    let agentVersion: String
    let snapshot: InventorySnapshot
    let destinationRoot: String
}

private struct RemoteAgentMutationContext {
    let host: ManagedHost
    let identity: HostIdentityEvidence
    let homeDirectory: String
    let agentVersion: String
    let executablePath: String
    let snapshot: InventorySnapshot
}

private func supports(
    _ feature: AdapterFeature,
    in reports: [AdapterCapabilityReport]
) -> Bool {
    reports.first { $0.feature == feature }?.support == .supported
}

private enum OperationVerificationPhase: Sendable {
    case beforeApply
    case afterApply
}

private func operationTargetMatches(
    plan: OperationPlan,
    snapshot: InventorySnapshot,
    phase: OperationVerificationPhase
) -> Bool {
    guard snapshot.status == .complete else {
        return false
    }
    switch plan.execution {
    case let .localSkill(spec):
        let targetIsReported = snapshot.installations.contains {
            installation in
            guard let path = installation.physicalOrigin else {
                return false
            }
            return URL(fileURLWithPath: path).standardizedFileURL.path
                == URL(
                    fileURLWithPath: spec.destinationPath
                ).standardizedFileURL.path
                && installation.origin == .standalone
                && installation.scope == .user
        }
        switch (spec.action, phase) {
        case (.install, .beforeApply), (.uninstall, .afterApply):
            return !targetIsReported
        case (.uninstall, .beforeApply),
             (.install, .afterApply),
             (.update, .beforeApply),
             (.update, .afterApply):
            return targetIsReported
        }
    case let .remoteSkill(spec):
        let targetIsReported = snapshot.installations.contains {
            installation in
            guard let path = installation.physicalOrigin else {
                return false
            }
            return URL(fileURLWithPath: path).standardizedFileURL.path
                == URL(
                    fileURLWithPath: spec.remoteDestinationPath
                ).standardizedFileURL.path
                && installation.origin == .standalone
                && installation.scope == .user
        }
        return phase == .beforeApply
            ? !targetIsReported
            : targetIsReported
    case let .remotePlugin(spec):
        let parts = spec.selector.split(
            separator: "@",
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else {
            return false
        }
        let sourceIDs = Set(
            snapshot.catalogSources.filter {
                $0.name == String(parts[1])
                    && ($0.reference ?? $0.name)
                        == plan.sourceReference
            }.map(\.id)
        )
        guard let package = snapshot.packages.first(where: {
            $0.name == String(parts[0])
                && $0.sourceID.map(sourceIDs.contains) == true
        }), let installation = snapshot.installations.first(where: {
            $0.packageID == package.id
                && $0.scope == spec.scope
        }) else {
            return false
        }
        let expected = phase == .beforeApply
            ? spec.expectedBeforeState
            : spec.expectedAfterState
        return installation.state == expected
            && (
                spec.expectedVersion == nil
                    || installation.installedVersion
                        == spec.expectedVersion
            )
    case let .nativePlugin(spec):
        let parts = spec.selector.split(
            separator: "@",
            omittingEmptySubsequences: false
        )
        guard parts.count == 2 else {
            return false
        }
        let matchingSources = snapshot.catalogSources.filter {
            $0.name == String(parts[1])
                && ($0.reference ?? $0.name) == plan.sourceReference
                && (plan.revision == nil || $0.revision == plan.revision)
        }
        let sourceIDs = Set(matchingSources.map(\.id))
        let package = snapshot.packages.first(where: {
            $0.name == String(parts[0])
                && $0.sourceID.map(sourceIDs.contains) == true
        })
        let installation = package.flatMap { package in
            snapshot.installations.first(where: {
                $0.packageID == package.id && $0.capabilityID == nil
            }) ?? snapshot.installations.first(where: {
                $0.packageID == package.id
            })
        }
        let expectedInstalled: Bool
        let expectedState: EffectiveState?
        let expectedVersion: String?
        switch phase {
        case .beforeApply:
            expectedInstalled = spec.expectedBeforeInstalled
            expectedState = spec.expectedBeforeState
            expectedVersion = spec.expectedBeforeVersion
        case .afterApply:
            expectedInstalled = spec.expectedAfterInstalled
            expectedState = spec.expectedAfterState
            expectedVersion = spec.expectedAfterVersion
        }
        guard expectedInstalled else {
            return installation == nil
        }
        guard let package, let installation,
              installation.scope == spec.scope else {
            return false
        }
        if let digest = plan.contentDigest,
           package.manifestDigest != digest {
            return false
        }
        if let expectedState, installation.state != expectedState {
            return false
        }
        if let expectedVersion,
           installation.installedVersion ?? package.version
            != expectedVersion {
            return false
        }
        return true
    case let .nativeMCP(spec):
        let capability = snapshot.providedCapabilities.first {
            $0.packageID == nil
                && $0.kind == .mcpServer
                && $0.name == spec.serverName
        }
        let installation = capability.flatMap { capability in
            snapshot.installations.first {
                $0.capabilityID == capability.id
            }
        }
        let expectedConfigured: Bool
        switch phase {
        case .beforeApply:
            expectedConfigured = spec.expectedBeforeConfigured
        case .afterApply:
            expectedConfigured = spec.expectedAfterConfigured
        }
        guard expectedConfigured else {
            return installation == nil
        }
        return installation?.scope == spec.scope
            && installation?.origin == .standalone
    case nil:
        return false
    }
}

private func inspectOperationTarget(
    adapter: any AgentAdapter,
    session: any HostSession,
    persistence: any KitroomPersistence,
    plan: OperationPlan,
    key: InventoryKey,
    phase: OperationVerificationPhase,
    update: @escaping @Sendable (InventorySnapshot) async -> Void
) async -> Bool {
    do {
        let verified = try await adapter.inspect(
            context: .hostOnly,
            using: session
        )
        try await persistence.saveInventorySnapshot(verified)
        await update(verified)
        return operationTargetMatches(
            plan: plan,
            snapshot: verified,
            phase: phase
        )
    } catch {
        return false
    }
}

private func catalogueTargetMatches(
    plan: OperationPlan,
    catalogue: CatalogueSnapshot
) -> Bool {
    guard catalogue.status == .complete,
          catalogue.hostID == plan.hostID,
          catalogue.agent == plan.agent,
          catalogue.capturedAt >= plan.basedOnSnapshotAt,
          case let .nativePlugin(spec) = plan.execution else {
        return false
    }
    let parts = spec.selector.split(
        separator: "@",
        omittingEmptySubsequences: false
    )
    guard parts.count == 2,
          let source = catalogue.sources.first(where: {
              $0.name == String(parts[1])
          }),
          (source.reference ?? source.name) == plan.sourceReference,
          plan.revision == nil || source.revision == plan.revision,
          let package = catalogue.packages.first(where: {
              $0.name == String(parts[0])
                  && $0.sourceID == source.id
          }) else {
        return false
    }
    return (plan.version == nil || package.version == plan.version)
        && (
            plan.contentDigest == nil
                || package.manifestDigest == plan.contentDigest
        )
}

private enum OperationProductError: LocalizedError {
    case operationEngineUnavailable(String?)
    case localHostRequired
    case hostDiscoveryRequired
    case freshCompleteInventoryRequired
    case hostIdentityChanged
    case adapterUnavailable
    case unsupportedInventoryItem
    case missingExactTarget
    case targetOutsideUserSkillRoot
    case remoteTargetUnavailable
    case agentVersionChanged
    case insufficientRemoteDiskSpace

    var errorDescription: String? {
        switch self {
        case let .operationEngineUnavailable(detail):
            if let detail, !detail.isEmpty {
                "Local operations are unavailable: \(detail)"
            } else {
                "Local operations are unavailable."
            }
        case .localHostRequired:
            "This operation is currently limited to the local Mac."
        case .hostDiscoveryRequired:
            "Check the local host before planning a change."
        case .freshCompleteInventoryRequired:
            "Run a complete inventory scan before planning a change."
        case .hostIdentityChanged:
            "The verified host identity no longer matches the plan."
        case .adapterUnavailable:
            "The selected agent cannot plan this operation."
        case .unsupportedInventoryItem:
            "This inventory item, scope, source, or agent capability does not support the requested guarded operation."
        case .missingExactTarget:
            "The inventory does not contain an exact installed path."
        case .targetOutsideUserSkillRoot:
            "The installed path is outside the agent's verified user skill directory."
        case .remoteTargetUnavailable:
            "The remote skill directory or its parent is unavailable or not writable."
        case .agentVersionChanged:
            "The verified remote agent version no longer matches the plan."
        case .insufficientRemoteDiskSpace:
            "The remote target does not have enough verified free space for staging and recovery."
        }
    }
}

private func remoteAvailableBytes(
    from output: String
) -> Int64 {
    let lines = output.split(whereSeparator: \.isNewline)
    guard let row = lines.last else {
        return 0
    }
    let columns = row.split(whereSeparator: \.isWhitespace)
    guard columns.count >= 4,
          let availableKilobytes = Int64(columns[3]) else {
        return 0
    }
    return availableKilobytes * 1_024
}

struct InventoryKey: Hashable, Sendable {
    let hostID: ManagedHost.ID
    let agent: AgentKind
}

enum HostSetupError: LocalizedError {
    case missingName
    case invalidAlias
    case duplicateAlias

    var errorDescription: String? {
        switch self {
        case .missingName:
            "Enter a display name."
        case .invalidAlias:
            "Enter a concrete OpenSSH alias using letters, numbers, dots, dashes, or underscores."
        case .duplicateAlias:
            "That OpenSSH alias is already in Kitroom."
        }
    }
}
