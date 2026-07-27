import CryptoKit
import Foundation

public enum OperationKind: String, Codable, Hashable, Sendable {
    case inspect
    case install
    case update
    case enable
    case disable
    case uninstall

    public var isMutation: Bool {
        self != .inspect
    }
}

public enum LocalSkillAction: String, Codable, Hashable, Sendable {
    case install
    case update
    case uninstall
}

public struct LocalSkillOperationSpec: Codable, Hashable, Sendable {
    public let action: LocalSkillAction
    public let skillName: String
    public let sourcePath: String?
    public let destinationPath: String
    public let backupRoot: String
    public let createsDestinationRoot: Bool
    public let sourceDigest: String?
    public let expectedDestinationDigest: String?

    public init(
        action: LocalSkillAction,
        skillName: String,
        sourcePath: String? = nil,
        destinationPath: String,
        backupRoot: String,
        createsDestinationRoot: Bool = false,
        sourceDigest: String? = nil,
        expectedDestinationDigest: String? = nil
    ) {
        self.action = action
        self.skillName = skillName
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.backupRoot = backupRoot
        self.createsDestinationRoot = createsDestinationRoot
        self.sourceDigest = sourceDigest
        self.expectedDestinationDigest = expectedDestinationDigest
    }
}

public enum NativePluginAction: String, Codable, Hashable, Sendable {
    case install
    case update
    case enable
    case disable
    case uninstall

    public var inverse: NativePluginAction? {
        switch self {
        case .install:
            .uninstall
        case .uninstall:
            .install
        case .enable:
            .disable
        case .disable:
            .enable
        case .update:
            nil
        }
    }
}

public struct NativePluginConfigurationState: Codable, Hashable, Sendable {
    public let path: String
    public let contentDigest: String?

    public init(path: String, contentDigest: String?) {
        self.path = path
        self.contentDigest = contentDigest
    }
}

public struct NativePluginOperationSpec: Codable, Hashable, Sendable {
    public let agent: AgentKind
    public let action: NativePluginAction
    public let selector: String
    public let scope: InventoryScope
    public let executablePath: String
    public let configurationStates: [NativePluginConfigurationState]
    public let expectedBeforeInstalled: Bool
    public let expectedAfterInstalled: Bool
    public let expectedBeforeState: EffectiveState?
    public let expectedAfterState: EffectiveState?
    public let expectedBeforeVersion: String?
    public let expectedAfterVersion: String?
    public let requiresCataloguePreflight: Bool

    public init(
        agent: AgentKind,
        action: NativePluginAction,
        selector: String,
        scope: InventoryScope,
        executablePath: String,
        configurationStates: [NativePluginConfigurationState],
        expectedBeforeInstalled: Bool = true,
        expectedAfterInstalled: Bool = true,
        expectedBeforeState: EffectiveState? = nil,
        expectedAfterState: EffectiveState? = nil,
        expectedBeforeVersion: String? = nil,
        expectedAfterVersion: String? = nil,
        requiresCataloguePreflight: Bool = false
    ) {
        self.agent = agent
        self.action = action
        self.selector = selector
        self.scope = scope
        self.executablePath = executablePath
        self.configurationStates = configurationStates
        self.expectedBeforeInstalled = expectedBeforeInstalled
        self.expectedAfterInstalled = expectedAfterInstalled
        self.expectedBeforeState = expectedBeforeState
        self.expectedAfterState = expectedAfterState
        self.expectedBeforeVersion = expectedBeforeVersion
        self.expectedAfterVersion = expectedAfterVersion
        self.requiresCataloguePreflight = requiresCataloguePreflight
    }
}

public enum NativeMCPAction: String, Codable, Hashable, Sendable {
    case add
    case remove

    public var inverse: NativeMCPAction? {
        switch self {
        case .add:
            .remove
        case .remove:
            nil
        }
    }
}

public struct NativeMCPOperationSpec: Codable, Hashable, Sendable {
    public let agent: AgentKind
    public let action: NativeMCPAction
    public let serverName: String
    public let serverURL: String?
    public let scope: InventoryScope
    public let executablePath: String
    public let configurationState: NativePluginConfigurationState
    public let expectedBeforeConfigured: Bool
    public let expectedAfterConfigured: Bool

    public init(
        agent: AgentKind,
        action: NativeMCPAction,
        serverName: String,
        serverURL: String? = nil,
        scope: InventoryScope,
        executablePath: String,
        configurationState: NativePluginConfigurationState,
        expectedBeforeConfigured: Bool,
        expectedAfterConfigured: Bool
    ) {
        self.agent = agent
        self.action = action
        self.serverName = serverName
        self.serverURL = serverURL
        self.scope = scope
        self.executablePath = executablePath
        self.configurationState = configurationState
        self.expectedBeforeConfigured = expectedBeforeConfigured
        self.expectedAfterConfigured = expectedAfterConfigured
    }
}

