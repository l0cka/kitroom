import Foundation

public struct CommandRequest: Hashable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String?
    public let standardInput: Data?
    public let timeout: Duration
    public let maximumOutputBytes: Int

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: String? = nil,
        standardInput: Data? = nil,
        timeout: Duration = .seconds(30),
        maximumOutputBytes: Int = 1_048_576
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.standardInput = standardInput
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public enum CommandTermination: Hashable, Sendable {
    case exited(code: Int32)
    case uncaughtSignal(Int32)
}

public struct CommandResult: Hashable, Sendable {
    public let standardOutput: String
    public let standardError: String
    public let standardOutputWasTruncated: Bool
    public let standardErrorWasTruncated: Bool
    public let termination: CommandTermination
    public let duration: Duration

    public init(
        standardOutput: String,
        standardError: String,
        standardOutputWasTruncated: Bool = false,
        standardErrorWasTruncated: Bool = false,
        termination: CommandTermination,
        duration: Duration = .zero
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.standardOutputWasTruncated = standardOutputWasTruncated
        self.standardErrorWasTruncated = standardErrorWasTruncated
        self.termination = termination
        self.duration = duration
    }

    public init(
        standardOutput: String,
        standardError: String,
        exitCode: Int32
    ) {
        self.init(
            standardOutput: standardOutput,
            standardError: standardError,
            termination: .exited(code: exitCode)
        )
    }

    public var exitCode: Int32? {
        if case let .exited(code) = termination {
            code
        } else {
            nil
        }
    }

    public var succeeded: Bool {
        termination == .exited(code: 0)
    }
}

public protocol HostSession: Sendable {
    var host: ManagedHost { get }

    func execute(_ request: CommandRequest) async throws -> CommandResult
}

public enum HostSessionError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case invalidHostAlias(String)
    case timedOut
    case cancelled
    case authenticationRequired
    case hostIdentityChanged
    case unreachable(String)
    case connectionLost(String)
    case transportFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(detail):
            "The command request is invalid: \(detail)"
        case let .invalidHostAlias(alias):
            "The SSH host alias is invalid: \(alias)"
        case .timedOut:
            "The host command timed out."
        case .cancelled:
            "The host command was cancelled."
        case .authenticationRequired:
            "The SSH host requires authentication."
        case .hostIdentityChanged:
            "The SSH host identity has changed."
        case let .unreachable(detail):
            "The SSH host is unreachable: \(detail)"
        case let .connectionLost(detail):
            "The SSH connection was lost: \(detail)"
        case let .transportFailure(detail):
            "The host transport failed: \(detail)"
        }
    }
}
