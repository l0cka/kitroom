public enum AdapterFeature: String, CaseIterable, Codable, Hashable, Sendable {
    case pluginInventory
    case marketplaceInventory
    case catalogueInventory
    case skillInventory
    case mcpInventory
    case pluginDetails
    case installPlugin
    case updatePlugin
    case enablePlugin
    case disablePlugin
    case uninstallPlugin
}

public enum CapabilitySupport: String, Codable, Hashable, Sendable {
    case supported
    case unsupported
    case unknown
}

public struct AdapterCapabilityReport: Codable, Hashable, Sendable {
    public let feature: AdapterFeature
    public let support: CapabilitySupport
    public let evidenceID: EvidenceRecord.ID?

    public init(
        feature: AdapterFeature,
        support: CapabilitySupport,
        evidenceID: EvidenceRecord.ID? = nil
    ) {
        self.feature = feature
        self.support = support
        self.evidenceID = evidenceID
    }
}
