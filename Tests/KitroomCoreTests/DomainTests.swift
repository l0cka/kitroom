import Foundation
@testable import KitroomCore
import XCTest

final class DomainTests: XCTestCase {
    func testRemoteHostDescriptionPreservesAlias() {
        let host = ManagedHost(
            name: "Argus",
            connection: .ssh(alias: "argus")
        )

        XCTAssertTrue(host.connection.isRemote)
        XCTAssertEqual(host.connection.description, "SSH · argus")
    }

    func testMutationPlanRequiresConfirmation() {
        let plan = OperationPlan(
            kind: .uninstall,
            risk: .medium,
            hostID: UUID(),
            agent: .codex,
            extensionID: "example-skill",
            basedOnSnapshotAt: Date(timeIntervalSince1970: 1_700_000_000),
            changes: [
                PlannedChange(
                    summary: "Remove example skill",
                    target: "~/.codex/skills/example-skill",
                    commandPreview: "codex plugin remove example-skill",
                    rollback: "Restore the captured backup"
                )
            ]
        )

        XCTAssertTrue(plan.requiresConfirmation)
        XCTAssertEqual(plan.approvalDigest.count, 64)
    }

    func testInspectionPlanDoesNotRequireConfirmation() {
        let plan = OperationPlan(
            kind: .inspect,
            risk: .readOnly,
            hostID: UUID(),
            agent: .claude,
            basedOnSnapshotAt: .distantPast,
            changes: []
        )

        XCTAssertFalse(plan.requiresConfirmation)
    }

    func testApprovalDigestChangesWithTarget() {
        let id = UUID()
        let hostID = UUID()
        let snapshotDate = Date(timeIntervalSince1970: 1_700_000_000)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_100)

        let first = OperationPlan(
            id: id,
            kind: .install,
            risk: .low,
            hostID: hostID,
            agent: .codex,
            extensionID: "example",
            basedOnSnapshotAt: snapshotDate,
            changes: [PlannedChange(summary: "Install", target: "/first")],
            createdAt: createdAt
        )
        let second = OperationPlan(
            id: id,
            kind: .install,
            risk: .low,
            hostID: hostID,
            agent: .codex,
            extensionID: "example",
            basedOnSnapshotAt: snapshotDate,
            changes: [PlannedChange(summary: "Install", target: "/second")],
            createdAt: createdAt
        )

        XCTAssertNotEqual(first.approvalDigest, second.approvalDigest)
    }

    func testHostAliasValidationRejectsShellSyntax() {
        XCTAssertTrue(HostAliasValidator.isValid("argus"))
        XCTAssertTrue(HostAliasValidator.isValid("dev.example-1"))
        XCTAssertFalse(HostAliasValidator.isValid(""))
        XCTAssertFalse(HostAliasValidator.isValid("argus; reboot"))
        XCTAssertFalse(HostAliasValidator.isValid("$(whoami)"))
    }
}

