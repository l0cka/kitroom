import Foundation

public enum InventoryStatus: String, Codable, Hashable, Sendable {
    case complete
    case partial
    case unavailable
}

public struct InventoryContext: Codable, Hashable, Sendable {
    public let workingDirectory: String?

    public init(workingDirectory: String? = nil) {
        let normalized = workingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.workingDirectory = normalized?.isEmpty == false ? normalized : nil
    }

    public static let hostOnly = InventoryContext()
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
    public let agentVersion: String?
    public let capabilities: [AdapterCapabilityReport]
    public let catalogSources: [CatalogSource]
    public let packages: [PackageRecord]
    public let providedCapabilities: [ProvidedCapability]
    public let installations: [InstallationRecord]
    public let evidence: [EvidenceRecord]
    public let issues: [InventoryIssue]

    public init(
        hostID: ManagedHost.ID,
        agent: AgentKind,
        capturedAt: Date,
        status: InventoryStatus,
        agentVersion: String? = nil,
        capabilities: [AdapterCapabilityReport] = [],
        catalogSources: [CatalogSource] = [],
        packages: [PackageRecord] = [],
        providedCapabilities: [ProvidedCapability] = [],
        installations: [InstallationRecord] = [],
        evidence: [EvidenceRecord] = [],
        issues: [InventoryIssue] = []
    ) {
        self.hostID = hostID
        self.agent = agent
        self.capturedAt = capturedAt
        self.status = status
        self.agentVersion = agentVersion
        self.capabilities = capabilities
        self.catalogSources = catalogSources
        self.packages = packages
        self.providedCapabilities = providedCapabilities
        self.installations = installations
        self.evidence = evidence
        self.issues = issues
    }
}
