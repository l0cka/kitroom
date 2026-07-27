import Foundation
import XCTest
@testable import KitroomCore

final class NativeMCPOperationTests: XCTestCase {
    func testAddPlanUsesExactCredentialFreeHTTPSCommand() async throws {
        let fixture = try makeFixture()
        let engine = NativeMCPOperationEngine(
            backupRoot: fixture.backupRoot
        )

        let plan = try await engine.planAddCodexHTTPServer(
            host: fixture.host,
            hostIdentity: "local-fixture",
            serverName: "docs",
            serverURL: "https://example.invalid/mcp",
            executablePath: "/usr/local/bin/codex",
            configurationPath: fixture.configuration.path,
            existingCapability: nil,
            basedOnSnapshotAt: fixture.capturedAt,
            createdAt: fixture.capturedAt
        )

        XCTAssertEqual(plan.kind, .install)
        XCTAssertEqual(plan.extensionID, "mcp:docs")
        XCTAssertTrue(
            plan.changes.contains {
                $0.commandPreview?.contains(
                    "mcp add docs --url https://example.invalid/mcp"
                ) == true
            }
        )
        XCTAssertTrue(
            plan.changes.contains {
                $0.target == fixture.configuration.path
            }
        )
    }

    func testURLWithCredentialsOrQueryIsRejected() async throws {
        let fixture = try makeFixture()
        let engine = NativeMCPOperationEngine(
            backupRoot: fixture.backupRoot
        )

        for value in [
            "https://user:password@example.invalid/mcp",
            "https://example.invalid/mcp?token=secret",
            "http://example.invalid/mcp"
        ] {
            do {
                _ = try await engine.planAddCodexHTTPServer(
                    host: fixture.host,
                    hostIdentity: "local-fixture",
                    serverName: "docs",
                    serverURL: value,
                    executablePath: "/usr/local/bin/codex",
                    configurationPath: fixture.configuration.path,
                    existingCapability: nil,
                    basedOnSnapshotAt: fixture.capturedAt,
                    createdAt: fixture.capturedAt
                )
                XCTFail("Expected \(value) to be rejected.")
            } catch let error as NativeMCPOperationError {
                XCTAssertEqual(error, .invalidURL)
            }
        }
    }

    func testPluginProvidedMCPRemovalIsBlocked() async throws {
        let fixture = try makeFixture()
        let engine = NativeMCPOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let capability = ProvidedCapability(
            id: "codex:mcp:docs",
            agent: .codex,
            packageID: "codex:plugin:tools@team",
            kind: .mcpServer,
            name: "docs"
        )
        let installation = InstallationRecord(
            id: "mcp-installation",
            hostID: fixture.host.id,
            agent: .codex,
            packageID: "codex:plugin:tools@team",
            capabilityID: capability.id,
            scope: .user,
            origin: .pluginProvided,
            state: .configured,
            restriction: .agentManaged
        )

        do {
            _ = try await engine.planRemoveCodexServer(
                host: fixture.host,
                hostIdentity: "local-fixture",
                capability: capability,
                installation: installation,
                executablePath: "/usr/local/bin/codex",
                configurationPath: fixture.configuration.path,
                basedOnSnapshotAt: fixture.capturedAt,
                createdAt: fixture.capturedAt
            )
            XCTFail("Expected plugin-provided MCP removal to be blocked.")
        } catch let error as NativeMCPOperationError {
            XCTAssertEqual(error, .invalidTarget)
        }
    }

    func testAddVerificationMismatchRunsRemoveAndRestoresConfiguration() async throws {
        let fixture = try makeFixture()
        let engine = NativeMCPOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let plan = try await makeAddPlan(
            engine: engine,
            fixture: fixture
        )
        let configuration = fixture.configuration
        let changedData = Data("[mcp_servers.docs]\nurl='changed'\n".utf8)
        let session = ScriptedMCPSession(
            host: fixture.host,
            results: [
                CommandResult(
                    standardOutput: "",
                    standardError: "",
                    exitCode: 0
                ),
                CommandResult(
                    standardOutput: "",
                    standardError: "",
                    exitCode: 0
                )
            ],
            onExecute: { index in
                if index == 0 {
                    try? changedData.write(to: configuration)
                }
            }
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.capturedAt.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.capturedAt,
                targetStateMatchesPlan: true
            ),
            session: session,
            now: fixture.capturedAt.addingTimeInterval(2),
            verifyExpectedState: { false },
            verifyRolledBackState: { true }
        )

