import Foundation

public enum CatalogueCompatibility: String, Codable, Hashable, Sendable {
    case compatible
    case incompatible
    case unknown
}

public enum CatalogueIntegrity: String, Codable, Hashable, Sendable {
    case digestVerified
    case digestDeclared
    case unverified
    case unknown
}

public struct CataloguePackageState: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let hostID: ManagedHost.ID
    public let agent: AgentKind
    public let packageID: PackageRecord.ID
    public let installedVersion: String?
    public let availableVersion: String?
    public let updateStatus: UpdateStatus
    public let restriction: ManagementRestriction
    public let compatibility: CatalogueCompatibility
    public let integrity: CatalogueIntegrity
    public let evidenceIDs: [EvidenceRecord.ID]

    public init(
        id: String,
        hostID: ManagedHost.ID,
        agent: AgentKind,
        packageID: PackageRecord.ID,
        installedVersion: String? = nil,
        availableVersion: String? = nil,
        updateStatus: UpdateStatus,
        restriction: ManagementRestriction = .unknown,
        compatibility: CatalogueCompatibility = .unknown,
        integrity: CatalogueIntegrity = .unknown,
        evidenceIDs: [EvidenceRecord.ID] = []
    ) {
        self.id = id
        self.hostID = hostID
        self.agent = agent
        self.packageID = packageID
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.updateStatus = updateStatus
        self.restriction = restriction
        self.compatibility = compatibility
        self.integrity = integrity
        self.evidenceIDs = evidenceIDs
    }
}

public struct CatalogueSnapshot: Codable, Hashable, Sendable {
    public let hostID: ManagedHost.ID
    public let agent: AgentKind
    public let capturedAt: Date
    public let status: InventoryStatus
    public let agentVersion: String?
    public let capabilities: [AdapterCapabilityReport]
    public let sources: [CatalogSource]
    public let packages: [PackageRecord]
    public let providedCapabilities: [ProvidedCapability]
    public let packageStates: [CataloguePackageState]
    public let evidence: [EvidenceRecord]
    public let issues: [InventoryIssue]

    public init(
        hostID: ManagedHost.ID,
        agent: AgentKind,
        capturedAt: Date,
        status: InventoryStatus,
        agentVersion: String? = nil,
        capabilities: [AdapterCapabilityReport] = [],
        sources: [CatalogSource] = [],
        packages: [PackageRecord] = [],
        providedCapabilities: [ProvidedCapability] = [],
        packageStates: [CataloguePackageState] = [],
        evidence: [EvidenceRecord] = [],
        issues: [InventoryIssue] = []
    ) {
        self.hostID = hostID
        self.agent = agent
        self.capturedAt = capturedAt
        self.status = status
        self.agentVersion = agentVersion
        self.capabilities = capabilities
        self.sources = sources
        self.packages = packages
        self.providedCapabilities = providedCapabilities
        self.packageStates = packageStates
        self.evidence = evidence
        self.issues = issues
    }
}

public extension InstallationRecord {
    func withUpdateStatus(_ updateStatus: UpdateStatus?) -> InstallationRecord {
        InstallationRecord(
            id: id,
            hostID: hostID,
            agent: agent,
            packageID: packageID,
            capabilityID: capabilityID,
            scope: scope,
            origin: origin,
            state: state,
            installedVersion: installedVersion,
            updateStatus: updateStatus,
            physicalOrigin: physicalOrigin,
            restriction: restriction,
            evidenceIDs: evidenceIDs
        )
    }
}

public extension InventorySnapshot {
    func annotated(with catalogue: CatalogueSnapshot?) -> InventorySnapshot {
        guard let catalogue, catalogue.hostID == hostID,
              catalogue.agent == agent else {
            return self
        }
        let states = Dictionary(
            uniqueKeysWithValues: catalogue.packageStates.map {
                ($0.packageID, $0.updateStatus)
            }
        )
        return InventorySnapshot(
            hostID: hostID,
            agent: agent,
            capturedAt: capturedAt,
            status: status,
            agentVersion: agentVersion,
            capabilities: capabilities,
            catalogSources: catalogSources,
            packages: packages,
            providedCapabilities: providedCapabilities,
            installations: installations.map { installation in
                guard let packageID = installation.packageID else {
                    return installation
                }
                return installation.withUpdateStatus(states[packageID])
            },
            evidence: evidence,
            issues: issues
        )
    }
}
