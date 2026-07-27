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
                targetStateMatchesPlan: true
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
                targetStateMatchesPlan: true
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
                targetStateMatchesPlan: true
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
                targetStateMatchesPlan: true
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
                targetStateMatchesPlan: true
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
                targetStateMatchesPlan: true
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

    private func makeFixture() throws -> RemoteSkillFixture {
        let root = FileManager.default.temporaryDirectory
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