        XCTAssertEqual(result.state, .verificationFailed)
        XCTAssertEqual(result.rollbackState, .succeeded)
        XCTAssertEqual(
            try Data(contentsOf: fixture.configuration),
            fixture.originalConfiguration
        )
        let requests = await session.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[0].arguments,
            [
                "mcp",
                "add",
                "docs",
                "--url",
                "https://example.invalid/mcp"
            ]
        )
        XCTAssertEqual(
            requests[1].arguments,
            ["mcp", "remove", "docs"]
        )
    }

    func testConfigurationChangeInvalidatesBeforeCommand() async throws {
        let fixture = try makeFixture()
        let engine = NativeMCPOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let plan = try await makeAddPlan(
            engine: engine,
            fixture: fixture
        )
        try Data("changed".utf8).write(to: fixture.configuration)
        let session = ScriptedMCPSession(
            host: fixture.host,
            results: []
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.capturedAt.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.capturedAt,
                targetStateMatchesPlan: true
            ),
            session: session,
            now: fixture.capturedAt.addingTimeInterval(2),
            verifyExpectedState: { true },
            verifyRolledBackState: { true }
        )

        XCTAssertEqual(result.state, .invalidated)
        let requests = await session.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCommandFailureRedactsSecretAndRetainsBackup() async throws {
        let fixture = try makeFixture()
        let engine = NativeMCPOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let plan = try await makeAddPlan(
            engine: engine,
            fixture: fixture
        )
        let session = ScriptedMCPSession(
            host: fixture.host,
            results: [
                CommandResult(
                    standardOutput: "partial",
                    standardError: "token=supersecret",
                    standardOutputWasTruncated: true,
                    termination: .exited(code: 1)
                )
            ]
        )

        let result = await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.capturedAt.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.capturedAt,
                targetStateMatchesPlan: true
            ),
            session: session,
            now: fixture.capturedAt.addingTimeInterval(2),
            verifyExpectedState: { false },
            verifyRolledBackState: { true }
        )

        XCTAssertEqual(result.state, .rolledBack)
        XCTAssertEqual(result.rollbackState, .succeeded)
        XCTAssertNotNil(result.backupPath)
        XCTAssertFalse(result.failure?.contains("supersecret") == true)
        XCTAssertTrue(result.failure?.contains("<redacted>") == true)
    }

    private func makeAddPlan(
        engine: NativeMCPOperationEngine,
        fixture: MCPFixture
    ) async throws -> OperationPlan {
        try await engine.planAddCodexHTTPServer(
            host: fixture.host,
            hostIdentity: "local-fixture",
            serverName: "docs",
            serverURL: "https://example.invalid/mcp",
            executablePath: "/usr/local/bin/codex",
            configurationPath: fixture.configuration.path,
            existingCapability: nil,
            basedOnSnapshotAt: fixture.capturedAt,
            createdAt: fixture.capturedAt
        )
    }

    private func makeFixture() throws -> MCPFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kitroom-native-mcp-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let configuration = root.appendingPathComponent("config.toml")
        let originalConfiguration = Data("model = \"test\"\n".utf8)
        try originalConfiguration.write(to: configuration)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return MCPFixture(
            root: root,
            backupRoot: root.appendingPathComponent("backups"),
            configuration: configuration,
            originalConfiguration: originalConfiguration,
            host: ManagedHost(name: "Local", connection: .local),
            capturedAt: Date(timeIntervalSince1970: 20_000)
        )
    }
}

private struct MCPFixture {
    let root: URL
    let backupRoot: URL
    let configuration: URL
    let originalConfiguration: Data
    let host: ManagedHost
    let capturedAt: Date
}

private actor ScriptedMCPSession: HostSession {
    nonisolated let host: ManagedHost
    private var results: [CommandResult]
    private var requests: [CommandRequest] = []
    private let onExecute: @Sendable (Int) -> Void

    init(
        host: ManagedHost,
        results: [CommandResult],
        onExecute: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.host = host
        self.results = results
        self.onExecute = onExecute
    }

    func execute(_ request: CommandRequest) throws -> CommandResult {
        let index = requests.count
        requests.append(request)
        onExecute(index)
        guard !results.isEmpty else {
            throw HostSessionError.transportFailure(
                "No scripted result remains."
            )
        }
        return results.removeFirst()
    }

    func capturedRequests() -> [CommandRequest] {
        requests
    }
}
