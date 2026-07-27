public protocol AgentAdapterRegistry: Sendable {
    var supportedAgents: [AgentKind] { get }

    func adapter(for agent: AgentKind) -> (any AgentAdapter)?
}

public struct DefaultAgentAdapterRegistry: AgentAdapterRegistry {
    private let adapters: [AgentKind: any AgentAdapter]

    public init(
        adapters: [any AgentAdapter] = [
            CodexAdapter(),
            ClaudeAdapter()
        ]
    ) {
        self.adapters = Dictionary(
            uniqueKeysWithValues: adapters.map { ($0.agent, $0) }
        )
    }

    public var supportedAgents: [AgentKind] {
        adapters.keys.sorted { $0.rawValue < $1.rawValue }
    }

    public func adapter(for agent: AgentKind) -> (any AgentAdapter)? {
        adapters[agent]
    }
}
