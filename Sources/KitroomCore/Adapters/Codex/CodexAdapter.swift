import Foundation

public struct CodexAdapter: AgentAdapter {
    public let agent = AgentKind.codex

    public let discoveryProfile = AgentDiscoveryProfile(
        agent: .codex,
        executableNames: ["codex"],
        candidateConfigurationPaths: [
            "~/.codex/config.toml"
        ],
        candidateSkillPaths: [
            "~/.codex/skills",
            "~/.agents/skills"
        ]
    )

    public let implementedCapabilities: AdapterCapabilities = []

    public init() {}

    public func inspect(using session: any HostSession) async throws -> InventorySnapshot {
        throw AdapterError.notImplemented(agent: agent, capability: "inventory")
    }

    public func makePlan(
        kind: OperationKind,
        extensionID: String,
        from snapshot: InventorySnapshot,
        using session: any HostSession
    ) async throws -> OperationPlan {
        throw AdapterError.notImplemented(agent: agent, capability: kind.rawValue)
    }
}