public enum OperationExecutionSpec: Codable, Hashable, Sendable {
    case localSkill(LocalSkillOperationSpec)
    case nativePlugin(NativePluginOperationSpec)
    case nativeMCP(NativeMCPOperationSpec)
}

public struct OperationPreflight: Codable, Hashable, Sendable {
    public let inspectedAt: Date
    public let targetStateMatchesPlan: Bool

    public init(
        inspectedAt: Date,
        targetStateMatchesPlan: Bool
    ) {
        self.inspectedAt = inspectedAt
        self.targetStateMatchesPlan = targetStateMatchesPlan
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
    public let hostIdentity: String?
    public let agent: AgentKind
    public let extensionID: String?
    public let scope: InventoryScope?
    public let sourceReference: String?
    public let version: String?
    public let revision: String?
    public let contentDigest: String?
    public let expectedBeforeDigest: String?
    public let expectedAfterDigest: String?
    public let basedOnSnapshotAt: Date
    public let changes: [PlannedChange]
    public let warnings: [String]
    public let verificationSteps: [String]
    public let execution: OperationExecutionSpec?
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        kind: OperationKind,
        risk: OperationRisk,
        hostID: ManagedHost.ID,
        hostIdentity: String? = nil,
        agent: AgentKind,
        extensionID: String? = nil,
        scope: InventoryScope? = nil,
        sourceReference: String? = nil,
        version: String? = nil,
        revision: String? = nil,
        contentDigest: String? = nil,
        expectedBeforeDigest: String? = nil,
        expectedAfterDigest: String? = nil,
        basedOnSnapshotAt: Date,
        changes: [PlannedChange],
        warnings: [String] = [],
        verificationSteps: [String] = [],
        execution: OperationExecutionSpec? = nil,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.risk = risk
        self.hostID = hostID
        self.hostIdentity = hostIdentity
        self.agent = agent
        self.extensionID = extensionID
        self.scope = scope
        self.sourceReference = sourceReference
        self.version = version
        self.revision = revision
        self.contentDigest = contentDigest
        self.expectedBeforeDigest = expectedBeforeDigest
        self.expectedAfterDigest = expectedAfterDigest
        self.basedOnSnapshotAt = basedOnSnapshotAt
        self.changes = changes
        self.warnings = warnings
        self.verificationSteps = verificationSteps
        self.execution = execution
        self.createdAt = createdAt
        self.expiresAt = expiresAt
            ?? createdAt.addingTimeInterval(10 * 60)
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
            hostIdentity ?? "",
            agent.rawValue,
            extensionID ?? "",
            scope?.rawValue ?? "",
            sourceReference ?? "",
            version ?? "",
            revision ?? "",
            contentDigest ?? "",
            expectedBeforeDigest ?? "",
            expectedAfterDigest ?? "",
            basedOnSnapshotAt.ISO8601Format(),
            changes.map {
                [$0.summary, $0.target, $0.commandPreview ?? "", $0.rollback ?? ""]
                    .joined(separator: "\u{1f}")
            }.joined(separator: "\u{1e}"),
            warnings.joined(separator: "\u{1e}"),
            verificationSteps.joined(separator: "\u{1e}"),
            executionDigestMaterial,
            createdAt.ISO8601Format(),
            expiresAt.ISO8601Format()
        ].joined(separator: "\u{1d}")

        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }

    private var executionDigestMaterial: String {
        switch execution {
        case let .localSkill(spec):
            return [
                "local-skill",
                spec.action.rawValue,
                spec.skillName,
                spec.sourcePath ?? "",
                spec.destinationPath,
                spec.backupRoot,
                String(spec.createsDestinationRoot),
                spec.sourceDigest ?? "",
                spec.expectedDestinationDigest ?? ""
            ].joined(separator: "\u{1f}")
        case let .nativePlugin(spec):
            return [
                "native-plugin",
                spec.agent.rawValue,
                spec.action.rawValue,
                spec.selector,
                spec.scope.rawValue,
                spec.executablePath,
                spec.configurationStates.map {
                    "\($0.path)\u{1f}\($0.contentDigest ?? "absent")"
                }.joined(separator: "\u{1e}"),
                String(spec.expectedBeforeInstalled),
                String(spec.expectedAfterInstalled),
                spec.expectedBeforeState?.rawValue ?? "",
                spec.expectedAfterState?.rawValue ?? "",
                spec.expectedBeforeVersion ?? "",
                spec.expectedAfterVersion ?? "",
                String(spec.requiresCataloguePreflight)
            ].joined(separator: "\u{1f}")
        case let .nativeMCP(spec):
            return [
                "native-mcp",
                spec.agent.rawValue,
                spec.action.rawValue,
                spec.serverName,
                spec.serverURL ?? "",
                spec.scope.rawValue,
                spec.executablePath,
                spec.configurationState.path,
                spec.configurationState.contentDigest ?? "absent",
                String(spec.expectedBeforeConfigured),
                String(spec.expectedAfterConfigured)
            ].joined(separator: "\u{1f}")
        case nil:
            return ""
        }
    }
}
