public protocol KitroomPersistence: Sendable {
    func loadHosts() async throws -> [ManagedHost]
    func saveHosts(_ hosts: [ManagedHost]) async throws
    func loadHostDiscoverySnapshots() async throws -> [HostDiscoverySnapshot]
    func loadHostDiscoveryHistory(
        hostID: ManagedHost.ID?,
        limit: Int
    ) async throws -> [HostDiscoverySnapshot]
    func saveHostDiscoverySnapshot(_ snapshot: HostDiscoverySnapshot) async throws
    func loadInventorySnapshots() async throws -> [InventorySnapshot]
    func loadInventoryHistory(
        hostID: ManagedHost.ID?,
        agent: AgentKind?,
        limit: Int
    ) async throws -> [InventorySnapshot]
    func saveInventorySnapshot(_ snapshot: InventorySnapshot) async throws
}

public actor InMemoryKitroomPersistence: KitroomPersistence {
    private var hosts: [ManagedHost]
    private var discoverySnapshots: [HostDiscoverySnapshot]
    private var inventorySnapshots: [InventorySnapshot]

    public init(
        hosts: [ManagedHost] = [],
        discoverySnapshots: [HostDiscoverySnapshot] = [],
        snapshots: [InventorySnapshot] = []
    ) {
        self.hosts = hosts
        self.discoverySnapshots = discoverySnapshots
        self.inventorySnapshots = snapshots
    }

    public func loadHosts() -> [ManagedHost] {
        hosts
    }

    public func saveHosts(_ hosts: [ManagedHost]) {
        self.hosts = hosts
    }

    public func loadHostDiscoverySnapshots() -> [HostDiscoverySnapshot] {
        latestDiscoverySnapshots(from: discoverySnapshots)
    }

    public func loadHostDiscoveryHistory(
        hostID: ManagedHost.ID? = nil,
        limit: Int = 50
    ) -> [HostDiscoverySnapshot] {
        discoverySnapshots
            .filter { hostID == nil || $0.hostID == hostID }
            .sorted { $0.attemptedAt > $1.attemptedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func saveHostDiscoverySnapshot(_ snapshot: HostDiscoverySnapshot) {
        discoverySnapshots.append(snapshot)
    }

    public func loadInventorySnapshots() -> [InventorySnapshot] {
        latestInventorySnapshots(from: inventorySnapshots)
    }

    public func loadInventoryHistory(
        hostID: ManagedHost.ID? = nil,
        agent: AgentKind? = nil,
        limit: Int = 50
    ) -> [InventorySnapshot] {
        inventorySnapshots
            .filter { snapshot in
                (hostID == nil || snapshot.hostID == hostID)
                    && (agent == nil || snapshot.agent == agent)
            }
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func saveInventorySnapshot(_ snapshot: InventorySnapshot) {
        inventorySnapshots.append(snapshot)
    }
}

func latestDiscoverySnapshots(
    from snapshots: [HostDiscoverySnapshot]
) -> [HostDiscoverySnapshot] {
    Dictionary(grouping: snapshots, by: \.hostID)
        .compactMap { _, values in
            values.max { $0.attemptedAt < $1.attemptedAt }
        }
        .sorted { $0.attemptedAt > $1.attemptedAt }
}

func latestInventorySnapshots(
    from snapshots: [InventorySnapshot]
) -> [InventorySnapshot] {
    Dictionary(grouping: snapshots) {
        InventoryPersistenceKey(hostID: $0.hostID, agent: $0.agent)
    }
    .compactMap { _, values in
        values.max { $0.capturedAt < $1.capturedAt }
    }
    .sorted { lhs, rhs in
        if lhs.hostID == rhs.hostID {
            return lhs.agent.rawValue < rhs.agent.rawValue
        }
        return lhs.hostID.uuidString < rhs.hostID.uuidString
    }
}

private struct InventoryPersistenceKey: Hashable {
    let hostID: ManagedHost.ID
    let agent: AgentKind
}
