import Foundation

public struct ManagedHost: Identifiable, Codable, Hashable, Sendable {
    public enum Connection: Codable, Hashable, Sendable {
        case local
        case ssh(alias: String)

        public var description: String {
            switch self {
            case .local:
                "Local"
            case let .ssh(alias):
                "SSH · \(alias)"
            }
        }

        public var isRemote: Bool {
            if case .ssh = self {
                true
            } else {
                false
            }
        }
    }

    public let id: UUID
    public let name: String
    public let connection: Connection

    public init(
        id: UUID = UUID(),
        name: String,
        connection: Connection
    ) {
        self.id = id
        self.name = name
        self.connection = connection
    }
}

