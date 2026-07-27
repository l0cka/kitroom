import Foundation

public protocol HostConnectionFactory: Sendable {
    func connect(to host: ManagedHost) async throws -> any HostSession
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

