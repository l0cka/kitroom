import Foundation

import Foundation

public protocol HostConnectionFactory: Sendable {
    func connect(to host: ManagedHost) async throws -> any HostSession
}

public struct UnavailableHostConnectionFactory: HostConnectionFactory {
    public init() {}

    public func connect(to host: ManagedHost) async throws -> any HostSession {
        throw HostSessionError.transportFailure(
            "Host connections are not implemented in this build."
        )
    }
}

public struct DefaultHostConnectionFactory: HostConnectionFactory {
    private let executor: any ProcessExecutor
    private let localEnvironment: [String: String]

    public init(
        executor: any ProcessExecutor,
        localEnvironment: [String: String] = HostEnvironment.standard
    ) {
        self.executor = executor
        self.localEnvironment = localEnvironment
    }

    public func connect(to host: ManagedHost) async throws -> any HostSession {
        switch host.connection {
        case .local:
            return try LocalHostSession(host: host, executor: executor)
        case .ssh:
            return try SSHHostSession(
                host: host,
                executor: executor,
                localEnvironment: localEnvironment
            )
        }
    }
}

public enum HostAliasValidator {
    public static func isValid(_ alias: String) -> Bool {
        guard !alias.isEmpty,
              alias.count <= 255,
              alias != ".",
              alias != "..",
              alias.first != "-"
        else {
            return false
        }

        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-"))

        return alias.unicodeScalars.allSatisfy(allowed.contains)
    }
}

public enum HostEnvironment {
    public static var standard: [String: String] {
        let source = ProcessInfo.processInfo.environment
        let allowedNames = ["HOME", "LANG", "LC_ALL", "PATH", "SHELL", "TMPDIR"]

        return allowedNames.reduce(into: [:]) { result, name in
            if let value = source[name] {
                result[name] = value
            }
        }
    }
}
