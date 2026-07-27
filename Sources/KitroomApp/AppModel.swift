import Foundation
import KitroomCore

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection? = .hosts
    @Published var selectedHostID: ManagedHost.ID?

    @Published private(set) var hosts: [ManagedHost]
    @Published private(set) var discoveryByHost: [ManagedHost.ID: HostDiscoverySnapshot] = [:]
    @Published private(set) var resolvedHostByID: [ManagedHost.ID: String] = [:]
    @Published private(set) var inventoryByKey: [InventoryKey: InventorySnapshot] = [:]
    @Published private(set) var inventoryScanningHostIDs: Set<ManagedHost.ID> = []
    @Published var projectDirectoryByHost: [ManagedHost.ID: String] = [:]

    let dependencies: AppDependencies

    private var hasStarted = false
    private var scanTasks: [ManagedHost.ID: Task<Void, Never>] = [:]
    private var inventoryTasks: [ManagedHost.ID: Task<Void, Never>] = [:]

    init(
        hosts: [ManagedHost] = [ManagedHost(name: "This Mac", connection: .local)],
        dependencies: AppDependencies = .live()
    ) {
        self.hosts = hosts
        self.dependencies = dependencies
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

    func inventory(
        for host: ManagedHost,
        agent: AgentKind
    ) -> InventorySnapshot? {
        inventoryByKey[InventoryKey(hostID: host.id, agent: agent)]
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
        } catch {
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
                discoveryByHost[host.id] = HostDiscoverySnapshot(
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
                scanTasks[host.id] = nil
                return
            }

            if let resolvedHost {
                resolvedHostByID[host.id] = resolvedHost
            }
            discoveryByHost[host.id] = snapshot
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
                    try await dependencies.persistence.saveInventorySnapshot(
                        snapshot
                    )
                }
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
                }
            }

            inventoryScanningHostIDs.remove(host.id)
            inventoryTasks[host.id] = nil
        }
    }

    func cancelInventoryScan(_ host: ManagedHost) {
        inventoryTasks[host.id]?.cancel()
    }
}

struct InventoryKey: Hashable {
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
