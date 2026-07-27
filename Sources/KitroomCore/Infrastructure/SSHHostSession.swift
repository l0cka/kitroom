import Foundation

public struct SSHHostSession: HostSession {
    public let host: ManagedHost

    private let alias: String
    private let executor: any ProcessExecutor
    private let localEnvironment: [String: String]
    private let connectTimeoutSeconds: Int

    public init(
        host: ManagedHost,
        executor: any ProcessExecutor,
        localEnvironment: [String: String] = [:],
        connectTimeoutSeconds: Int = 10
    ) throws {
        guard case let .ssh(alias) = host.connection else {
            throw HostSessionError.invalidRequest(
                "An SSH session requires an SSH host."
            )
        }
        guard HostAliasValidator.isValid(alias) else {
            throw HostSessionError.invalidHostAlias(alias)
        }
        guard (1 ... 60).contains(connectTimeoutSeconds) else {
            throw HostSessionError.invalidRequest(
                "The SSH connection timeout must be between 1 and 60 seconds."
            )
        }

        self.host = host
        self.alias = alias
        self.executor = executor
        self.localEnvironment = localEnvironment
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }

    public func execute(_ request: CommandRequest) async throws -> CommandResult {
        let remoteCommand = try RemoteCommandEncoder.encode(request)
        let sshRequest = CommandRequest(
            executable: "/usr/bin/ssh",
            arguments: [
                "-o", "BatchMode=yes",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "ConnectionAttempts=1",
                "-o", "ConnectTimeout=\(connectTimeoutSeconds)",
                "--",
                alias,
                remoteCommand
            ],
            environment: localEnvironment,
            standardInput: request.standardInput,
            timeout: request.timeout,
            maximumOutputBytes: request.maximumOutputBytes
        )

        do {
            let result = try await executor.execute(sshRequest)

            if result.exitCode == 255 {
                throw Self.classifyFailure(result.standardError)
            }

            return result
        } catch let error as HostSessionError {
            throw error
        } catch {
            throw HostSessionError.transportFailure(error.localizedDescription)
        }
    }

    public static func classifyFailure(_ standardError: String) -> HostSessionError {
        let detail = boundedDetail(standardError)
        let normalized = standardError.lowercased()

        if normalized.contains("remote host identification has changed")
            || normalized.contains("host key verification failed") {
            return .hostIdentityChanged
        }

        if normalized.contains("permission denied")
            || normalized.contains("no supported authentication methods")
            || normalized.contains("authentication failed") {
            return .authenticationRequired
        }

        if normalized.contains("connection reset")
            || normalized.contains("connection closed")
            || normalized.contains("broken pipe") {
            return .connectionLost(detail)
        }

        if normalized.contains("could not resolve hostname")
            || normalized.contains("connection refused")
            || normalized.contains("network is unreachable")
            || normalized.contains("operation timed out")
            || normalized.contains("connection timed out")
            || normalized.contains("no route to host") {
            return .unreachable(detail)
        }

        return .transportFailure(detail)
    }

    private static func boundedDetail(_ value: String) -> String {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return String(collapsed.prefix(500))
    }
}
