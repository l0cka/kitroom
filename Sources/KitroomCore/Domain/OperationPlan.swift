import CryptoKit
import Foundation

public enum OperationKind: String, Codable, Hashable, Sendable {
    case inspect
    case install
    case update
    case disable
    case uninstall

    public var isMutation: Bool {
        self != .inspect
    }
}

public enum OperationRisk: String, Codable, Comparable, Hashable, Sendable {
    case readOnly
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .readOnly: 0
        case .low: 1
        case .medium: 2
        case .high: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct PlannedChange: Codable, Hashable, Sendable {
    public let summary: String
    public let target: String
    public let commandPreview: String?
    public let rollback: String?

    public init(
        summary: String,
        target: String,
        commandPreview: String? = nil,
        rollback: String? = nil
    ) {
        self.summary = summary
        self.target = target
        self.commandPreview = commandPreview
        self.rollback = rollback
    }
}

public struct OperationPlan: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let kind: OperationKind
    public let risk: OperationRisk
    public let hostID: ManagedHost.ID
    public let agent: AgentKind
    public let extensionID: String?
    public let basedOnSnapshotAt: Date
    public let changes: [PlannedChange]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: OperationKind,
        risk: OperationRisk,
        hostID: ManagedHost.ID,
        agent: AgentKind,
        extensionID: String? = nil,
        basedOnSnapshotAt: Date,
        changes: [PlannedChange],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.risk = risk
        self.hostID = hostID
        self.agent = agent
        self.extensionID = extensionID
        self.basedOnSnapshotAt = basedOnSnapshotAt
        self.changes = changes
        self.createdAt = createdAt
    }

    public var requiresConfirmation: Bool {
        kind.isMutation
    }

    public var approvalDigest: String {
        let input = [
            id.uuidString,
            kind.rawValue,
            risk.rawValue,
            hostID.uuidString,
            agent.rawValue,
            extensionID ?? "",
            basedOnSnapshotAt.ISO8601Format(),
            changes.map {
                [$0.summary, $0.target, $0.commandPreview ?? "", $0.rollback ?? ""]
                    .joined(separator: "\u{1f}")
            }.joined(separator: "\u{1e}")
        ].joined(separator: "\u{1d}")

        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

