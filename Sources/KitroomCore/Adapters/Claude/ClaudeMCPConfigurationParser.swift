import Foundation

enum ClaudeMCPConfigurationParser {
    static func parse(
        _ data: Data,
        hostID: ManagedHost.ID,
        evidenceID: EvidenceRecord.ID? = nil
    ) throws -> ParsedAgentInventory {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw AdapterError.invalidInventory(
                "Claude configuration is not a JSON object."
            )
        }

        var inventory = ParsedAgentInventory()
        appendServers(
            root["mcpServers"],
            hostID: hostID,
            scope: .user,
            physicalOrigin: "~/.claude.json",
            evidenceID: evidenceID,
            inventory: &inventory
        )

        if let projects = root["projects"] as? [String: Any] {
            for (projectPath, value) in projects.sorted(by: { $0.key < $1.key }) {
                guard let project = value as? [String: Any] else {
                    continue
                }
                appendServers(
                    project["mcpServers"],
                    hostID: hostID,
                    scope: .localProject,
                    physicalOrigin: projectPath,
                    evidenceID: evidenceID,
                    inventory: &inventory
                )
            }
        }

        return inventory
    }

    static func parseProjectConfiguration(
        _ data: Data,
        userConfigurationData: Data?,
        hostID: ManagedHost.ID,
        projectRoot: String,
        evidenceID: EvidenceRecord.ID? = nil
    ) throws -> ParsedAgentInventory {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw AdapterError.invalidInventory(
                "Claude project MCP configuration is not a JSON object."
            )
        }

        var enableAll = false
        var enabledNames = Set<String>()
        var disabledNames = Set<String>()
        if let userConfigurationData,
           let userObject = try? JSONSerialization.jsonObject(
                with: userConfigurationData
           ),
           let userRoot = userObject as? [String: Any],
           let projects = userRoot["projects"] as? [String: Any],
           let project = projects[projectRoot] as? [String: Any] {
            enableAll = project["enableAllProjectMcpServers"] as? Bool ?? false
            enabledNames = stringSet(project["enabledMcpjsonServers"])
            disabledNames = stringSet(project["disabledMcpjsonServers"])
        }

        var inventory = ParsedAgentInventory()
        guard let servers = root["mcpServers"] as? [String: Any] else {
            return inventory
        }

        for name in servers.keys
            .filter({ !SensitiveValueRedactor.isSensitiveKey($0) })
            .sorted() {
            let capabilityID = InventoryIdentifier.make(
                "claude",
                "mcp",
                "project",
                projectRoot,
                name
            )
            let state: EffectiveState
            if disabledNames.contains(name) {
                state = .disabled
            } else if enableAll || enabledNames.contains(name) {
                state = .configured
            } else {
                state = .pendingApproval
            }

            inventory.capabilities.append(
                ProvidedCapability(
                    id: capabilityID,
                    agent: .claude,
                    kind: .mcpServer,
                    name: name,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
            inventory.installations.append(
                InstallationRecord(
                    id: InventoryIdentifier.make(
                        hostID.uuidString,
                        capabilityID,
                        projectRoot
                    ),
                    hostID: hostID,
                    agent: .claude,
                    capabilityID: capabilityID,
                    scope: .repository,
                    origin: .standalone,
                    state: state,
                    physicalOrigin: URL(fileURLWithPath: projectRoot)
                        .appendingPathComponent(".mcp.json")
                        .path,
                    restriction: .agentManaged,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
        }

        return inventory
    }

    private static func appendServers(
        _ value: Any?,
        hostID: ManagedHost.ID,
        scope: InventoryScope,
        physicalOrigin: String,
        evidenceID: EvidenceRecord.ID?,
        inventory: inout ParsedAgentInventory
    ) {
        guard let servers = value as? [String: Any] else {
            return
        }

        for (name, untrustedConfiguration) in servers.sorted(by: { $0.key < $1.key }) {
            guard !SensitiveValueRedactor.isSensitiveKey(name) else {
                continue
            }
            let configuration = untrustedConfiguration as? [String: Any]
            let disabled = configuration?["disabled"] as? Bool ?? false
            let capabilityID = InventoryIdentifier.make(
                "claude",
                "mcp",
                scope.rawValue,
                name
            )
            inventory.capabilities.append(
                ProvidedCapability(
                    id: capabilityID,
                    agent: .claude,
                    kind: .mcpServer,
                    name: name,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
            inventory.installations.append(
                InstallationRecord(
                    id: InventoryIdentifier.make(
                        hostID.uuidString,
                        capabilityID,
                        physicalOrigin
                    ),
                    hostID: hostID,
                    agent: .claude,
                    capabilityID: capabilityID,
                    scope: scope,
                    origin: .standalone,
                    state: disabled ? .disabled : .configured,
                    physicalOrigin: physicalOrigin,
                    restriction: .agentManaged,
                    evidenceIDs: evidenceID.map { [$0] } ?? []
                )
            )
        }
    }

    private static func stringSet(_ value: Any?) -> Set<String> {
        Set((value as? [String] ?? []).filter {
            !SensitiveValueRedactor.isSensitiveKey($0)
        })
    }
}
