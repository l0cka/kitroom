import Foundation
import XCTest
@testable import KitroomCore

final class RemoteSkillOperationTests: XCTestCase {
    func testVersionedEnvelopeInstallsIntoIsolatedRemoteProfile() async throws {
        let fixture = try makeFixture()
        let session = LoopbackRemoteSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture
        )
        let destination = fixture.remoteSkillRoot
            .appendingPathComponent("example-skill", isDirectory: true)

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.baseline,
                targetStateMatchesPlan: true,
                verifiedHostIdentity: fixture.identity.value,
                verifiedAgentVersion: "codex 1.0"
            ),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: {
                FileManager.default.fileExists(
                    atPath: destination
                        .appendingPathComponent("SKILL.md")
                        .path
                )
            },
            verifyRolledBackState: {
                !FileManager.default.fileExists(
                    atPath: destination.path
                )
            }
        )

        XCTAssertEqual(
            result.state,
            .completed,
            result.failure ?? "No failure detail"
        )
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ),
            "# Remote skill\n"
        )
        let requests = await session.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].executable, "/bin/sh")
        XCTAssertNotNil(requests[0].standardInput)
        XCTAssertFalse(requests[0].arguments.joined().contains("rm -rf"))
    }

    func testVerificationMismatchMovesExactRemoteTargetToBackup() async throws {
        let fixture = try makeFixture()
        let session = LoopbackRemoteSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture
        )
        let destination = fixture.remoteSkillRoot
            .appendingPathComponent("example-skill", isDirectory: true)

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.baseline,
                targetStateMatchesPlan: true,
                verifiedHostIdentity: fixture.identity.value,
                verifiedAgentVersion: "codex 1.0"
            ),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: { false },
            verifyRolledBackState: {
                !FileManager.default.fileExists(
                    atPath: destination.path
                )
            }
        )

        XCTAssertEqual(result.state, .verificationFailed)
        XCTAssertEqual(result.rollbackState, .succeeded)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path)
        )
        let backupPath = try XCTUnwrap(result.backupPath)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: backupPath)
                    .appendingPathComponent("SKILL.md")
                    .path
            )
        )
    }

    func testConnectionLossAfterApplyTriggersProvenRollback() async throws {
        let fixture = try makeFixture()
        let session = DisconnectingLoopbackRemoteSession(
            host: fixture.host,
            disconnectAfterFirstExecution: true
        )
        let engine = RemoteSkillOperationEngine()
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture
        )
        let destination = fixture.remoteSkillRoot
            .appendingPathComponent("example-skill", isDirectory: true)

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.baseline,
                targetStateMatchesPlan: true,
                verifiedHostIdentity: fixture.identity.value,
                verifiedAgentVersion: "codex 1.0"
            ),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: {
                FileManager.default.fileExists(atPath: destination.path)
            },
            verifyRolledBackState: {
                !FileManager.default.fileExists(atPath: destination.path)
            }
        )

        XCTAssertEqual(result.state, .rolledBack)
        XCTAssertEqual(result.rollbackState, .succeeded)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path)
        )
    }

    func testUpdateReplacesExactDestinationAndRetainsPreviousContent() async throws {
        let fixture = try makeFixture()
        let session = LoopbackRemoteSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let destination = try installExistingRemoteSkill(
            fixture: fixture,
            manifest: "# Previous remote skill\n"
        )
        let plan = try await engine.planUpdate(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agent: .codex,
            agentVersion: "codex 1.0",
            localSourceDirectory: fixture.source,
            remoteDestinationRoot: fixture.remoteSkillRoot.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: attestedPreflight(fixture),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: {
                (try? String(
                    contentsOf: destination.appendingPathComponent("SKILL.md"),
                    encoding: .utf8
                )) == "# Remote skill\n"
            },
            verifyRolledBackState: { false }
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.rollbackState, .available)
        let backupPath = try XCTUnwrap(result.backupPath)
        XCTAssertEqual(
            try String(
                contentsOf: URL(fileURLWithPath: backupPath)
                    .appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ),
            "# Previous remote skill\n"
        )
    }

    func testUpdateVerificationFailureRestoresPreviousContent() async throws {
        let fixture = try makeFixture()
        let session = LoopbackRemoteSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let destination = try installExistingRemoteSkill(
            fixture: fixture,
            manifest: "# Previous remote skill\n"
        )
        let plan = try await engine.planUpdate(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agent: .codex,
            agentVersion: "codex 1.0",
            localSourceDirectory: fixture.source,
            remoteDestinationRoot: fixture.remoteSkillRoot.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: attestedPreflight(fixture),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: { false },
            verifyRolledBackState: {
                (try? String(
                    contentsOf: destination.appendingPathComponent("SKILL.md"),
                    encoding: .utf8
                )) == "# Previous remote skill\n"
            }
        )

        XCTAssertEqual(result.state, .verificationFailed)
        XCTAssertEqual(result.rollbackState, .succeeded)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ),
            "# Previous remote skill\n"
        )
    }

    func testUninstallMovesExactDestinationToRetainedBackup() async throws {
        let fixture = try makeFixture()
        let session = LoopbackRemoteSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let destination = try installExistingRemoteSkill(
            fixture: fixture,
            manifest: "# Installed remote skill\n"
        )
        let plan = try await engine.planUninstall(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agent: .codex,
            agentVersion: "codex 1.0",
            skillName: destination.lastPathComponent,
            remoteDestinationPath: destination.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: attestedPreflight(fixture),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: {
                !FileManager.default.fileExists(atPath: destination.path)
            },
            verifyRolledBackState: { false }
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination.path)
        )
        let backupPath = try XCTUnwrap(result.backupPath)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: backupPath)
                    .appendingPathComponent("SKILL.md")
                    .path
            )
        )
    }

    func testUninstallVerificationFailureRestoresExactDestination() async throws {
        let fixture = try makeFixture()
        let session = LoopbackRemoteSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let destination = try installExistingRemoteSkill(
            fixture: fixture,
            manifest: "# Installed remote skill\n"
        )
        let plan = try await engine.planUninstall(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agent: .codex,
            agentVersion: "codex 1.0",
            skillName: destination.lastPathComponent,
            remoteDestinationPath: destination.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: attestedPreflight(fixture),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: { false },
            verifyRolledBackState: {
                FileManager.default.fileExists(
                    atPath: destination
                        .appendingPathComponent("SKILL.md")
                        .path
                )
            }
        )

        XCTAssertEqual(result.state, .verificationFailed)
        XCTAssertEqual(result.rollbackState, .succeeded)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("SKILL.md").path
            )
        )
    }

    func testRemoteDestinationDigestDriftInvalidatesBeforeMutation() async throws {
        let fixture = try makeFixture()
        let session = LoopbackRemoteSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let destination = try installExistingRemoteSkill(
            fixture: fixture,
            manifest: "# Previous remote skill\n"
        )
        let plan = try await engine.planUpdate(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agent: .codex,
            agentVersion: "codex 1.0",
            localSourceDirectory: fixture.source,
            remoteDestinationRoot: fixture.remoteSkillRoot.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )
        try Data("# Drifted remote skill\n".utf8).write(
            to: destination.appendingPathComponent("SKILL.md")
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: attestedPreflight(fixture),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: { true },
            verifyRolledBackState: { true }
        )

        XCTAssertEqual(result.state, .invalidated)
        XCTAssertEqual(
            try String(
                contentsOf: destination.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ),
            "# Drifted remote skill\n"
        )
        let requests = await session.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.standardInput == nil })
    }

    func testDerivedIdentityAndUnsafeRemotePathAreRejected() async throws {
        let fixture = try makeFixture()
        let engine = RemoteSkillOperationEngine()
        let derived = HostIdentityEvidence(
            kind: .derived,
            value: "derived",
            source: "fixture"
        )

        do {
            _ = try await engine.planInstall(
                host: fixture.host,
                hostIdentity: derived,
                agent: .codex,
                agentVersion: "codex 1.0",
                localSourceDirectory: fixture.source,
                remoteDestinationRoot: fixture.remoteSkillRoot.path,
                remoteHomeDirectory: fixture.remoteHome.path,
                createsDestinationRoot: false,
                basedOnSnapshotAt: fixture.baseline,
                createdAt: fixture.baseline
            )
            XCTFail("Expected a derived identity to be rejected.")
        } catch let error as RemoteSkillOperationError {
            XCTAssertEqual(error, .stableHostIdentityRequired)
        }

        do {
            _ = try await engine.planInstall(
                host: fixture.host,
                hostIdentity: fixture.identity,
                agent: .codex,
                agentVersion: "codex 1.0",
                localSourceDirectory: fixture.source,
                remoteDestinationRoot: fixture.remoteSkillRoot.path
                    + "\nunsafe",
                remoteHomeDirectory: fixture.remoteHome.path,
                createsDestinationRoot: false,
                basedOnSnapshotAt: fixture.baseline,
                createdAt: fixture.baseline
            )
            XCTFail("Expected an unsafe remote path to be rejected.")
        } catch let error as RemoteSkillOperationError {
            XCTAssertEqual(error, .invalidRemotePath)
        }
    }

    func testRemotePathsAreValidatedLexicallyWithoutLocalFilesystemResolution()
        async throws
    {
        let fixture = try makeFixture()
        let engine = RemoteSkillOperationEngine()

        let plan = try await engine.planInstall(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agent: .codex,
            agentVersion: "codex 1.0",
            localSourceDirectory: fixture.source,
            remoteDestinationRoot: "/private/var/lib/kitroom/skills",
            remoteHomeDirectory: "/private/var/lib/kitroom",
            createsDestinationRoot: false,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )
        XCTAssertEqual(plan.extensionID, "example-skill")

        let rootHomePlan = try await engine.planInstall(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agent: .codex,
            agentVersion: "codex 1.0",
            localSourceDirectory: fixture.source,
            remoteDestinationRoot: "/skills",
            remoteHomeDirectory: "/",
            createsDestinationRoot: false,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )
        guard case let .remoteSkill(rootHomeSpec) =
            rootHomePlan.execution else {
            return XCTFail("Expected a remote skill plan.")
        }
        XCTAssertEqual(
            rootHomeSpec.remoteDestinationPath,
            "/skills/example-skill"
        )
        XCTAssertTrue(
            rootHomeSpec.remoteBackupPath.hasPrefix("/.kitroom/backups/")
        )

        for invalidPath in [
            "/private/var/lib/../escape",
            "/private//var/lib/kitroom",
            "/private/var/lib/kitroom/",
            "private/var/lib/kitroom",
        ] {
            do {
                _ = try await engine.planInstall(
                    host: fixture.host,
                    hostIdentity: fixture.identity,
                    agent: .codex,
                    agentVersion: "codex 1.0",
                    localSourceDirectory: fixture.source,
                    remoteDestinationRoot: invalidPath,
                    remoteHomeDirectory: "/private/var/lib/kitroom",
                    createsDestinationRoot: false,
                    basedOnSnapshotAt: fixture.baseline,
                    createdAt: fixture.baseline
                )
                XCTFail("Expected \(invalidPath) to be rejected.")
            } catch let error as RemoteSkillOperationError {
                XCTAssertEqual(error, .invalidRemotePath)
            }
        }
    }

    func testApplyRequiresAttestationForTheConcreteRemoteSession() async throws {
        let fixture = try makeFixture()
        let session = LoopbackRemoteSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.baseline,
                targetStateMatchesPlan: true,
                verifiedHostIdentity: "different-machine",
                verifiedAgentVersion: "codex 1.0"
            ),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: { true },
            verifyRolledBackState: { true }
        )

        XCTAssertEqual(result.state, .invalidated)
        let requests = await session.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnsafeArchivePathIsRejected() async throws {
        let fixture = try makeFixture()
        try Data("unsafe".utf8).write(
            to: fixture.source.appendingPathComponent("two words.txt")
        )
        let engine = RemoteSkillOperationEngine()

        do {
            _ = try await makePlan(
                engine: engine,
                fixture: fixture
            )
            XCTFail("Expected an unsafe archive path to be rejected.")
        } catch let error as RemoteSkillOperationError {
            XCTAssertEqual(error, .unsafeArchivePath)
        }
    }

    func testLocalSourceDigestDriftInvalidatesBeforeRemoteTransfer() async throws {
        let fixture = try makeFixture()
        let session = LoopbackRemoteSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture
        )
        try Data("changed after planning\n".utf8).write(
            to: fixture.source.appendingPathComponent("notes.txt")
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.baseline,
                targetStateMatchesPlan: true,
                verifiedHostIdentity: fixture.identity.value,
                verifiedAgentVersion: "codex 1.0"
            ),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: { true },
            verifyRolledBackState: { true }
        )

        XCTAssertEqual(result.state, .invalidated)
        let requests = await session.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDirectoryEntriesCountTowardArchiveLimit() async throws {
        let fixture = try makeFixture()
        let engine = RemoteSkillOperationEngine()

        for index in 0 ... RemoteSkillOperationEngine.maximumFileCount {
            try FileManager.default.createDirectory(
                at: fixture.source.appendingPathComponent(
                    "directory-\(index)",
                    isDirectory: true
                ),
                withIntermediateDirectories: false
            )
        }

        do {
            _ = try await makePlan(
                engine: engine,
                fixture: fixture
            )
            XCTFail("Expected directory entries to be bounded.")
        } catch let error as RemoteSkillOperationError {
            XCTAssertEqual(error, .skillTooLarge)
        }
    }

    func testDirectoryOnlyDriftInvalidatesBeforeRemoteTransfer() async throws {
        let fixture = try makeFixture()
        let session = LoopbackRemoteSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture
        )
        try FileManager.default.createDirectory(
            at: fixture.source.appendingPathComponent(
                "added-after-planning",
                isDirectory: true
            ),
            withIntermediateDirectories: false
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.baseline,
                targetStateMatchesPlan: true,
                verifiedHostIdentity: fixture.identity.value,
                verifiedAgentVersion: "codex 1.0"
            ),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: { true },
            verifyRolledBackState: { true }
        )

        XCTAssertEqual(result.state, .invalidated)
        let requests = await session.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnavailableVerificationNeverReportsRemoteSuccess() async throws {
        let fixture = try makeFixture()
        let session = LoopbackRemoteSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.baseline,
                targetStateMatchesPlan: true,
                verifiedHostIdentity: fixture.identity.value,
                verifiedAgentVersion: "codex 1.0"
            ),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: { false },
            verifyRolledBackState: { false }
        )

        XCTAssertEqual(result.state, .verificationFailed)
        XCTAssertEqual(result.rollbackState, .failed)
        XCTAssertNotEqual(result.state, .completed)
    }

    func testRemoteEnvelopeFailureIsNotMistakenForNoOpOrSuccess() async throws {
        let fixture = try makeFixture()
        let session = FailingRemoteEnvelopeSession(host: fixture.host)
        let engine = RemoteSkillOperationEngine()
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.baseline,
                targetStateMatchesPlan: true,
                verifiedHostIdentity: fixture.identity.value,
                verifiedAgentVersion: "codex 1.0"
            ),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: { false },
            verifyRolledBackState: { true }
        )

        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.rollbackState, .notRequired)
        XCTAssertNotEqual(result.state, .completed)
    }

    private func makePlan(
        engine: RemoteSkillOperationEngine,
        fixture: RemoteSkillFixture
    ) async throws -> OperationPlan {
        try await engine.planInstall(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agent: .codex,
            agentVersion: "codex 1.0",
            localSourceDirectory: fixture.source,
            remoteDestinationRoot: fixture.remoteSkillRoot.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            createsDestinationRoot: false,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )
    }

    private func installExistingRemoteSkill(
        fixture: RemoteSkillFixture,
        manifest: String
    ) throws -> URL {
        let destination = fixture.remoteSkillRoot
            .appendingPathComponent("example-skill", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )
        try Data(manifest.utf8).write(
            to: destination.appendingPathComponent("SKILL.md")
        )
        try Data("previous fixture\n".utf8).write(
            to: destination.appendingPathComponent("notes.txt")
        )
        return destination
    }

    private func attestedPreflight(
        _ fixture: RemoteSkillFixture
    ) -> OperationPreflight {
        OperationPreflight(
            inspectedAt: fixture.baseline,
            targetStateMatchesPlan: true,
            verifiedHostIdentity: fixture.identity.value,
            verifiedAgentVersion: "codex 1.0"
        )
    }

    private func makeFixture() throws -> RemoteSkillFixture {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/")
            ? "/private" + temporaryPath
            : temporaryPath
        let root = URL(fileURLWithPath: canonicalTemporaryPath)
            .appendingPathComponent(
                "kitroom-remote-skill-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let source = root.appendingPathComponent(
            "example-skill",
            isDirectory: true
        )
        let remoteHome = root.appendingPathComponent(
            "remote-home",
            isDirectory: true
        )
        let remoteSkillRoot = remoteHome
            .appendingPathComponent(".codex/skills", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: remoteSkillRoot,
            withIntermediateDirectories: true
        )
        try Data("# Remote skill\n".utf8).write(
            to: source.appendingPathComponent("SKILL.md")
        )
        try Data("fixture\n".utf8).write(
            to: source.appendingPathComponent("notes.txt")
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return RemoteSkillFixture(
            root: root,
            source: source,
            remoteHome: remoteHome,
            remoteSkillRoot: remoteSkillRoot,
            host: ManagedHost(
                name: "Fixture host",
                connection: .ssh(alias: "fixture-host")
            ),
            identity: HostIdentityEvidence(
                kind: .machineID,
                value: "fixture-machine-id",
                source: "fixture"
            ),
            baseline: Date(timeIntervalSince1970: 30_000)
        )
    }
}

