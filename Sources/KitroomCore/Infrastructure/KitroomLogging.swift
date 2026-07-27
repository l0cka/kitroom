import OSLog

public enum KitroomLogLevel: String, Codable, Hashable, Sendable {
    case debug
    case info
    case notice
    case error
}

public struct KitroomLogEvent: Hashable, Sendable {
    public let level: KitroomLogLevel
    public let category: String
    public let name: String
    public let publicMetadata: [String: String]
    public let privateContext: String?

    public init(
        level: KitroomLogLevel,
        category: String,
        name: String,
        publicMetadata: [String: String] = [:],
        privateContext: String? = nil
    ) {
        self.level = level
        self.category = category
        self.name = name
        self.publicMetadata = publicMetadata
        self.privateContext = privateContext
    }

    public var publicDescription: String {
        let metadata = publicMetadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        return metadata.isEmpty ? name : "\(name) \(metadata)"
    }

    public var redactedDescription: String {
        privateContext == nil
            ? publicDescription
            : "\(publicDescription) context=<private>"
    }
}

public protocol KitroomLogging: Sendable {
    func record(_ event: KitroomLogEvent)
}

public struct SystemKitroomLogger: KitroomLogging {
    private let subsystem: String

    public init(subsystem: String = "com.l0cka.kitroom") {
        self.subsystem = subsystem
    }

    public func record(_ event: KitroomLogEvent) {
        let logger = Logger(subsystem: subsystem, category: event.category)
        let publicDescription = event.publicDescription

        if let privateContext = event.privateContext {
            logger.log(
                level: event.level.osLogType,
                "\(publicDescription, privacy: .public) context=\(privateContext, privacy: .private(mask: .hash))"
            )
        } else {
            logger.log(
                level: event.level.osLogType,
                "\(publicDescription, privacy: .public)"
            )
        }
    }
}

public struct NoOpKitroomLogger: KitroomLogging {
    public init() {}

    public func record(_ event: KitroomLogEvent) {}
}

private extension KitroomLogLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug:
            .debug
        case .info:
            .info
        case .notice:
            .default
        case .error:
            .error
        }
    }
}
