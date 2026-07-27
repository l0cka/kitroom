import Foundation
import XCTest
@testable import KitroomCore

final class BackupRetentionTests: XCTestCase {
    func testConfirmedEligibleDeletionRemovesOnlyExactOperationDirectory() async throws {
        let fixture = try makeFixture()
        let record = fixture.record(
            state: .completed,
            rollbackState: .available
        )
        let neighbor = fixture.root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: neighbor,
            withIntermediateDirectories: true
        )

        XCTAssertTrue(BackupRetentionService.canDelete(record))
        let updated = try await fixture.service.deleteBackup(
            for: record,
            at: fixture.now
        )

        XCTAssertNil(updated.backupPath)
        XCTAssertEqual(updated.backupDeletedAt, fixture.now)
        XCTAssertEqual(updated.rollbackState, .notRequired)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.operationDirectory.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: neighbor.path)
        )
    }

    func testBackupOutsideVerifiedRootIsRejected() async throws {
        let fixture = try makeFixture()
        let outside = fixture.container.appendingPathComponent(
            "outside-backup",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let record = fixture.record(
            state: .completed,
            rollbackState: .available,
            backupPath: outside.path
        )

        do {
            _ = try await fixture.service.deleteBackup(
                for: record,
                at: fixture.now
            )
            XCTFail("Expected an outside backup to be rejected.")
        } catch let error as BackupRetentionError {
            XCTAssertEqual(error, .pathOutsideBackupRoot)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outside.path)
        )
    }

    func testUnresolvedRollbackBackupCannotBeDeleted() async throws {
        let fixture = try makeFixture()
        let record = fixture.record(
            state: .verificationFailed,
            rollbackState: .failed
        )

        XCTAssertFalse(BackupRetentionService.canDelete(record))
        do {
            _ = try await fixture.service.deleteBackup(
                for: record,
                at: fixture.now
            )
            XCTFail("Expected unresolved rollback evidence to be retained.")
        } catch let error as BackupRetentionError {
            XCTAssertEqual(error, .rollbackEvidenceRequired)
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.operationDirectory.path
            )
        )
    }

    func testDeletingBackupPreservesCompletedRollbackEvidence() async throws {
        let fixture = try makeFixture()
        let record = fixture.record(
            state: .rolledBack,
            rollbackState: .succeeded
        )

        let updated = try await fixture.service.deleteBackup(
            for: record,
            at: fixture.now
        )

        XCTAssertEqual(updated.rollbackState, .succeeded)
        XCTAssertEqual(updated.backupDeletedAt, fixture.now)
    }

    func testRemoteBackupDeletionIsNeverIssuedByLocalRetentionService() async throws {
        let fixture = try makeFixture(remote: true)
        let record = fixture.record(
            state: .completed,
            rollbackState: .available
        )

        XCTAssertFalse(BackupRetentionService.canDelete(record))
        do {
            _ = try await fixture.service.deleteBackup(
                for: record,
                at: fixture.now
            )
            XCTFail("Expected remote backup deletion to be blocked.")
        } catch let error as BackupRetentionError {
            XCTAssertEqual(error, .remoteBackupUnsupported)
        }
    }

    func testSymlinkedBackupRootCannotRedirectDeletion() async throws {
        let fixture = try makeFixture(symlinkedRoot: true)
        let externalOperationDirectory = fixture.operationDirectory
            .resolvingSymlinksInPath()
        let record = fixture.record(
            state: .completed,
            rollbackState: .available
        )

        do {
            _ = try await fixture.service.deleteBackup(
                for: record,
                at: fixture.now
            )
            XCTFail("Expected a symlinked backup root to be rejected.")
        } catch let error as BackupRetentionError {
            XCTAssertEqual(error, .backupUnavailable)
        }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: externalOperationDirectory.path
            )
        )
    }

    func testSymlinkedBackupRootCannotRedirectCreation() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kitroom-backup-creation-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let outside = container.appendingPathComponent(
            "outside",
            isDirectory: true
        )
        let root = container.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: root,
            withDestinationURL: outside
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: container)
        }

        XCTAssertThrowsError(
            try VerifiedDirectoryTree.createChildDirectory(
                named: UUID().uuidString,
                beneath: root
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: outside.path),
            []
        )
    }

    private func makeFixture(
        remote: Bool = false,
        symlinkedRoot: Bool = false
    ) throws -> BackupRetentionFixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kitroom-backup-retention-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let root = container.appendingPathComponent(
            "Backups",
            isDirectory: true
        )
        let planID = UUID()
        let operationDirectory = root.appendingPathComponent(
            planID.uuidString,
            isDirectory: true
        )
        let retained = operationDirectory.appendingPathComponent(
            "captured-content",
            isDirectory: true
        )
        if symlinkedRoot {
            let outside = container.appendingPathComponent(
                "outside",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: root,
                withDestinationURL: outside
            )
        }
        try FileManager.default.createDirectory(
            at: retained,
            withIntermediateDirectories: true
        )
        try Data("retained".utf8).write(
            to: retained.appendingPathComponent("SKILL.md")
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: container)
        }
        return BackupRetentionFixture(
            container: container,
            root: root,
            operationDirectory: operationDirectory,
            retained: retained,
            planID: planID,
            remote: remote,
            now: Date(timeIntervalSince1970: 50_000),
            service: BackupRetentionService(backupRoot: root)
        )
    }
}

private struct BackupRetentionFixture {
    let container: URL
    let root: URL
    let operationDirectory: URL
    let retained: URL
    let planID: UUID
    let remote: Bool
    let now: Date
    let service: BackupRetentionService

    func record(
        state: OperationLifecycleState,
        rollbackState: OperationRollbackState,
        backupPath: String? = nil
    ) -> OperationRecord {
        let execution: OperationExecutionSpec = remote
            ? .remoteSkill(
                RemoteSkillOperationSpec(
                    skillName: "example",
                    localSourcePath: "/fixture/example",
                    remoteDestinationPath: "/remote/.codex/skills/example",
                    remoteBackupPath: "/remote/.kitroom/backups/example",
                    createsDestinationRoot: false,
                    sourceDigest: "fixture",
                    archiveByteCount: 1_024
                )
            )
            : .localSkill(
                LocalSkillOperationSpec(
                    action: .install,
                    skillName: "example",
                    destinationPath: "/fixture/.codex/skills/example",
                    backupRoot: root.path
                )
            )
        let plan = OperationPlan(
            id: planID,
            kind: .install,
            risk: remote ? .high : .low,
            hostID: UUID(),
            hostIdentity: remote ? "remote-fixture" : "local-fixture",
            agent: .codex,
            extensionID: "example",
            basedOnSnapshotAt: now,
            changes: [
                PlannedChange(
                    summary: "Install",
                    target: remote
                        ? "/remote/.codex/skills/example"
                        : "/fixture/.codex/skills/example"
                )
            ],
            execution: execution,
            createdAt: now
        )
        return OperationRecord(
            plan: plan,
            state: state,
            updatedAt: now,
            completedAt: now,
            backupPath: backupPath ?? retained.path,
            rollbackState: rollbackState
        )
    }
}
