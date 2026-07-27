import Foundation

public enum ExtensionKind: String, CaseIterable, Codable, Hashable, Sendable {
    case skill
    case plugin
    case mcpServer

    public var displayName: String {
        switch self {
        case .skill:
            "Skill"
        case .plugin:
            "Plugin"
        case .mcpServer:
            "MCP server"
        }
    }
}

public enum ExtensionOrigin: String, Codable, Hashable, Sendable {
    case handManaged
    case marketplace
    case pluginProvided
    case shared
    case runtimeInjected
    case unknown
}

public enum InstallationState: String, Codable, Hashable, Sendable {
    case installed
    case disabled
    case updateAvailable
    case absent
    case unknown
}

public struct ManagedExtension: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: ExtensionKind
    public let agent: AgentKind
    public let origin: ExtensionOrigin
    public let state: InstallationState
    public let installedVersion: String?
    public let availableVersion: String?
    public let source: String?
    public let evidence: [String]

    public init(
        id: String,
        name: String,
        kind: ExtensionKind,
        agent: AgentKind,
        origin: ExtensionOrigin,
        state: InstallationState,
        installedVersion: String? = nil,
        availableVersion: String? = nil,
        source: String? = nil,
        evidence: [String] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.agent = agent
        self.origin = origin
        self.state = state
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.source = source
        self.evidence = evidence
    }
}

