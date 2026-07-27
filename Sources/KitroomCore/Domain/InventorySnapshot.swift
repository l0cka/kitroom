import Foundation

public enum InventoryStatus: String, Codable, Hashable, Sendable {
    case complete
    case partial
    case unavailable
}

public struct InventoryIssue: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let summary: String
    public let detail: String

    public init(
        id: UUID = UUID(),
        summary: String,
        detail: String
    ) {
        self.id = id
        self.summary = summary
        self.detail = detail
    }
}

public struct InventorySnapshot: Codable, Hashable, Sendable {
    public let hostID: ManagedHost.ID
    public let agent: AgentKind
    public let capturedAt: Date
    public let status: InventoryStatus
    public let extensions: [ManagedExtension]
    public let issues: [InventoryIssue]

    public init(
        hostID: ManagedHost.ID,
        agent: AgentKind,
        capturedAt: Date,
        status: InventoryStatus,
        extensions: [ManagedExtension],
        issues: [InventoryIssue] = []
    ) {
        self.hostID = hostID
        self.agent = agent
        self.capturedAt = capturedAt
        self.status = status
        self.extensions = extensions
        self.issues = issues
    }
}

