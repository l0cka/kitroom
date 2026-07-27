import Foundation

public struct ClaudeAdapter: AgentAdapter {
    public let agent = AgentKind.claude

    public let discoveryProfile = AgentDiscoveryProfile(
        agent: .claude,
        executableNames: ["claude"],
        candidateConfigurationPaths: [
            "~/.claude/settings.json"
        ],
        candidateSkillPaths: [
            "~/.claude/skills",
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

