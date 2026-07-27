import Foundation
import SwiftData

@Model
final class KitroomStoredRecord {
    @Attribute(.unique) var key: String
    var kind: String
    var schemaVersion: Int
    var createdAt: Date
    var updatedAt: Date
    @Attribute(.externalStorage) var payload: Data

    init(
        key: String,
        kind: String,
        schemaVersion: Int = 1,
        createdAt: Date,
        updatedAt: Date,
        payload: Data
    ) {
        self.key = key
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payload = payload
    }
}

public actor SwiftDataKitroomPersistence: KitroomPersistence {
    public static let currentSchemaVersion = 1

    private enum RecordKind: String {
        case hosts
        case hostDiscovery
        case inventory
        case catalogue
        case operation
    }

    private let container: ModelContainer
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let historyLimitPerGrain: Int

    public init(
        storeURL: URL,
        historyLimitPerGrain: Int = 50
    ) throws {
        let schema = Schema([KitroomStoredRecord.self])
        let configuration = ModelConfiguration(
            "Kitroom",
            schema: schema,
            url: storeURL,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        self.historyLimitPerGrain = max(1, historyLimitPerGrain)
    }

    public static func live(
        fileManager: FileManager = .default
    ) throws -> SwiftDataKitroomPersistence {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport
            .appendingPathComponent("Kitroom", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return try SwiftDataKitroomPersistence(
            storeURL: directory.appendingPathComponent("Kitroom.store")
        )
    }

    public func loadHosts() throws -> [ManagedHost] {
        guard let record = try records(kind: .hosts)
            .max(by: { $0.updatedAt < $1.updatedAt })
        else {
            return []
        }
        return try decode([ManagedHost].self, from: record)
    }

    public func saveHosts(_ hosts: [ManagedHost]) throws {
        let context = ModelContext(container)
        let existing = try fetchAll(in: context)
            .filter { $0.kind == RecordKind.hosts.rawValue }
        let now = Date()
        let payload = try encoder.encode(hosts)

        if let record = existing.first {
            record.payload = payload
            record.schemaVersion = Self.currentSchemaVersion
            record.updatedAt = now
            for duplicate in existing.dropFirst() {
                context.delete(duplicate)
            }
        } else {
            context.insert(
                KitroomStoredRecord(
                    key: "hosts:current",
                    kind: RecordKind.hosts.rawValue,
                    createdAt: now,
                    updatedAt: now,
                    payload: payload
                )
            )
        }
        try context.save()
    }

    public func loadHostDiscoverySnapshots() throws -> [HostDiscoverySnapshot] {
        let snapshots = try records(kind: .hostDiscovery)
            .map { try decode(HostDiscoverySnapshot.self, from: $0) }
        return latestDiscoverySnapshots(from: snapshots)
    }

    public func loadHostDiscoveryHistory(
        hostID: ManagedHost.ID? = nil,
        limit: Int = 50
    ) throws -> [HostDiscoverySnapshot] {
        try records(kind: .hostDiscovery)
            .map { try decode(HostDiscoverySnapshot.self, from: $0) }
            .filter { hostID == nil || $0.hostID == hostID }
            .sorted { $0.attemptedAt > $1.attemptedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func saveHostDiscoverySnapshot(
        _ snapshot: HostDiscoverySnapshot
    ) throws {
        let context = ModelContext(container)
        let now = Date()
        context.insert(
            KitroomStoredRecord(
                key: historyKey(
                    prefix: RecordKind.hostDiscovery.rawValue,
                    hostID: snapshot.hostID,
                    agent: nil,
                    timestamp: snapshot.attemptedAt
                ),
                kind: RecordKind.hostDiscovery.rawValue,
                createdAt: now,
                updatedAt: now,
                payload: try encoder.encode(snapshot)
            )
        )
        try trimDiscoveryHistory(in: context, hostID: snapshot.hostID)
        try context.save()
    }

    public func loadInventorySnapshots() throws -> [InventorySnapshot] {
        latestInventorySnapshots(from: try allInventorySnapshots())
    }

    public func loadInventoryHistory(
        hostID: ManagedHost.ID? = nil,
        agent: AgentKind? = nil,
        limit: Int = 50
    ) throws -> [InventorySnapshot] {
        try allInventorySnapshots()
            .filter { snapshot in
                (hostID == nil || snapshot.hostID == hostID)
                    && (agent == nil || snapshot.agent == agent)
            }
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func saveInventorySnapshot(_ snapshot: InventorySnapshot) throws {
        let context = ModelContext(container)
        let now = Date()
        context.insert(
            KitroomStoredRecord(
                key: historyKey(
                    prefix: RecordKind.inventory.rawValue,
                    hostID: snapshot.hostID,
                    agent: snapshot.agent,
                    timestamp: snapshot.capturedAt
                ),
                kind: RecordKind.inventory.rawValue,
                createdAt: now,
                updatedAt: now,
                payload: try encoder.encode(snapshot)
            )
        )
        try trimInventoryHistory(
            in: context,
            hostID: snapshot.hostID,
            agent: snapshot.agent
        )
        try context.save()
    }

    public func loadCatalogueSnapshots() throws -> [CatalogueSnapshot] {
        latestCatalogueSnapshots(from: try allCatalogueSnapshots())
    }

    public func loadCatalogueHistory(
        hostID: ManagedHost.ID? = nil,
        agent: AgentKind? = nil,
        limit: Int = 50
    ) throws -> [CatalogueSnapshot] {
        try allCatalogueSnapshots()
            .filter { snapshot in
                (hostID == nil || snapshot.hostID == hostID)
                    && (agent == nil || snapshot.agent == agent)
            }
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func saveCatalogueSnapshot(_ snapshot: CatalogueSnapshot) throws {
        let context = ModelContext(container)
        let now = Date()
        context.insert(
            KitroomStoredRecord(
                key: historyKey(
                    prefix: RecordKind.catalogue.rawValue,
                    hostID: snapshot.hostID,
                    agent: snapshot.agent,
                    timestamp: snapshot.capturedAt
                ),
                kind: RecordKind.catalogue.rawValue,
                createdAt: now,
                updatedAt: now,
                payload: try encoder.encode(snapshot)
            )
        )
        try trimCatalogueHistory(
            in: context,
            hostID: snapshot.hostID,
            agent: snapshot.agent
        )
        try context.save()
    }

    public func loadOperationRecords(
        limit: Int = 200
    ) throws -> [OperationRecord] {
        try records(kind: .operation)
            .map { try decode(OperationRecord.self, from: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    public func saveOperationRecord(_ record: OperationRecord) throws {
        let context = ModelContext(container)
        let key = "\(RecordKind.operation.rawValue):\(record.id.uuidString)"
        let existing = try fetchAll(in: context).filter {
            $0.kind == RecordKind.operation.rawValue && $0.key == key
        }
        let now = Date()
        let payload = try encoder.encode(record)
        if let stored = existing.first {
            stored.payload = payload
            stored.schemaVersion = Self.currentSchemaVersion
            stored.updatedAt = now
            for duplicate in existing.dropFirst() {
                context.delete(duplicate)
            }
        } else {
            context.insert(
                KitroomStoredRecord(
                    key: key,
                    kind: RecordKind.operation.rawValue,
                    createdAt: now,
                    updatedAt: now,
                    payload: payload
                )
            )
        }
        try trimOperationHistory(in: context)
        try context.save()
    }

    private func allInventorySnapshots() throws -> [InventorySnapshot] {
        try records(kind: .inventory)
            .map { try decode(InventorySnapshot.self, from: $0) }
    }

    private func allCatalogueSnapshots() throws -> [CatalogueSnapshot] {
        try records(kind: .catalogue)
            .map { try decode(CatalogueSnapshot.self, from: $0) }
    }

    private func records(
        kind: RecordKind
    ) throws -> [KitroomStoredRecord] {
        let context = ModelContext(container)
        return try fetchAll(in: context)
            .filter { $0.kind == kind.rawValue }
    }

    private func fetchAll(
        in context: ModelContext
    ) throws -> [KitroomStoredRecord] {
        try context.fetch(FetchDescriptor<KitroomStoredRecord>())
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from record: KitroomStoredRecord
    ) throws -> Value {
        guard record.schemaVersion <= Self.currentSchemaVersion else {
            throw SwiftDataPersistenceError.unsupportedSchemaVersion(
                record.schemaVersion
            )
        }
        return try decoder.decode(type, from: record.payload)
    }

    private func trimDiscoveryHistory(
        in context: ModelContext,
        hostID: ManagedHost.ID
    ) throws {
        let matching = try fetchAll(in: context)
            .filter { $0.kind == RecordKind.hostDiscovery.rawValue }
            .map { record -> (KitroomStoredRecord, HostDiscoverySnapshot) in
                let snapshot = try decode(
                    HostDiscoverySnapshot.self,
                    from: record
                )
                return (record, snapshot)
            }
            .filter { $0.1.hostID == hostID }
            .sorted { $0.1.attemptedAt > $1.1.attemptedAt }

        for (record, _) in matching.dropFirst(historyLimitPerGrain) {
            context.delete(record)
        }
    }

    private func trimInventoryHistory(
        in context: ModelContext,
        hostID: ManagedHost.ID,
        agent: AgentKind
    ) throws {
        let matching = try fetchAll(in: context)
            .filter { $0.kind == RecordKind.inventory.rawValue }
            .map { record -> (KitroomStoredRecord, InventorySnapshot) in
                let snapshot = try decode(
                    InventorySnapshot.self,
                    from: record
                )
                return (record, snapshot)
            }
            .filter {
                $0.1.hostID == hostID && $0.1.agent == agent
            }
            .sorted { $0.1.capturedAt > $1.1.capturedAt }

        for (record, _) in matching.dropFirst(historyLimitPerGrain) {
            context.delete(record)
        }
    }

    private func trimCatalogueHistory(
        in context: ModelContext,
        hostID: ManagedHost.ID,
        agent: AgentKind
    ) throws {
        let matching = try fetchAll(in: context)
            .filter { $0.kind == RecordKind.catalogue.rawValue }
            .map { record -> (KitroomStoredRecord, CatalogueSnapshot) in
                let snapshot = try decode(
                    CatalogueSnapshot.self,
                    from: record
                )
                return (record, snapshot)
            }
            .filter {
                $0.1.hostID == hostID && $0.1.agent == agent
            }
            .sorted { $0.1.capturedAt > $1.1.capturedAt }

        for (record, _) in matching.dropFirst(historyLimitPerGrain) {
            context.delete(record)
        }
    }

    private func trimOperationHistory(
        in context: ModelContext
    ) throws {
        let matching = try fetchAll(in: context)
            .filter { $0.kind == RecordKind.operation.rawValue }
            .map { record -> (KitroomStoredRecord, OperationRecord) in
                (record, try decode(OperationRecord.self, from: record))
            }
            .sorted { $0.1.updatedAt > $1.1.updatedAt }

        for (record, _) in matching.dropFirst(
            max(200, historyLimitPerGrain)
        ) {
            context.delete(record)
        }
    }

    private func historyKey(
        prefix: String,
        hostID: ManagedHost.ID,
        agent: AgentKind?,
        timestamp: Date
    ) -> String {
        [
            prefix,
            hostID.uuidString,
            agent?.rawValue ?? "host",
            String(timestamp.timeIntervalSince1970),
            UUID().uuidString
        ]
        .joined(separator: ":")
    }
}

public enum SwiftDataPersistenceError: LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            "The Kitroom store uses unsupported schema version \(version)."
        }
    }
}
