import Foundation
import XCTest
@testable import KitroomCore

final class RemoteMCPOperationTests: XCTestCase {
    func testRemoteAddUsesExactCredentialFreeHTTPSCommand() async throws {
        let fixture = try makeFixture(configurationPresent: false)
        let session = LoopbackRemoteMCPSession(
            host: fixture.host,
            configuration: fixture.configuration,
            configured: false
        )
        let engine = RemoteMCPOperationEngine()
        let plan = try await makeAddPlan(
            engine: engine,
            fixture: fixture,
            session: session
        )

        guard case let .remoteMCP(spec) = plan.execution else {
            return XCTFail("Expected a remote MCP execution spec.")
        }
        XCTAssertFalse(spec.expectedBeforeConfigured)
        XCTAssertTrue(spec.expectedAfterConfigured)
        XCTAssertEqual(plan.agentVersion, "codex-cli 0.145.0")
        XCTAssertTrue(
            plan.changes.contains {
                $0.commandPreview?.contains(
                    "mcp add docs --url https://mcp.example.invalid/api"
                ) == true
            }
        )

        let result = await apply(
            engine: engine,
            plan: plan,
            fixture: fixture,
            session: session,
            expectedConfigured: true,
            rolledBackConfigured: false
        )

        XCTAssertEqual(
            result.state,
            .completed,
            result.failure ?? "No failure detail"
        )
        let configuredAfterAdd = await session.isConfigured()
        XCTAssertTrue(configuredAfterAdd)
        let requests = await session.nativeRequests()
        XCTAssertEqual(requests.last?.arguments, [
            "mcp",
            "add",
            "docs",
            "--url",
            "https://mcp.example.invalid/api"
        ])
    }

    func testRemoteAddVerificationFailureRemovesServerAndRestoresAbsence() async throws {
        let fixture = try makeFixture(configurationPresent: false)
        let session = LoopbackRemoteMCPSession(
            host: fixture.host,
            configuration: fixture.configuration,
            configured: false
        )
        let engine = RemoteMCPOperationEngine()
        let plan = try await makeAddPlan(
            engine: engine,
            fixture: fixture,
            session: session
        )

        let result = await engine.apply(
            plan: plan,
            approval: approval(plan, fixture: fixture),
            preflight: preflight(fixture),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: { false },
            verifyRolledBackState: {
                !(await session.isConfigured())
                    && !FileManager.default.fileExists(
                        atPath: fixture.configuration.path
                    )
            }
        )

        XCTAssertEqual(result.state, .verificationFailed)
        XCTAssertEqual(result.rollbackState, .succeeded)
        let configuredAfterRollback = await session.isConfigured()
        XCTAssertFalse(configuredAfterRollback)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.configuration.path
            )
        )
        let requests = await session.nativeRequests()
        XCTAssertEqual(
            requests.map { Array($0.arguments.prefix(2)) },
            [["mcp", "add"], ["mcp", "remove"]]
        )
    }

    func testRemoteRemoveRetainsDigestVerifiedConfigurationBackup() async throws {
        let fixture = try makeFixture(configurationPresent: true)
        let session = LoopbackRemoteMCPSession(
            host: fixture.host,
            configuration: fixture.configuration,
            configured: true
        )
        let engine = RemoteMCPOperationEngine()
        let capability = ProvidedCapability(
            id: "codex:mcp:docs",
            agent: .codex,
            kind: .mcpServer,
            name: "docs"
        )
        let installation = InstallationRecord(
            id: "codex:mcp-installation:docs",
            hostID: fixture.host.id,
            agent: .codex,
            capabilityID: capability.id,
            scope: .user,
            origin: .standalone,
            state: .configured,
            restriction: .agentManaged
        )
        let plan = try await engine.planRemoveCodexServer(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agentVersion: "codex-cli 0.145.0",
            capability: capability,
            installation: installation,
            executablePath: fixture.executablePath,
            configurationPath: fixture.configuration.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )

        let result = await apply(
            engine: engine,
            plan: plan,
            fixture: fixture,
            session: session,
            expectedConfigured: false,
            rolledBackConfigured: true
        )

        XCTAssertEqual(result.state, .completed)
        let configuredAfterRemove = await session.isConfigured()
        XCTAssertFalse(configuredAfterRemove)
        let backupPath = try XCTUnwrap(result.backupPath)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: backupPath)),
            fixture.originalConfiguration
        )
        let requests = await session.nativeRequests()
        XCTAssertEqual(
            requests.last?.arguments,
            ["mcp", "remove", "docs"]
        )
    }

    func testRemoteConfigurationDriftInvalidatesBeforeNativeCommand() async throws {
        let fixture = try makeFixture(configurationPresent: true)
        let session = LoopbackRemoteMCPSession(
            host: fixture.host,
            configuration: fixture.configuration,
            configured: false
        )
        let engine = RemoteMCPOperationEngine()
        let plan = try await makeAddPlan(
            engine: engine,
            fixture: fixture,
            session: session
        )
        try Data("[mcp_servers.changed]\n".utf8).write(
            to: fixture.configuration
        )

        let result = await apply(
            engine: engine,
            plan: plan,
            fixture: fixture,
            session: session,
            expectedConfigured: true,
            rolledBackConfigured: false
        )

        XCTAssertEqual(result.state, .invalidated)
        let nativeRequests = await session.nativeRequests()
        XCTAssertTrue(nativeRequests.isEmpty)
    }

    private func makeAddPlan(
        engine: RemoteMCPOperationEngine,
        fixture: RemoteMCPFixture,
        session: LoopbackRemoteMCPSession
    ) async throws -> OperationPlan {
        try await engine.planAddCodexHTTPServer(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agentVersion: "codex-cli 0.145.0",
            serverName: "docs",
            serverURL: "https://mcp.example.invalid/api",
            executablePath: fixture.executablePath,
            configurationPath: fixture.configuration.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            existingCapability: nil,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )
    }

    private func apply(
        engine: RemoteMCPOperationEngine,
        plan: OperationPlan,
        fixture: RemoteMCPFixture,
        session: LoopbackRemoteMCPSession,
        expectedConfigured: Bool,
        rolledBackConfigured: Bool
    ) async -> OperationRecord {
        await engine.apply(
            plan: plan,
            approval: approval(plan, fixture: fixture),
            preflight: preflight(fixture),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: {
                await session.isConfigured() == expectedConfigured
            },
            verifyRolledBackState: {
                await session.isConfigured() == rolledBackConfigured
            }
        )
    }

    private func approval(
        _ plan: OperationPlan,
        fixture: RemoteMCPFixture
    ) -> OperationApproval {
        OperationApproval(
            plan: plan,
            approvedAt: fixture.baseline.addingTimeInterval(1)
        )
    }

    private func preflight(
        _ fixture: RemoteMCPFixture
    ) -> OperationPreflight {
        OperationPreflight(
            inspectedAt: fixture.baseline,
            targetStateMatchesPlan: true,
            verifiedHostIdentity: fixture.identity.value,
            verifiedAgentVersion: "codex-cli 0.145.0"
        )
    }

    private func makeFixture(
        configurationPresent: Bool
    ) throws -> RemoteMCPFixture {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/")
            ? "/private" + temporaryPath
            : temporaryPath
        let root = URL(fileURLWithPath: canonicalTemporaryPath)
            .appendingPathComponent(
                "kitroom-remote-mcp-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let remoteHome = root.appendingPathComponent(
            "remote-home",
            isDirectory: true
        )
        let configuration = remoteHome
            .appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: configuration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("[mcp_servers]\n".utf8)
        if configurationPresent {
            try original.write(to: configuration)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return RemoteMCPFixture(
            remoteHome: remoteHome,
            configuration: configuration,
            originalConfiguration: original,
            executablePath: root.appendingPathComponent("bin/codex").path,
            host: ManagedHost(
                name: "Fixture host",
                connection: .ssh(alias: "fixture-host")
            ),
            identity: HostIdentityEvidence(
                kind: .machineID,
                value: "fixture-machine-id",
                source: "fixture"
            ),
            baseline: Date(timeIntervalSince1970: 50_000)
        )
    }
}

