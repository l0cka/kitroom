import Foundation

public struct CommandRequest: Hashable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let timeout: Duration

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        timeout: Duration = .seconds(30)
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

public struct CommandResult: Hashable, Sendable {
    public let standardOutput: String
    public let standardError: String
    public let exitCode: Int32

    public init(
        standardOutput: String,
        standardError: String,
        exitCode: Int32
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }

    public var succeeded: Bool {
        exitCode == 0
    }
}

public protocol HostSession: Sendable {
    var host: ManagedHost { get }

    func execute(_ request: CommandRequest) async throws -> CommandResult
}

public enum HostSessionError: LocalizedError, Sendable {
    case invalidHostAlias(String)
    case timedOut
    case transportFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidHostAlias(alias):
            "The SSH host alias is invalid: \(alias)"
        case .timedOut:
            "The host command timed out."
        case let .transportFailure(detail):
            "The host transport failed: \(detail)"
        }
    }
}

