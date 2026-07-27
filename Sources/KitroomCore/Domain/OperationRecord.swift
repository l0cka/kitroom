import Foundation

public enum OperationLifecycleState: String, Codable, Hashable, Sendable {
    case draft
    case planned
    case awaitingApproval
    case applying
    case verifying
    case completed
    case failed
    case rolledBack
    case verificationFailed
    case invalidated
}

public enum OperationRollbackState: String, Codable, Hashable, Sendable {
    case notRequired
    case available
    case succeeded
    case failed
}

public struct OperationEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let state: OperationLifecycleState
    public let occurredAt: Date
    public let message: String

    public init(
        id: UUID = UUID(),
        state: OperationLifecycleState,
        occurredAt: Date,
        message: String
    ) {
        self.id = id
        self.state = state
        self.occurredAt = occurredAt
        self.message = message
    }
}

public struct OperationRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: OperationPlan.ID { plan.id }

    public let plan: OperationPlan
    public let state: OperationLifecycleState
    public let updatedAt: Date
    public let completedAt: Date?
    public let backupPath: String?
    public let rollbackState: OperationRollbackState
    public let verificationDigest: String?
    public let failure: String?
    public let events: [OperationEvent]

    public init(
        plan: OperationPlan,
        state: OperationLifecycleState,
        updatedAt: Date,
        completedAt: Date? = nil,
        backupPath: String? = nil,
        rollbackState: OperationRollbackState = .notRequired,
        verificationDigest: String? = nil,
        failure: String? = nil,
        events: [OperationEvent] = []
    ) {
        self.plan = plan
        self.state = state
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.backupPath = backupPath
        self.rollbackState = rollbackState
        self.verificationDigest = verificationDigest
        self.failure = failure
        self.events = events
    }

    public func transitioned(
        to state: OperationLifecycleState,
        at date: Date,
        message: String,
        backupPath: String? = nil,
        rollbackState: OperationRollbackState? = nil,
        verificationDigest: String? = nil,
        failure: String? = nil
    ) -> OperationRecord {
        OperationRecord(
            plan: plan,
            state: state,
            updatedAt: date,
            completedAt: state.isTerminal ? date : nil,
            backupPath: backupPath ?? self.backupPath,
            rollbackState: rollbackState ?? self.rollbackState,
            verificationDigest: verificationDigest
                ?? self.verificationDigest,
            failure: failure,
            events: events + [
                OperationEvent(
                    state: state,
                    occurredAt: date,
                    message: message
                )
            ]
        )
    }
}

public extension OperationLifecycleState {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .rolledBack, .verificationFailed,
                .invalidated:
            true
        case .draft, .planned, .awaitingApproval, .applying, .verifying:
            false
        }
    }
}
