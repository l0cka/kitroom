import Foundation

public enum HostConnectionState: String, Codable, Hashable, Sendable {
    case notChecked
    case connecting
    case reachable
    case authenticationRequired
    case hostIdentityChanged
    case unreachable
    case partialDiscovery
    case cancelled
}

public struct HostPlatform: Codable, Hashable, Sendable {
    public let operatingSystem: String
    public let architecture: String?
    public let homeDirectory: String?
    public let shell: String?
    public let hostname: String?

    public init(
        operatingSystem: String,
        architecture: String? = nil,
        homeDirectory: String? = nil,
        shell: String? = nil,
        hostname: String? = nil
    ) {
        self.operatingSystem = operatingSystem
        self.architecture = architecture
        self.homeDirectory = homeDirectory
        self.shell = shell
        self.hostname = hostname
    }
}

public enum HostIdentityKind: String, Codable, Hashable, Sendable {
    case platformUUID
    case machineID
    case derived
}

public struct HostIdentityEvidence: Codable, Hashable, Sendable {
    public let kind: HostIdentityKind
    public let value: String
    public let source: String

    public init(kind: HostIdentityKind, value: String, source: String) {
        self.kind = kind
        self.value = value
        self.source = source
    }
}

public enum HostPathAccessState: String, Codable, Hashable, Sendable {
    case missing
    case readOnly
    case readWrite
    case denied
    case unknown
}

public struct HostPathAccess: Identifiable, Codable, Hashable, Sendable {
    public var id: String { path }

    public let path: String
    public let state: HostPathAccessState

    public init(path: String, state: HostPathAccessState) {
        self.path = path
        self.state = state
    }
}

public enum AgentAvailability: String, Codable, Hashable, Sendable {
    case available
    case notInstalled
    case unknown
}

public struct DiscoveredAgent: Identifiable, Codable, Hashable, Sendable {
    public var id: AgentKind { agent }

    public let agent: AgentKind
    public let availability: AgentAvailability
    public let executablePath: String?
    public let version: String?

    public init(
        agent: AgentKind,
        availability: AgentAvailability,
        executablePath: String? = nil,
        version: String? = nil
    ) {
        self.agent = agent
        self.availability = availability
        self.executablePath = executablePath
        self.version = version
    }
}

public struct HostDiscoverySnapshot: Codable, Hashable, Sendable {
    public let hostID: ManagedHost.ID
    public let attemptedAt: Date
    public let completedAt: Date?
    public let connectionState: HostConnectionState
    public let resolvedHost: String?
    public let platform: HostPlatform?
    public let identity: HostIdentityEvidence?
    public let pathAccess: [HostPathAccess]
    public let agents: [DiscoveredAgent]
    public let latencyMilliseconds: Double?
    public let issues: [InventoryIssue]

    public init(
        hostID: ManagedHost.ID,
        attemptedAt: Date,
        completedAt: Date? = nil,
        connectionState: HostConnectionState,
        resolvedHost: String? = nil,
        platform: HostPlatform? = nil,
        identity: HostIdentityEvidence? = nil,
        pathAccess: [HostPathAccess] = [],
        agents: [DiscoveredAgent] = [],
        latencyMilliseconds: Double? = nil,
        issues: [InventoryIssue] = []
    ) {
        self.hostID = hostID
        self.attemptedAt = attemptedAt
        self.completedAt = completedAt
        self.connectionState = connectionState
        self.resolvedHost = resolvedHost
        self.platform = platform
        self.identity = identity
        self.pathAccess = pathAccess
        self.agents = agents
        self.latencyMilliseconds = latencyMilliseconds
        self.issues = issues
    }
}
