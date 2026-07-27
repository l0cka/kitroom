import Foundation

struct ParsedAgentInventory: Sendable {
    var sources: [CatalogSource] = []
    var packages: [PackageRecord] = []
    var capabilities: [ProvidedCapability] = []
    var installations: [InstallationRecord] = []
}

struct CodexSkillConfigurationOverride: Hashable, Sendable {
    let path: String
    let enabled: Bool
}

enum CodexInventoryParser {
    static let parserVersion = "codex-inventory-v1"

    static func parsePlugins(
        _ data: Data,
        hostID: ManagedHost.ID,
        capturedAt: Date,
        evidenceID: EvidenceRecord.ID? = nil
    ) throws -> ParsedAgentInventory {
        let envelope = try JSONDecoder().decode(PluginEnvelope.self, from: data)
        var inventory = ParsedAgentInventory()
        var seenSources = Set<String>()

        for plugin in envelope.installed where plugin.installed != false {
            let sourceID = "codex:marketplace:\(plugin.marketplaceName ?? "unknown")"
            if seenSources.insert(sourceID).inserted {
                inventory.sources.append(
                    CatalogSource(
                        id: sourceID,
                        agent: .codex,
                        name: plugin.marketplaceName ?? "Unknown marketplace",
                        kind: sourceKind(plugin),
                        reference: plugin.marketplaceSource?.source,
                        localRoot: plugin.marketplaceSource?.path,
                        capturedAt: capturedAt,
                        evidenceIDs: evidenceID.map { [$0] } ?? []
                    )
                )
            }

            let packageID = "codex:plugin:\(plugin.pluginID)"
            inventory.packages.append(
                PackageRecord(
                    id: packageID,
                    agent: .codex,
                    name: plugin.name,
                    sourceID: sourceID,
                    version: plugin.version,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
            inventory.installations.append(
                InstallationRecord(
                    id: InventoryIdentifier.make(
                        hostID.uuidString,
                        packageID,
                        "plugin"
                    ),
                    hostID: hostID,
                    agent: .codex,
                    packageID: packageID,
                    scope: .user,
                    origin: sourceKind(plugin) == .bundled ? .bundled : .marketplace,
                    state: plugin.enabled == false ? .disabled : .enabled,
                    installedVersion: plugin.version,
                    physicalOrigin: plugin.source?.path,
                    restriction: restriction(plugin.installPolicy),
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
        }

        return inventory
    }

    static func parseMarketplaces(
        _ data: Data,
        capturedAt: Date,
        evidenceID: EvidenceRecord.ID? = nil
    ) throws -> [CatalogSource] {
        let envelope = try JSONDecoder().decode(MarketplaceEnvelope.self, from: data)
        return envelope.marketplaces.map { marketplace in
            let kind = marketplaceKind(marketplace)
            return CatalogSource(
                id: "codex:marketplace:\(marketplace.name)",
                agent: .codex,
                name: marketplace.name,
                kind: kind,
                reference: kind == .local
                    ? marketplace.root
                        ?? marketplace.marketplaceSource?.source
                    : marketplace.marketplaceSource?.source
                        ?? marketplace.root,
                localRoot: marketplace.root,
                revision: marketplace.marketplaceSource?.revision,
                capturedAt: capturedAt,
                evidenceIDs: evidenceID.map { [$0] } ?? []
            )
        }
    }

    static func parseMCPServers(
        _ data: Data,
        hostID: ManagedHost.ID,
        evidenceID: EvidenceRecord.ID? = nil
    ) throws -> ParsedAgentInventory {
        let servers = try JSONDecoder().decode([MCPServer].self, from: data)
        var inventory = ParsedAgentInventory()

        for server in servers {
            let capabilityID = InventoryIdentifier.make(
                "codex",
                "mcp",
                server.name
            )
            inventory.capabilities.append(
                ProvidedCapability(
                    id: capabilityID,
                    agent: .codex,
                    kind: .mcpServer,
                    name: server.name,
                    displayName: server.name,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )

            let state: EffectiveState
            if server.enabled == false {
                state = .disabled
            } else if server.disabledReason != nil {
                state = .unavailable
            } else if server.authStatus?.lowercased().contains("pending") == true {
                state = .pendingApproval
            } else {
                state = .configured
            }
            inventory.installations.append(
                InstallationRecord(
                    id: InventoryIdentifier.make(
                        hostID.uuidString,
                        capabilityID,
                        "mcp"
                    ),
                    hostID: hostID,
                    agent: .codex,
                    capabilityID: capabilityID,
                    scope: .user,
                    origin: .standalone,
                    state: state,
                    restriction: .agentManaged,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
        }

        return inventory
    }

    static func parseSkillConfiguration(
        _ value: String
    ) throws -> [CodexSkillConfigurationOverride] {
        var overrides: [CodexSkillConfigurationOverride] = []
        var inSkillConfiguration = false
        var path: String?
        var enabled: Bool?

        func appendCurrent() throws {
            guard inSkillConfiguration else {
                return
            }
            if path == nil, enabled == nil {
                return
            }
            guard let path else {
                throw AdapterError.invalidInventory(
                    "A skills.config entry has an enabled value but no path."
                )
            }
            overrides.append(
                CodexSkillConfigurationOverride(
                    path: path,
                    enabled: enabled ?? true
                )
            )
        }

        for rawLine in value.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "[[skills.config]]" {
                try appendCurrent()
                inSkillConfiguration = true
                path = nil
                enabled = nil
                continue
            }
            if line.hasPrefix("[") {
                try appendCurrent()
                inSkillConfiguration = false
                path = nil
                enabled = nil
                continue
            }
            guard inSkillConfiguration,
                  !line.isEmpty,
                  !line.hasPrefix("#")
            else {
                continue
            }

            let fields = line.split(separator: "=", maxSplits: 1)
            guard fields.count == 2 else {
                continue
            }
            let key = fields[0].trimmingCharacters(in: .whitespaces)
            let rawValue = fields[1]
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "path":
                guard rawValue.count >= 2,
                      let first = rawValue.first,
                      let last = rawValue.last,
                      (first == "\"" && last == "\"")
                        || (first == "'" && last == "'")
                else {
                    throw AdapterError.invalidInventory(
                        "A skills.config path is not a quoted string."
                    )
                }
                path = String(rawValue.dropFirst().dropLast())
            case "enabled":
                if rawValue == "true" {
                    enabled = true
                } else if rawValue == "false" {
                    enabled = false
                } else {
                    throw AdapterError.invalidInventory(
                        "A skills.config enabled value is not a Boolean."
                    )
                }
            default:
                continue
            }
        }

        try appendCurrent()
        return overrides
    }

    private static func sourceKind(_ plugin: Plugin) -> PackageSourceKind {
        let marketplace = plugin.marketplaceName?.lowercased() ?? ""
        if marketplace.contains("bundled") || marketplace.contains("runtime") {
            return .bundled
        }
        switch plugin.marketplaceSource?.sourceType?.lowercased() {
        case "git", "github":
            return .git
        case "url":
            return .url
        case "local":
            return .local
        default:
            return .marketplace
        }
    }

    private static func marketplaceKind(
        _ marketplace: Marketplace
    ) -> PackageSourceKind {
        let name = marketplace.name.lowercased()
        if name.contains("bundled") || name.contains("runtime") {
            return .bundled
        }
        switch marketplace.marketplaceSource?.sourceType?.lowercased() {
        case "git", "github":
            return .git
        case "url":
            return .url
        case "local":
            return .local
        default:
            return .marketplace
        }
    }

    private static func restriction(_ installPolicy: String?) -> ManagementRestriction {
        switch installPolicy?.uppercased() {
        case "REQUIRED", "MANAGED":
            return .administratorManaged
        case "BLOCKED":
            return .readOnly
        case "AVAILABLE":
            return .agentManaged
        default:
            return .unknown
        }
    }
}

private extension CodexInventoryParser {
    struct PluginEnvelope: Decodable {
        let installed: [Plugin]
    }

    struct Plugin: Decodable {
        let pluginID: String
        let name: String
        let marketplaceName: String?
        let version: String?
        let installed: Bool?
        let enabled: Bool?
        let source: Source?
        let marketplaceSource: Source?
        let installPolicy: String?

        enum CodingKeys: String, CodingKey {
            case pluginID = "pluginId"
            case name
            case marketplaceName
            case version
            case installed
            case enabled
            case source
            case marketplaceSource
            case installPolicy
        }
    }

    struct MarketplaceEnvelope: Decodable {
        let marketplaces: [Marketplace]
    }

    struct Marketplace: Decodable {
        let name: String
        let root: String?
        let marketplaceSource: Source?
    }

    struct Source: Decodable {
        let source: String?
        let path: String?
        let sourceType: String?
        let revision: String?
        let sha: String?
        let url: String?
    }

    struct MCPServer: Decodable {
        let name: String
        let enabled: Bool?
        let disabledReason: String?
        let authStatus: String?

        enum CodingKeys: String, CodingKey {
            case name
            case enabled
            case disabledReason = "disabled_reason"
            case authStatus = "auth_status"
        }
    }
}
