public struct SSHConfigurationSummary: Codable, Hashable, Sendable {
    public let alias: String
    public let hostname: String
    public let user: String?
    public let port: Int?

    public init(
        alias: String,
        hostname: String,
        user: String? = nil,
        port: Int? = nil
    ) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
    }

    public var resolvedDescription: String {
        let userPrefix = user.map { "\($0)@" } ?? ""
        let portSuffix = port.map { ":\($0)" } ?? ""
        return "\(userPrefix)\(hostname)\(portSuffix)"
    }
}

public protocol SSHConfigurationResolving: Sendable {
    func resolve(alias: String) async throws -> SSHConfigurationSummary
}

public struct SSHConfigurationResolver: SSHConfigurationResolving {
    private let executor: any ProcessExecutor
    private let environment: [String: String]

    public init(
        executor: any ProcessExecutor,
        environment: [String: String] = HostEnvironment.standard
    ) {
        self.executor = executor
        self.environment = environment
    }

    public func resolve(alias: String) async throws -> SSHConfigurationSummary {
        guard HostAliasValidator.isValid(alias) else {
            throw HostSessionError.invalidHostAlias(alias)
        }

        let result = try await executor.execute(
            CommandRequest(
                executable: "/usr/bin/ssh",
                arguments: ["-G", "--", alias],
                environment: environment,
                timeout: .seconds(5),
                maximumOutputBytes: 262_144
            )
        )

        guard result.succeeded else {
            if result.exitCode == 255 {
                throw SSHHostSession.classifyFailure(result.standardError)
            }
            throw HostSessionError.transportFailure(
                "OpenSSH could not resolve the selected host alias."
            )
        }

        var values: [String: String] = [:]
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(
                maxSplits: 1,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 2 else {
                continue
            }
            values[String(fields[0]).lowercased()] = String(fields[1])
        }

        guard let hostname = values["hostname"], !hostname.isEmpty else {
            throw HostSessionError.transportFailure(
                "OpenSSH returned no resolved hostname."
            )
        }

        return SSHConfigurationSummary(
            alias: alias,
            hostname: hostname,
            user: values["user"],
            port: values["port"].flatMap(Int.init)
        )
    }
}
