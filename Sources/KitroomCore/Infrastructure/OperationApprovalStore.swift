public protocol OperationApprovalStore: Sendable {
    func approval(for planID: OperationPlan.ID) async -> OperationApproval?
    func save(_ approval: OperationApproval) async
    func removeApproval(for planID: OperationPlan.ID) async
}

public actor InMemoryOperationApprovalStore: OperationApprovalStore {
    private var approvals: [OperationPlan.ID: OperationApproval] = [:]

    public init() {}

    public func approval(for planID: OperationPlan.ID) -> OperationApproval? {
        approvals[planID]
    }

    public func save(_ approval: OperationApproval) {
        approvals[approval.planID] = approval
    }

    public func removeApproval(for planID: OperationPlan.ID) {
        approvals[planID] = nil
    }
}
