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
                localRoot: $0.installLocation,
                capturedAt: capturedAt,
                evidenceIDs: evidenceID.map { [$0] } ?? []
            )
        }
    }

    static func parseCatalogue(
        _ data: Data,
        hostID: ManagedHost.ID,
        capturedAt: Date,
        installedInventory: InventorySnapshot?,
        marketplaces: [CatalogSource],
        evidenceID: EvidenceRecord.ID? = nil
    ) throws -> ParsedCatalogue {
        let envelope = try JSONDecoder().decode(
            AvailablePluginEnvelope.self,
            from: data
        )
        var result = ParsedCatalogue()
        var seenSources = Set<String>()
        let installedByID = Dictionary(
            uniqueKeysWithValues: envelope.installed.map {
                ($0.id, $0)
            }
        )
        let availableIDs = Set(envelope.available.map(\.pluginID))
        let marketplaceRoots: [String: String] = Dictionary(
            uniqueKeysWithValues: marketplaces.compactMap { source in
                guard let root = source.localRoot else {
                    return nil as (String, String)?
                }
                return (source.name, root)
            }
        )

        for plugin in envelope.available {
            let sourceID = "claude:marketplace:\(plugin.marketplaceName)"
            if seenSources.insert(sourceID).inserted {
                let known = marketplaces.first { $0.id == sourceID }
                result.sources.append(
                    known ?? CatalogSource(
                        id: sourceID,
                        agent: .claude,
                        name: plugin.marketplaceName,
                        kind: plugin.source.kind,
                        reference: plugin.source.reference,
                        capturedAt: capturedAt,
                        evidenceIDs: evidenceID.map { [$0] } ?? []
                    )
                )
            }

            let packageID = "claude:plugin:\(plugin.pluginID)"
            let installedVersion = CatalogueVersionJoin.installedVersion(
                packageID: packageID,
                inventory: installedInventory,
                fallback: installedByID[plugin.pluginID]?.version
            )
            let digest = plugin.source.digest
            let restriction = installedInventory?.installations.first {
                $0.packageID == packageID
            }?.restriction ?? .unknown
            result.packages.append(
                PackageRecord(
                    id: packageID,
                    agent: .claude,
                    name: plugin.name,
                    sourceID: sourceID,
                    publisher: plugin.publisher,
                    description: plugin.description,
                    repository: plugin.source.repository,
                    version: plugin.version,
                    revision: plugin.source.revision,
                    manifestDigest: digest,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
            result.packageStates.append(
                CataloguePackageState(
                    id: InventoryIdentifier.make(
                        hostID.uuidString,
                        packageID,
                        "catalogue"
                    ),
                    hostID: hostID,
                    agent: .claude,
                    packageID: packageID,
                    installedVersion: installedVersion,
                    availableVersion: plugin.version,
                    updateStatus: CatalogueVersionJoin.status(
                        installedVersion: installedVersion,
                        availableVersion: plugin.version
                    ),
                    restriction: restriction,
                    compatibility: .unknown,
                    integrity: digest == nil ? .unverified : .digestDeclared,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
            if let root = plugin.source.componentRoot(
                marketplaceRoot: marketplaceRoots[plugin.marketplaceName]
            ) {
                let marketplaceRoot = marketplaceRoots[plugin.marketplaceName]
                result.componentRoots.append(
                    CatalogueComponentRoot(
                        packageID: packageID,
                        path: root,
                        containerPath: marketplaceRoot.flatMap { container in
                            let prefix = container.hasSuffix("/")
                                ? container
                                : container + "/"
                            guard root == container
                                    || root.hasPrefix(prefix)
                            else {
                                return nil
                            }
                            return container
                        }
                    )
                )
            }
        }

        for plugin in envelope.installed
        where !availableIDs.contains(plugin.id) {
            let identity = PluginIdentity(plugin.id)
            let packageID = "claude:plugin:\(plugin.id)"
            let sourceID = "claude:marketplace:\(identity.marketplace)"
            let installedVersion = CatalogueVersionJoin.installedVersion(
                packageID: packageID,
                inventory: installedInventory,
                fallback: plugin.version
            )
            if seenSources.insert(sourceID).inserted {
                result.sources.append(
                    marketplaces.first { $0.id == sourceID }
                        ?? CatalogSource(
                            id: sourceID,
                            agent: .claude,
                            name: identity.marketplace,
                            kind: .marketplace,
                            capturedAt: capturedAt,
                            evidenceIDs: evidenceID.map { [$0] } ?? []
                        )
                )
            }
            result.packages.append(
                PackageRecord(
                    id: packageID,
                    agent: .claude,
                    name: identity.name,
                    sourceID: sourceID,
                    version: plugin.version,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
            result.packageStates.append(
                CataloguePackageState(
                    id: InventoryIdentifier.make(
                        hostID.uuidString,
                        packageID,
                        "catalogue"
                    ),
                    hostID: hostID,
                    agent: .claude,
                    packageID: packageID,
                    installedVersion: installedVersion,
                    availableVersion: nil,
                    updateStatus: CatalogueVersionJoin.status(
                        installedVersion: installedVersion,
                        availableVersion: nil
                    ),
                    restriction: installedInventory?.installations.first {
                        $0.packageID == packageID
                    }?.restriction ?? .unknown,
                    compatibility: .unknown,
                    integrity: .unknown,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
        }

        return result
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
        let installLocation: String?
    }

    struct AvailablePluginEnvelope: Decodable {
        let installed: [InstalledPlugin]
        let available: [AvailablePlugin]

        enum CodingKeys: String, CodingKey {
            case installed
            case available
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            installed = try container.decodeIfPresent(
                [InstalledPlugin].self,
                forKey: .installed
            ) ?? []
            available = try container.decodeIfPresent(
                [AvailablePlugin].self,
                forKey: .available
            ) ?? []
        }
    }

    struct AvailablePlugin: Decodable {
        let pluginID: String
        let name: String
        let description: String?
        let publisher: String?
        let marketplaceName: String
        let version: String?
        let source: AvailableSource

        enum CodingKeys: String, CodingKey {
            case pluginID = "pluginId"
            case name
            case description
            case publisher
            case marketplaceName
            case version
            case source
        }
    }

    enum AvailableSource: Decodable {
        case path(String)
        case details(SourceDetails)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .path(value)
            } else {
                self = .details(try container.decode(SourceDetails.self))
            }
        }

        var kind: PackageSourceKind {
            switch self {
            case .path:
                .local
            case let .details(details):
                switch details.source?.lowercased() {
                case "github", "git", "git-subdir":
                    .git
                case "url":
                    .url
                case "local", "directory":
                    .local
                default:
                    .marketplace
                }
            }
        }

        var reference: String? {
            switch self {
            case let .path(value):
                value
            case let .details(details):
                details.url ?? details.path
            }
        }

        var repository: String? {
            switch self {
            case let .path(value):
                value.hasPrefix("https://") ? value : nil
            case let .details(details):
                details.url
            }
        }

        var revision: String? {
            switch self {
            case .path:
                nil
            case let .details(details):
                details.ref ?? details.sha
            }
        }

        var digest: String? {
            switch self {
            case .path:
                nil
            case let .details(details):
                details.sha
            }
        }

        func componentRoot(marketplaceRoot: String?) -> String? {
            let path: String?
            switch self {
            case let .path(value):
                path = value
            case let .details(details):
                path = details.path
            }
            guard let path else {
                return nil
            }
            if path.hasPrefix("/") {
                return path
            }
            guard let marketplaceRoot else {
                return nil
            }
            return URL(fileURLWithPath: marketplaceRoot)
                .appendingPathComponent(path)
                .standardizedFileURL
                .path
        }
    }

    struct SourceDetails: Decodable {
        let source: String?
        let url: String?
        let path: String?
        let ref: String?
        let sha: String?
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
