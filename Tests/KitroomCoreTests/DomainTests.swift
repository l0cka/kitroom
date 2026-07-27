import Foundation
@testable import KitroomCore
import XCTest

final class DomainTests: XCTestCase {
    func testLegacyRemoteExecutionSpecsDecodeWithSafeDefaults() throws {
        let legacyPlugin = Data(
            #"""
            {
              "envelopeVersion": 1,
              "agent": "claude",
              "action": "enable",
              "selector": "formatter@team",
              "scope": "user",
              "executablePath": "/usr/local/bin/claude",
              "configurationState": {
                "path": "/fixture/.claude/settings.json",
                "contentDigest": "fixture-digest"
              },
              "remoteBackupPath": "/fixture/.kitroom/backups/plan/settings.json",
              "expectedBeforeState": "disabled",
              "expectedAfterState": "enabled",
              "expectedVersion": "1.2.3"
            }
            """#.utf8
        )
        let plugin = try JSONDecoder().decode(
            RemotePluginOperationSpec.self,
            from: legacyPlugin
        )
        XCTAssertTrue(plugin.expectedBeforeInstalled)
        XCTAssertTrue(plugin.expectedAfterInstalled)
        XCTAssertEqual(plugin.expectedBeforeVersion, "1.2.3")
        XCTAssertEqual(plugin.expectedAfterVersion, "1.2.3")
        XCTAssertFalse(plugin.requiresCataloguePreflight)

        let legacySkill = Data(
            #"""
            {
              "envelopeVersion": 1,
              "skillName": "fixture",
              "localSourcePath": "/fixture/source",
              "remoteDestinationPath": "/fixture/skills/fixture",
              "remoteBackupPath": "/fixture/backups/plan/fixture",
              "createsDestinationRoot": false,
              "sourceDigest": "fixture-digest",
              "archiveByteCount": 1024
            }
            """#.utf8
        )
        let skill = try JSONDecoder().decode(
            RemoteSkillOperationSpec.self,
            from: legacySkill
        )
        XCTAssertEqual(skill.action, .install)
        XCTAssertNil(skill.expectedDestinationDigest)
    }

    func testRemoteHostDescriptionPreservesAlias() {
        let host = ManagedHost(
            name: "Build Server",
            connection: .ssh(alias: "build-server")
        )

        XCTAssertTrue(host.connection.isRemote)
        XCTAssertEqual(host.connection.description, "SSH · build-server")
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

    func testRemoteApprovalDigestBindsHostIdentityAndAgentVersion() {
        let id = UUID()
        let hostID = UUID()
        let snapshotDate = Date(timeIntervalSince1970: 1_700_000_000)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_100)
        func plan(identity: String, version: String) -> OperationPlan {
            OperationPlan(
                id: id,
                kind: .install,
                risk: .high,
                hostID: hostID,
                hostIdentity: identity,
                agent: .codex,
                agentVersion: version,
                extensionID: "example",
                basedOnSnapshotAt: snapshotDate,
                changes: [
                    PlannedChange(
                        summary: "Install",
                        target: "/remote/example"
                    )
                ],
                createdAt: createdAt
            )
        }

        let baseline = plan(
            identity: "remote-machine-a",
            version: "codex 1.0"
        )
        XCTAssertNotEqual(
            baseline.approvalDigest,
            plan(
                identity: "remote-machine-b",
                version: "codex 1.0"
            ).approvalDigest
        )
        XCTAssertNotEqual(
            baseline.approvalDigest,
            plan(
                identity: "remote-machine-a",
                version: "codex 1.1"
            ).approvalDigest
        )
    }

    func testHostAliasValidationRejectsShellSyntax() {
        XCTAssertTrue(HostAliasValidator.isValid("build-server"))
        XCTAssertTrue(HostAliasValidator.isValid("dev.example-1"))
        XCTAssertFalse(HostAliasValidator.isValid(""))
        XCTAssertFalse(HostAliasValidator.isValid("build-server; reboot"))
        XCTAssertFalse(HostAliasValidator.isValid("$(whoami)"))
    }
}
