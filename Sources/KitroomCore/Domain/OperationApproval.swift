import Foundation

public struct OperationApproval: Codable, Hashable, Sendable {
    public let planID: OperationPlan.ID
    public let planDigest: String
    public let approvedAt: Date

    public init(
        planID: OperationPlan.ID,
        planDigest: String,
        approvedAt: Date
    ) {
        self.planID = planID
        self.planDigest = planDigest
        self.approvedAt = approvedAt
    }

    public init(plan: OperationPlan, approvedAt: Date) {
        self.init(
            planID: plan.id,
            planDigest: plan.approvalDigest,
            approvedAt: approvedAt
        )
    }

    public func isValid(for plan: OperationPlan) -> Bool {
        planID == plan.id && planDigest == plan.approvalDigest
    }

    public func isValid(for plan: OperationPlan, at date: Date) -> Bool {
        isValid(for: plan)
            && approvedAt >= plan.createdAt
            && !plan.isExpired(at: date)
    }
}
