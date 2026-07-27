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

public enum HostAliasValidator {
    public static func isValid(_ alias: String) -> Bool {
        guard !alias.isEmpty, alias.count <= 255 else {
            return false
        }

        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-"))

        return alias.unicodeScalars.allSatisfy(allowed.contains)
    }
}
