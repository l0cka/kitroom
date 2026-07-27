import Foundation

public enum InventoryScope: String, Codable, Hashable, Sendable {
    case user
    case repository
    case localProject
    case managed
    case system
    case session
    case unknown
}

public enum PackageSourceKind: String, Codable, Hashable, Sendable {
    case marketplace
    case local
    case git
    case url
    case bundled
    case managed
    case unknown
}

public struct CatalogSource: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let agent: AgentKind
    public let name: String
    public let kind: PackageSourceKind
    public let reference: String?
    public let localRoot: String?
    public let revision: String?
    public let capturedAt: Date
    public let evidenceIDs: [EvidenceRecord.ID]

    public init(
        id: String,
        agent: AgentKind,
        name: String,
        kind: PackageSourceKind,
        reference: String? = nil,
        localRoot: String? = nil,
        revision: String? = nil,
        capturedAt: Date,
        evidenceIDs: [EvidenceRecord.ID] = []
    ) {
        self.id = id
        self.agent = agent
        self.name = name
        self.kind = kind
        self.reference = reference
        self.localRoot = localRoot
        self.revision = revision
        self.capturedAt = capturedAt
        self.evidenceIDs = evidenceIDs
    }
}

public struct PackageRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let agent: AgentKind
    public let name: String
    public let displayName: String
    public let sourceID: CatalogSource.ID?
    public let publisher: String?
    public let description: String?
    public let version: String?
    public let revision: String?
    public let manifestDigest: String?
    public let evidenceIDs: [EvidenceRecord.ID]

    public init(
        id: String,
        agent: AgentKind,
        name: String,
        displayName: String? = nil,
        sourceID: CatalogSource.ID? = nil,
        publisher: String? = nil,
        description: String? = nil,
        version: String? = nil,
        revision: String? = nil,
        manifestDigest: String? = nil,
        evidenceIDs: [EvidenceRecord.ID] = []
    ) {
        self.id = id
        self.agent = agent
        self.name = name
        self.displayName = displayName ?? name
        self.sourceID = sourceID
        self.publisher = publisher
        self.description = description
        self.version = version
        self.revision = revision
        self.manifestDigest = manifestDigest
        self.evidenceIDs = evidenceIDs
    }
}

public enum CapabilityKind: String, Codable, Hashable, Sendable {
    case skill
    case mcpServer
    case hook
    case subagent
    case connector
    case lspServer
    case command
    case executable
    case other
}

public struct ProvidedCapability: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let agent: AgentKind
    public let packageID: PackageRecord.ID?
    public let kind: CapabilityKind
    public let name: String
    public let displayName: String
    public let relativePath: String?
    public let contentDigest: String?
    public let evidenceIDs: [EvidenceRecord.ID]

    public init(
        id: String,
        agent: AgentKind,
        packageID: PackageRecord.ID? = nil,
        kind: CapabilityKind,
        name: String,
        displayName: String? = nil,
        relativePath: String? = nil,
        contentDigest: String? = nil,
        evidenceIDs: [EvidenceRecord.ID] = []
    ) {
        self.id = id
        self.agent = agent
        self.packageID = packageID
        self.kind = kind
        self.name = name
        self.displayName = displayName ?? name
        self.relativePath = relativePath
        self.contentDigest = contentDigest
        self.evidenceIDs = evidenceIDs
    }
}

public enum InstallationOrigin: String, Codable, Hashable, Sendable {
    case standalone
    case marketplace
    case pluginProvided
    case shared
    case legacy
    case runtimeInjected
    case bundled
    case unknown
}

public enum EffectiveState: String, Codable, Hashable, Sendable {
    case configured
    case enabled
    case disabled
    case pendingApproval
    case unavailable
    case unhealthy
    case unknown
}

public enum ManagementRestriction: String, Codable, Hashable, Sendable {
    case userManaged
    case agentManaged
    case administratorManaged
    case readOnly
    case unknown
}

public struct InstallationRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let hostID: ManagedHost.ID
    public let agent: AgentKind
    public let packageID: PackageRecord.ID?
    public let capabilityID: ProvidedCapability.ID?
    public let scope: InventoryScope
    public let origin: InstallationOrigin
    public let state: EffectiveState
    public let installedVersion: String?
    public let updateStatus: UpdateStatus?
    public let physicalOrigin: String?
    public let restriction: ManagementRestriction
    public let evidenceIDs: [EvidenceRecord.ID]

    public init(
        id: String,
        hostID: ManagedHost.ID,
        agent: AgentKind,
        packageID: PackageRecord.ID? = nil,
        capabilityID: ProvidedCapability.ID? = nil,
        scope: InventoryScope,
        origin: InstallationOrigin,
        state: EffectiveState,
        installedVersion: String? = nil,
        updateStatus: UpdateStatus? = nil,
        physicalOrigin: String? = nil,
        restriction: ManagementRestriction = .unknown,
        evidenceIDs: [EvidenceRecord.ID] = []
    ) {
        self.id = id
        self.hostID = hostID
        self.agent = agent
        self.packageID = packageID
        self.capabilityID = capabilityID
        self.scope = scope
        self.origin = origin
        self.state = state
        self.installedVersion = installedVersion
        self.updateStatus = updateStatus
        self.physicalOrigin = physicalOrigin
        self.restriction = restriction
        self.evidenceIDs = evidenceIDs
    }
}

public enum EvidenceStatus: String, Codable, Hashable, Sendable {
    case success
    case partial
    case failure
}

public struct EvidenceRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let probeName: String
    public let sourceReference: String
    public let capturedAt: Date
    public let parserVersion: String
    public let status: EvidenceStatus
    public let diagnostic: String?

    public init(
        id: String,
        probeName: String,
        sourceReference: String,
        capturedAt: Date,
        parserVersion: String,
        status: EvidenceStatus,
        diagnostic: String? = nil
    ) {
        self.id = id
        self.probeName = probeName
        self.sourceReference = sourceReference
        self.capturedAt = capturedAt
        self.parserVersion = parserVersion
        self.status = status
        self.diagnostic = diagnostic
    }
}
