import Foundation

enum ClaudeInventoryParser {
    static let parserVersion = "claude-inventory-v1"

    static func parsePlugins(
        _ data: Data,
        hostID: ManagedHost.ID,
        capturedAt: Date,
        evidenceID: EvidenceRecord.ID? = nil
    ) throws -> ParsedAgentInventory {
        let plugins = try JSONDecoder().decode([InstalledPlugin].self, from: data)
        var inventory = ParsedAgentInventory()
        var seenSources = Set<String>()

        for plugin in plugins {
            let identity = PluginIdentity(plugin.id)
            let sourceID = "claude:marketplace:\(identity.marketplace)"
            if seenSources.insert(sourceID).inserted {
                inventory.sources.append(
                    CatalogSource(
                        id: sourceID,
                        agent: .claude,
                        name: identity.marketplace,
                        kind: .marketplace,
                        capturedAt: capturedAt,
                        evidenceIDs: evidenceID.map { [$0] } ?? []
                    )
                )
            }

            let packageID = "claude:plugin:\(plugin.id)"
            inventory.packages.append(
                PackageRecord(
                    id: packageID,
                    agent: .claude,
                    name: identity.name,
                    sourceID: sourceID,
                    version: plugin.version,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
            let scope = InventoryScope(claudeScope: plugin.scope)
            inventory.installations.append(
                InstallationRecord(
                    id: InventoryIdentifier.make(
                        hostID.uuidString,
                        packageID,
                        scope.rawValue
                    ),
                    hostID: hostID,
                    agent: .claude,
                    packageID: packageID,
                    scope: scope,
                    origin: .marketplace,
                    state: plugin.enabled == false ? .disabled : .enabled,
                    installedVersion: plugin.version,
                    physicalOrigin: plugin.installPath,
                    restriction: scope == .managed
                        ? .administratorManaged
                        : .agentManaged,
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
        let marketplaces = try JSONDecoder().decode([Marketplace].self, from: data)
        return marketplaces.map {
            CatalogSource(
                id: "claude:marketplace:\($0.name)",
                agent: .claude,
                name: $0.name,
                kind: $0.source.lowercased() == "github" ? .git : .marketplace,
                reference: $0.repo,
                capturedAt: capturedAt,
                evidenceIDs: evidenceID.map { [$0] } ?? []
            )
        }
    }
}

private extension ClaudeInventoryParser {
    struct InstalledPlugin: Decodable {
        let id: String
        let version: String?
        let scope: String?
        let enabled: Bool?
        let installPath: String?
    }

    struct Marketplace: Decodable {
        let name: String
        let source: String
        let repo: String?
    }

    struct PluginIdentity {
        let name: String
        let marketplace: String

        init(_ value: String) {
            let fields = value.split(separator: "@", maxSplits: 1).map(String.init)
            name = fields.first ?? value
            marketplace = fields.count == 2 ? fields[1] : "unknown"
        }
    }
}

private extension InventoryScope {
    init(claudeScope: String?) {
        switch claudeScope?.lowercased() {
        case "user":
            self = .user
        case "project":
            self = .repository
        case "local":
            self = .localProject
        case "managed":
            self = .managed
        default:
            self = .unknown
        }
    }
}
