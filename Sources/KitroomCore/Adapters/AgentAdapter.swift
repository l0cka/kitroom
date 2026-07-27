import Foundation

public struct AdapterCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let inventory = Self(rawValue: 1 << 0)
    public static let install = Self(rawValue: 1 << 1)
    public static let update = Self(rawValue: 1 << 2)
    public static let disable = Self(rawValue: 1 << 3)
    public static let uninstall = Self(rawValue: 1 << 4)
}

public struct AgentDiscoveryProfile: Hashable, Sendable {
    public let agent: AgentKind
    public let executableNames: [String]
    public let candidateConfigurationPaths: [String]
    public let candidateSkillPaths: [String]

    public init(
        agent: AgentKind,
        executableNames: [String],
        candidateConfigurationPaths: [String],
        candidateSkillPaths: [String]
    ) {
        self.agent = agent
        self.executableNames = executableNames
        self.candidateConfigurationPaths = candidateConfigurationPaths
        self.candidateSkillPaths = candidateSkillPaths
    }
}

public protocol AgentAdapter: Sendable {
    var agent: AgentKind { get }
    var discoveryProfile: AgentDiscoveryProfile { get }
    var implementedCapabilities: AdapterCapabilities { get }

    func inspect(using session: any HostSession) async throws -> InventorySnapshot
    func makePlan(
        kind: OperationKind,
        extensionID: String,
        from snapshot: InventorySnapshot,
        using session: any HostSession
    ) async throws -> OperationPlan
}

public enum AdapterError: LocalizedError, Sendable {
    case notImplemented(agent: AgentKind, capability: String)
    case agentUnavailable(AgentKind)
    case invalidInventory(String)

    public var errorDescription: String? {
        switch self {
        case let .notImplemented(agent, capability):
            "\(agent.displayName) \(capability) is not implemented yet."
        case let .agentUnavailable(agent):
            "\(agent.displayName) is unavailable on the selected host."
        case let .invalidInventory(detail):
            "Inventory could not be verified: \(detail)"
        }
    }
}

