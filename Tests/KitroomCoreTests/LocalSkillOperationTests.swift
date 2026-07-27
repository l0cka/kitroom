import Foundation
import XCTest
@testable import KitroomCore

final class LocalSkillOperationTests: XCTestCase {
    func testCopiedSkillDigestIsStable() async throws {
        let fixture = try makeFixture()
        let copy = fixture.destinationRoot.appendingPathComponent(
            ".example-skill.kitroom-stage-test",
            isDirectory: true
        )
        try FileManager.default.copyItem(at: fixture.source, to: copy)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: copy.path
        )
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot
        )

        let sourceDigest = try await engine.digestOfSkill(at: fixture.source)
        let copyDigest = try await engine.digestOfSkill(at: copy)

        XCTAssertEqual(sourceDigest, copyDigest)
    }

    func testApprovalExpiresAndDigestCoversExecutionTarget() {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let host = ManagedHost(name: "Local", connection: .local)
        let first = plan(
            host: host,
            destination: "/tmp/profile-a/skills/example",
            createdAt: createdAt
        )
        let second = plan(
            host: host,
            destination: "/tmp/profile-b/skills/example",
            createdAt: createdAt
        )
        let approval = OperationApproval(
            plan: first,
            approvedAt: createdAt.addingTimeInterval(1)
        )

        XCTAssertNotEqual(first.approvalDigest, second.approvalDigest)
        XCTAssertTrue(
            approval.isValid(
                for: first,
                at: createdAt.addingTimeInterval(2)
            )
        )
        XCTAssertFalse(
            approval.isValid(
                for: first,
                at: first.expiresAt
            )
        )
    }

    func testInstallAndUninstallUseExactTargetAndRecoverableBackup() async throws {
        let fixture = try makeFixture()
        let host = ManagedHost(name: "Local", connection: .local)
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let baseline = Date(timeIntervalSince1970: 2_000)
        let install = try await engine.planInstall(
            host: host,
            hostIdentity: "local-test",
            agent: .codex,
            sourceDirectory: fixture.source,
            destinationRoot: fixture.destinationRoot,
            basedOnSnapshotAt: baseline,
            createdAt: baseline
        )
        let installResult = await engine.apply(
            plan: install,
            approval: OperationApproval(
                plan: install,
                approvedAt: baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: baseline,
                targetStateMatchesPlan: true
            ),
            now: baseline.addingTimeInterval(2)
        )
        let destination = fixture.destinationRoot
            .appendingPathComponent("example-skill", isDirectory: true)

        XCTAssertEqual(
            installResult.state,
            .completed,
            installResult.failure ?? "No failure detail"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("SKILL.md").path
            )
        )

        let uninstallBaseline = baseline.addingTimeInterval(30)
        let uninstall = try await engine.planUninstall(
            host: host,
            hostIdentity: "local-test",
            agent: .codex,
            skillName: "example-skill",
            destinationDirectory: destination,
            basedOnSnapshotAt: uninstallBaseline,
            createdAt: uninstallBaseline
        )
        let uninstallResult = await engine.apply(
            plan: uninstall,
            approval: OperationApproval(
                plan: uninstall,
                approvedAt: uninstallBaseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: uninstallBaseline,
                targetStateMatchesPlan: true
            ),
            now: uninstallBaseline.addingTimeInterval(2)
        )

        XCTAssertEqual(uninstallResult.state, .completed)
        XCTAssertEqual(uninstallResult.rollbackState, .available)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path)
        )
        let backupPath = try XCTUnwrap(uninstallResult.backupPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupPath))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: URL(fileURLWithPath: backupPath)
                .deletingLastPathComponent()
                .path
        )
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    func testChangedInventoryInvalidatesApprovedPlan() async throws {
        let fixture = try makeFixture()
        let host = ManagedHost(name: "Local", connection: .local)
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let baseline = Date(timeIntervalSince1970: 3_000)
        let operation = try await engine.planInstall(
            host: host,
            hostIdentity: nil,
            agent: .claude,
            sourceDirectory: fixture.source,
            destinationRoot: fixture.destinationRoot,
            basedOnSnapshotAt: baseline,
            createdAt: baseline
        )

        let result = await engine.apply(
            plan: operation,
            approval: OperationApproval(
                plan: operation,
                approvedAt: baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: baseline.addingTimeInterval(1),
                targetStateMatchesPlan: false
            ),
            now: baseline.addingTimeInterval(2)
        )

        XCTAssertEqual(result.state, .invalidated)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationRoot
                    .appendingPathComponent("example-skill")
                    .path
            )
        )
    }

    func testSourceChangeInvalidatesPlanBeforeApply() async throws {
        let fixture = try makeFixture()
        let host = ManagedHost(name: "Local", connection: .local)
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let baseline = Date(timeIntervalSince1970: 4_000)
        let operation = try await engine.planInstall(
            host: host,
            hostIdentity: nil,
            agent: .codex,
            sourceDirectory: fixture.source,
            destinationRoot: fixture.destinationRoot,
            basedOnSnapshotAt: baseline,
            createdAt: baseline
        )
        try Data("# changed".utf8).write(
            to: fixture.source.appendingPathComponent("SKILL.md")
        )

        let result = await engine.apply(
            plan: operation,
            approval: OperationApproval(
                plan: operation,
                approvedAt: baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: baseline,
                targetStateMatchesPlan: true
            ),
            now: baseline.addingTimeInterval(2)
        )

        XCTAssertEqual(result.state, .invalidated)
        XCTAssertEqual(result.failure, "Source digest changed.")
    }

    func testIdenticalInstalledSkillIsIdempotentNoOp() async throws {
        let fixture = try makeFixture()
        let destination = fixture.destinationRoot
            .appendingPathComponent("example-skill", isDirectory: true)
        try FileManager.default.copyItem(
            at: fixture.source,
            to: destination
        )
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot
        )

        do {
            _ = try await engine.planInstall(
                host: ManagedHost(name: "Local", connection: .local),
                hostIdentity: nil,
                agent: .codex,
                sourceDirectory: fixture.source,
                destinationRoot: fixture.destinationRoot,
                basedOnSnapshotAt: Date(),
                createdAt: Date()
            )
            XCTFail("Expected an idempotent no-op.")
        } catch let error as LocalSkillOperationError {
            XCTAssertEqual(error, .noChangesRequired)
        }
    }

    func testInstallCreatesOnlyTheMissingAgentSkillRoot() async throws {
        let fixture = try makeFixture()
        try FileManager.default.removeItem(at: fixture.destinationRoot)
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let baseline = Date(timeIntervalSince1970: 4_500)
        let operation = try await engine.planInstall(
            host: ManagedHost(name: "Local", connection: .local),
            hostIdentity: nil,
            agent: .codex,
            sourceDirectory: fixture.source,
            destinationRoot: fixture.destinationRoot,
            basedOnSnapshotAt: baseline,
            createdAt: baseline
        )
        XCTAssertEqual(operation.changes.count, 2)

        let result = await engine.apply(
            plan: operation,
            approval: OperationApproval(
                plan: operation,
                approvedAt: baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: baseline,
                targetStateMatchesPlan: true
            ),
            now: baseline.addingTimeInterval(2)
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destinationRoot
                    .appendingPathComponent("example-skill/SKILL.md")
                    .path
            )
        )
    }

    func testUpdateAtomicallyReplacesSkillAndRetainsPreviousContent() async throws {
        let fixture = try makeFixture()
        let destination = fixture.destinationRoot
            .appendingPathComponent("example-skill", isDirectory: true)
        try FileManager.default.copyItem(
            at: fixture.source,
            to: destination
        )
        let previous = try Data(
            contentsOf: destination.appendingPathComponent("SKILL.md")
        )
        try Data("# Updated skill\n".utf8).write(
            to: fixture.source.appendingPathComponent("SKILL.md")
        )
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let baseline = Date(timeIntervalSince1970: 4_700)
        let plan = try await engine.planUpdate(
            host: ManagedHost(name: "Local", connection: .local),
            hostIdentity: "local-test",
            agent: .codex,
            sourceDirectory: fixture.source,
            destinationRoot: fixture.destinationRoot,
            basedOnSnapshotAt: baseline,
            createdAt: baseline
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: baseline,
                targetStateMatchesPlan: true
            ),
            now: baseline.addingTimeInterval(2)
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.rollbackState, .available)
        XCTAssertEqual(
            try Data(
                contentsOf: destination.appendingPathComponent("SKILL.md")
            ),
            Data("# Updated skill\n".utf8)
        )
        let backupPath = try XCTUnwrap(result.backupPath)
        XCTAssertEqual(
            try Data(
                contentsOf: URL(fileURLWithPath: backupPath)
                    .appendingPathComponent("SKILL.md")
            ),
            previous
        )
    }

    func testUpdateVerificationFailureAtomicallyRestoresPreviousContent() async throws {
        let fixture = try makeFixture()
        let destination = fixture.destinationRoot
            .appendingPathComponent("example-skill", isDirectory: true)
        try FileManager.default.copyItem(
            at: fixture.source,
            to: destination
        )
        let previousDigestEngine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let previousDigest = try await previousDigestEngine.digestOfSkill(
            at: destination
        )
        try Data("# Updated skill\n".utf8).write(
            to: fixture.source.appendingPathComponent("SKILL.md")
        )
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot,
            injectedFault: .forceVerificationMismatch
        )
        let baseline = Date(timeIntervalSince1970: 4_800)
        let plan = try await engine.planUpdate(
            host: ManagedHost(name: "Local", connection: .local),
            hostIdentity: "local-test",
            agent: .claude,
            sourceDirectory: fixture.source,
            destinationRoot: fixture.destinationRoot,
            basedOnSnapshotAt: baseline,
            createdAt: baseline
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: baseline,
                targetStateMatchesPlan: true
            ),
            now: baseline.addingTimeInterval(2)
        )

        XCTAssertEqual(result.state, .verificationFailed)
        XCTAssertEqual(result.rollbackState, .succeeded)
        let restoredDigest = try await previousDigestEngine.digestOfSkill(
            at: destination
        )
        XCTAssertEqual(restoredDigest, previousDigest)
    }

    func testUpdateInvalidatesWhenInstalledContentChanges() async throws {
        let fixture = try makeFixture()
        let destination = fixture.destinationRoot
            .appendingPathComponent("example-skill", isDirectory: true)
        try FileManager.default.copyItem(
            at: fixture.source,
            to: destination
        )
        try Data("# Updated source\n".utf8).write(
            to: fixture.source.appendingPathComponent("SKILL.md")
        )
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let baseline = Date(timeIntervalSince1970: 4_900)
        let plan = try await engine.planUpdate(
            host: ManagedHost(name: "Local", connection: .local),
            hostIdentity: "local-test",
            agent: .codex,
            sourceDirectory: fixture.source,
            destinationRoot: fixture.destinationRoot,
            basedOnSnapshotAt: baseline,
            createdAt: baseline
        )
        try Data("# Changed after planning\n".utf8).write(
            to: destination.appendingPathComponent("SKILL.md")
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: baseline,
                targetStateMatchesPlan: true
            ),
            now: baseline.addingTimeInterval(2)
        )

        XCTAssertEqual(result.state, .invalidated)
        XCTAssertEqual(result.failure, "Target digest changed.")
    }

    func testAtomicStagingInterruptionLeavesDestinationAbsent() async throws {
        let fixture = try makeFixture()
        let host = ManagedHost(name: "Local", connection: .local)
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot,
            injectedFault: .afterStaging
        )
        let baseline = Date(timeIntervalSince1970: 5_000)
        let operation = try await engine.planInstall(
            host: host,
            hostIdentity: nil,
            agent: .codex,
            sourceDirectory: fixture.source,
            destinationRoot: fixture.destinationRoot,
            basedOnSnapshotAt: baseline,
            createdAt: baseline
        )

        let result = await engine.apply(
            plan: operation,
            approval: OperationApproval(
                plan: operation,
                approvedAt: baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: baseline,
                targetStateMatchesPlan: true
            ),
            now: baseline.addingTimeInterval(2)
        )

        XCTAssertEqual(result.state, .failed)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationRoot
                    .appendingPathComponent("example-skill")
                    .path
            )
        )
        let staged = try FileManager.default.contentsOfDirectory(
            atPath: fixture.destinationRoot.path
        )
        XCTAssertTrue(staged.isEmpty)
    }

    func testVerificationFailureRollsInstalledContentOutOfLoadPath() async throws {
        let fixture = try makeFixture()
        let host = ManagedHost(name: "Local", connection: .local)
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot,
            injectedFault: .forceVerificationMismatch
        )
        let baseline = Date(timeIntervalSince1970: 6_000)
        let operation = try await engine.planInstall(
            host: host,
            hostIdentity: nil,
            agent: .claude,
            sourceDirectory: fixture.source,
            destinationRoot: fixture.destinationRoot,
            basedOnSnapshotAt: baseline,
            createdAt: baseline
        )

        let result = await engine.apply(
            plan: operation,
            approval: OperationApproval(
                plan: operation,
                approvedAt: baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: baseline,
                targetStateMatchesPlan: true
            ),
            now: baseline.addingTimeInterval(2)
        )

        XCTAssertEqual(
            result.state,
            .verificationFailed,
            result.failure ?? "No failure detail"
        )
        XCTAssertEqual(result.rollbackState, .succeeded)
        XCTAssertNotNil(result.backupPath)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationRoot
                    .appendingPathComponent("example-skill")
                    .path
            )
        )
    }

    func testAgentVerificationFailureRollsBackInstall() async throws {
        let fixture = try makeFixture()
        let host = ManagedHost(name: "Local", connection: .local)
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let baseline = Date(timeIntervalSince1970: 7_000)
        let operation = try await engine.planInstall(
            host: host,
            hostIdentity: nil,
            agent: .codex,
            sourceDirectory: fixture.source,
            destinationRoot: fixture.destinationRoot,
            basedOnSnapshotAt: baseline,
            createdAt: baseline
        )

        let result = await engine.apply(
            plan: operation,
            approval: OperationApproval(
                plan: operation,
                approvedAt: baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: baseline,
                targetStateMatchesPlan: true
            ),
            now: baseline.addingTimeInterval(2),
            verifyEffectiveState: { false }
        )

        XCTAssertEqual(result.state, .verificationFailed)
        XCTAssertEqual(result.rollbackState, .succeeded)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationRoot
                    .appendingPathComponent("example-skill")
                    .path
            )
        )
    }

    func testRollbackFailureRemainsDistinctAndTargetIsNotClaimedSafe() async throws {
        let fixture = try makeFixture()
        try Data("not a directory".utf8).write(to: fixture.backupRoot)
        let host = ManagedHost(name: "Local", connection: .local)
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot,
            injectedFault: .forceVerificationMismatch
        )
        let baseline = Date(timeIntervalSince1970: 8_000)
        let operation = try await engine.planInstall(
            host: host,
            hostIdentity: nil,
            agent: .claude,
            sourceDirectory: fixture.source,
            destinationRoot: fixture.destinationRoot,
            basedOnSnapshotAt: baseline,
            createdAt: baseline
        )

        let result = await engine.apply(
            plan: operation,
            approval: OperationApproval(
                plan: operation,
                approvedAt: baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: baseline,
                targetStateMatchesPlan: true
            ),
            now: baseline.addingTimeInterval(2)
        )

        XCTAssertEqual(result.state, .verificationFailed)
        XCTAssertEqual(result.rollbackState, .failed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destinationRoot
                    .appendingPathComponent("example-skill")
                    .path
            )
        )
    }

    func testSymbolicLinkInSkillIsRejected() async throws {
        let fixture = try makeFixture()
        try FileManager.default.createSymbolicLink(
            at: fixture.source.appendingPathComponent("linked.txt"),
            withDestinationURL: fixture.source.appendingPathComponent(
                "notes.txt"
            )
        )
        let engine = LocalSkillOperationEngine(
            backupRoot: fixture.backupRoot
        )

        do {
            _ = try await engine.planInstall(
                host: ManagedHost(name: "Local", connection: .local),
                hostIdentity: nil,
                agent: .codex,
                sourceDirectory: fixture.source,
                destinationRoot: fixture.destinationRoot,
                basedOnSnapshotAt: Date(),
                createdAt: Date()
            )
            XCTFail("Expected the symbolic link to be rejected.")
        } catch let error as LocalSkillOperationError {
            XCTAssertEqual(error, .unsafeSymbolicLink)
        }
    }

    private func plan(
        host: ManagedHost,
        destination: String,
        createdAt: Date
    ) -> OperationPlan {
        OperationPlan(
            kind: .install,
            risk: .medium,
            hostID: host.id,
            agent: .codex,
            extensionID: "example",
            scope: .user,
            contentDigest: "digest",
            expectedAfterDigest: "digest",
            basedOnSnapshotAt: createdAt,
            changes: [
                PlannedChange(
                    summary: "Install",
                    target: destination
                )
            ],
            execution: .localSkill(
                LocalSkillOperationSpec(
                    action: .install,
                    skillName: "example",
                    sourcePath: "/tmp/source/example",
                    destinationPath: destination,
                    backupRoot: "/tmp/backups",
                    sourceDigest: "digest"
                )
            ),
            createdAt: createdAt
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent(
            "example-skill",
            isDirectory: true
        )
        let destinationRoot = root.appendingPathComponent(
            "profile/skills",
            isDirectory: true
        )
        let backupRoot = root.appendingPathComponent(
            "backups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        try Data("# Example skill\n".utf8).write(
            to: source.appendingPathComponent("SKILL.md")
        )
        try Data("fixture\n".utf8).write(
            to: source.appendingPathComponent("notes.txt")
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            source: source,
            destinationRoot: destinationRoot,
            backupRoot: backupRoot
        )
    }
}

private struct Fixture {
    let source: URL
    let destinationRoot: URL
    let backupRoot: URL
}