private struct RemoteSkillFixture {
    let root: URL
    let source: URL
    let remoteHome: URL
    let remoteSkillRoot: URL
    let host: ManagedHost
    let identity: HostIdentityEvidence
    let baseline: Date
}

private actor LoopbackRemoteSession: HostSession {
    nonisolated let host: ManagedHost
    private let executor = SystemProcessExecutor()
    private var requests: [CommandRequest] = []

    init(host: ManagedHost) {
        self.host = host
    }

    func execute(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        return try await executor.execute(request)
    }

    func capturedRequests() -> [CommandRequest] {
        requests
    }
}

private actor DisconnectingLoopbackRemoteSession: HostSession {
    nonisolated let host: ManagedHost
    private let executor = SystemProcessExecutor()
    private let disconnectAfterFirstExecution: Bool
    private var executionCount = 0

    init(
        host: ManagedHost,
        disconnectAfterFirstExecution: Bool
    ) {
        self.host = host
        self.disconnectAfterFirstExecution = disconnectAfterFirstExecution
    }

    func execute(_ request: CommandRequest) async throws -> CommandResult {
        executionCount += 1
        let result = try await executor.execute(request)
        if disconnectAfterFirstExecution, executionCount == 1 {
            throw HostSessionError.connectionLost(
                "Fixture disconnected after apply."
            )
        }
        return result
    }
}

private actor FailingRemoteEnvelopeSession: HostSession {
    nonisolated let host: ManagedHost

    init(host: ManagedHost) {
        self.host = host
    }

    func execute(_ request: CommandRequest) async throws -> CommandResult {
        CommandResult(
            standardOutput: "",
            standardError: "fixture filesystem does not support the requested rename",
            exitCode: 95
        )
    }
}
