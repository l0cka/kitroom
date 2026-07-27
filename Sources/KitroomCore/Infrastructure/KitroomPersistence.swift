public protocol KitroomPersistence: Sendable {
    func loadHosts() async throws -> [ManagedHost]
    func saveHosts(_ hosts: [ManagedHost]) async throws
    func loadInventorySnapshots() async throws -> [InventorySnapshot]
    func saveInventorySnapshot(_ snapshot: InventorySnapshot) async throws
}

public actor InMemoryKitroomPersistence: KitroomPersistence {
    private var hosts: [ManagedHost]
    private var snapshots: [InventorySnapshot]

    public init(
        hosts: [ManagedHost] = [],
        snapshots: [InventorySnapshot] = []
    ) {
        self.hosts = hosts
        self.snapshots = snapshots
    }

    public func loadHosts() -> [ManagedHost] {
        hosts
    }

    public func saveHosts(_ hosts: [ManagedHost]) {
        self.hosts = hosts
    }

    public func loadInventorySnapshots() -> [InventorySnapshot] {
        snapshots
    }

    public func saveInventorySnapshot(_ snapshot: InventorySnapshot) {
        snapshots.removeAll {
            $0.hostID == snapshot.hostID && $0.agent == snapshot.agent
        }
        snapshots.append(snapshot)
    }
}