private struct RemoteMCPFixture {
    let remoteHome: URL
    let configuration: URL
    let originalConfiguration: Data
    let executablePath: String
    let host: ManagedHost
    let identity: HostIdentityEvidence
    let baseline: Date
}

private actor LoopbackRemoteMCPSession: HostSession {
    nonisolated let host: ManagedHost
    private let executor = SystemProcessExecutor()
    private let configuration: URL
    private var configured: Bool
    private var requests: [CommandRequest] = []

    init(
        host: ManagedHost,
        configuration: URL,
        configured: Bool
    ) {
        self.host = host
        self.configuration = configuration
        self.configured = configured
    }

    func execute(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        if request.executable == "/bin/sh" {
            return try await executor.execute(request)
        }
        guard request.arguments.count >= 2,
              request.arguments[0] == "mcp" else {
            return CommandResult(
                standardOutput: "",
                standardError: "unsupported fixture command",
                exitCode: 2
            )
        }
        switch request.arguments[1] {
        case "add":
            configured = true
            try Data("[mcp_servers.docs]\n".utf8).write(
                to: configuration
            )
        case "remove":
            configured = false
            if FileManager.default.fileExists(
                atPath: configuration.path
            ) {
                try FileManager.default.removeItem(at: configuration)
            }
        default:
            return CommandResult(
                standardOutput: "",
                standardError: "unsupported fixture action",
                exitCode: 2
            )
        }
        return CommandResult(
            standardOutput: "{}",
            standardError: "",
            exitCode: 0
        )
    }

    func isConfigured() -> Bool {
        configured
    }

    func nativeRequests() -> [CommandRequest] {
        requests.filter { $0.executable != "/bin/sh" }
    }
}
