import Foundation
import XCTest
@testable import KitroomCore

final class RemotePluginOperationTests: XCTestCase {
    func testRemoteClaudeTogglePlanBindsIdentityVersionAndConfigurationDigest() async throws {
        let fixture = try makeFixture(state: .disabled)
        let session = LoopbackRemotePluginSession(
            host: fixture.host,
            state: .disabled,
            configuration: fixture.configuration
        )
        let engine = RemotePluginOperationEngine()

        let plan = try await makePlan(
            engine: engine,
            fixture: fixture,
            session: session,
            action: .enable
        )

        XCTAssertEqual(plan.hostIdentity, fixture.identity.value)
        XCTAssertEqual(plan.agentVersion, "2.1.207")
        XCTAssertEqual(plan.kind, .enable)
        guard case let .remotePlugin(spec) = plan.execution else {
            return XCTFail("Expected a remote plugin execution spec.")
        }
        XCTAssertEqual(spec.envelopeVersion, 1)
        XCTAssertNotNil(spec.configurationState.contentDigest)
        XCTAssertTrue(
            spec.remoteBackupPath.hasPrefix(
                fixture.remoteHome.path + "/.kitroom/backups/"
            )
        )
        XCTAssertTrue(
            plan.changes.contains {
                $0.commandPreview?.contains(
                    "plugin enable formatter@team --scope user"
                ) == true
            }
        )
    }

    func testRemoteClaudeToggleCompletesWithFreshMatchingState() async throws {
        let fixture = try makeFixture(state: .disabled)
        let session = LoopbackRemotePluginSession(
            host: fixture.host,
            state: .disabled,
            configuration: fixture.configuration
        )
        let engine = RemotePluginOperationEngine()
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture,
            session: session,
            action: .enable
        )

        let result = await apply(
            engine: engine,
            plan: plan,
            fixture: fixture,
            session: session
        )

        XCTAssertEqual(
            result.state,
            .completed,
            result.failure ?? "No failure detail"
        )
        XCTAssertEqual(result.rollbackState, .available)
        let completedState = await session.pluginState()
        XCTAssertEqual(completedState, .enabled)
        let backupPath = try XCTUnwrap(result.backupPath)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: backupPath)),
            fixture.originalConfiguration
        )
        let requests = await session.capturedRequests()
        XCTAssertTrue(
            requests.contains {
                $0.executable == fixture.executablePath
                    && $0.arguments == [
                        "plugin",
                        "enable",
                        "formatter@team",
                        "--scope",
                        "user"
                    ]
            }
        )
    }

    func testConnectionLossAfterNativeApplyRunsInverseAndRestoresRemoteConfiguration() async throws {
        let fixture = try makeFixture(state: .disabled)
        let session = LoopbackRemotePluginSession(
            host: fixture.host,
            state: .disabled,
            configuration: fixture.configuration,
            disconnectAfterFirstNativeApply: true
        )
        let engine = RemotePluginOperationEngine()
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture,
            session: session,
            action: .enable
        )

        let result = await apply(
            engine: engine,
            plan: plan,
            fixture: fixture,
            session: session
        )

        XCTAssertEqual(
            result.state,
            .rolledBack,
            result.failure ?? "No failure detail"
        )
        XCTAssertEqual(result.rollbackState, .succeeded)
        let rolledBackState = await session.pluginState()
        XCTAssertEqual(rolledBackState, .disabled)
        XCTAssertEqual(
            try Data(contentsOf: fixture.configuration),
            fixture.originalConfiguration
        )
        let nativeRequests = await session.capturedRequests().filter {
            $0.executable == fixture.executablePath
        }
        XCTAssertEqual(nativeRequests.map { $0.arguments[1] }, [
            "enable",
            "disable"
        ])
    }

    func testRemoteConfigurationDriftInvalidatesBeforeNativeCommand() async throws {
        let fixture = try makeFixture(state: .disabled)
        let session = LoopbackRemotePluginSession(
            host: fixture.host,
            state: .disabled,
            configuration: fixture.configuration
        )
        let engine = RemotePluginOperationEngine()
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture,
            session: session,
            action: .enable
        )
        try Data("{\"changed\":true}\n".utf8).write(
            to: fixture.configuration
        )

        let result = await apply(
            engine: engine,
            plan: plan,
            fixture: fixture,
            session: session
        )

        XCTAssertEqual(result.state, .invalidated)
        let requests = await session.capturedRequests()
        XCTAssertFalse(
            requests.contains {
                $0.executable == fixture.executablePath
            }
        )
    }

    func testDerivedIdentityAndUnsafeSelectorAreRejected() async throws {
        let fixture = try makeFixture(state: .disabled)
        let session = LoopbackRemotePluginSession(
            host: fixture.host,
            state: .disabled,
            configuration: fixture.configuration
        )
        let engine = RemotePluginOperationEngine()
        let derived = HostIdentityEvidence(
            kind: .derived,
            value: "derived",
            source: "fixture"
        )

        do {
            _ = try await engine.planClaudeToggle(
                host: fixture.host,
                hostIdentity: derived,
                agentVersion: "2.1.207",
                action: .enable,
                package: fixture.package,
                source: fixture.source,
                installation: fixture.installation,
                executablePath: fixture.executablePath,
                configurationPath: fixture.configuration.path,
                remoteHomeDirectory: fixture.remoteHome.path,
                session: session,
                basedOnSnapshotAt: fixture.baseline,
                createdAt: fixture.baseline
            )
            XCTFail("Expected derived host identity rejection.")
        } catch let error as RemotePluginOperationError {
            XCTAssertEqual(error, .stableHostIdentityRequired)
        }

        let unsafePackage = PackageRecord(
            id: fixture.package.id,
            agent: .claude,
            name: "--all",
            sourceID: fixture.source.id
        )
        do {
            _ = try await engine.planClaudeToggle(
                host: fixture.host,
                hostIdentity: fixture.identity,
                agentVersion: "2.1.207",
                action: .enable,
                package: unsafePackage,
                source: fixture.source,
                installation: fixture.installation,
                executablePath: fixture.executablePath,
                configurationPath: fixture.configuration.path,
                remoteHomeDirectory: fixture.remoteHome.path,
                session: session,
                basedOnSnapshotAt: fixture.baseline,
                createdAt: fixture.baseline
            )
            XCTFail("Expected unsafe selector rejection.")
        } catch let error as RemotePluginOperationError {
            XCTAssertEqual(error, .invalidSelector)
        }

        do {
            _ = try await engine.planClaudeToggle(
                host: fixture.host,
                hostIdentity: fixture.identity,
                agentVersion: "2.1.207",
                action: .enable,
                package: fixture.package,
                source: fixture.source,
                installation: fixture.installation,
                executablePath: "/",
                configurationPath: fixture.configuration.path,
                remoteHomeDirectory: fixture.remoteHome.path,
                session: session,
                basedOnSnapshotAt: fixture.baseline,
                createdAt: fixture.baseline
            )
            XCTFail("Expected a directory executable path to be rejected.")
        } catch let error as RemotePluginOperationError {
            XCTAssertEqual(error, .invalidExecutable)
        }
    }

    func testRemoteClaudeInstallUpdateAndUninstallUseNativeCommands() async throws {
        let fixture = try makeFixture(state: .enabled)
        let session = RecordingRemotePluginSession(host: fixture.host)
        let engine = RemotePluginOperationEngine()
        let updatePackage = PackageRecord(
            id: fixture.package.id,
            agent: .claude,
            name: fixture.package.name,
            sourceID: fixture.source.id,
            version: "2.0.0",
            manifestDigest: "updated-fixture-digest"
        )
        let updateInstallation = InstallationRecord(
            id: fixture.installation.id,
            hostID: fixture.host.id,
            agent: .claude,
            packageID: fixture.package.id,
            scope: .user,
            origin: .marketplace,
            state: .enabled,
            installedVersion: "1.2.3",
            updateStatus: .updateAvailable,
            restriction: .agentManaged
        )

        let install = try await engine.planPluginAction(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agentVersion: "2.1.207",
            agent: .claude,
            action: .install,
            package: fixture.package,
            source: fixture.source,
            installation: nil,
            executablePath: fixture.executablePath,
            configurationPath: fixture.configuration.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )
        let update = try await engine.planPluginAction(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agentVersion: "2.1.207",
            agent: .claude,
            action: .update,
            package: updatePackage,
            source: fixture.source,
            installation: updateInstallation,
            executablePath: fixture.executablePath,
            configurationPath: fixture.configuration.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )
        let uninstall = try await engine.planPluginAction(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agentVersion: "2.1.207",
            agent: .claude,
            action: .uninstall,
            package: fixture.package,
            source: fixture.source,
            installation: fixture.installation,
            executablePath: fixture.executablePath,
            configurationPath: fixture.configuration.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )

        XCTAssertEqual(install.kind, .install)
        XCTAssertEqual(update.kind, .update)
        XCTAssertEqual(update.risk, .high)
        XCTAssertEqual(uninstall.kind, .uninstall)
        for (plan, action) in [
            (install, "install"),
            (update, "update"),
            (uninstall, "uninstall")
        ] {
            let result = await applyRecordingPlan(
                engine: engine,
                plan: plan,
                fixture: fixture,
                session: session,
                agentVersion: "2.1.207"
            )
            XCTAssertEqual(
                result.state,
                .completed,
                result.failure ?? "No failure detail for \(action)"
            )
        }
        let commands = await session.nativeRequests()
        XCTAssertEqual(
            commands.suffix(3).map(\.arguments),
            [
                ["plugin", "install", "formatter@team", "--scope", "user"],
                ["plugin", "update", "formatter@team", "--scope", "user"],
                ["plugin", "uninstall", "formatter@team", "--scope", "user"]
            ]
        )
    }

    func testRemoteCodexInstallAndUninstallUseAddAndRemoveJSON() async throws {
        let fixture = try makeFixture(state: .enabled)
        let session = RecordingRemotePluginSession(host: fixture.host)
        let engine = RemotePluginOperationEngine()
        let source = CatalogSource(
            id: "codex:source:team",
            agent: .codex,
            name: "team",
            kind: .marketplace,
            reference: "https://example.invalid/codex-team.git",
            capturedAt: fixture.baseline
        )
        let package = PackageRecord(
            id: "codex:package:team:formatter",
            agent: .codex,
            name: "formatter",
            sourceID: source.id,
            version: "1.2.3",
            manifestDigest: "codex-fixture-digest"
        )
        let installation = InstallationRecord(
            id: "codex:installation:team:formatter",
            hostID: fixture.host.id,
            agent: .codex,
            packageID: package.id,
            scope: .user,
            origin: .marketplace,
            state: .enabled,
            installedVersion: "1.2.3",
            restriction: .agentManaged
        )
        let configuration = fixture.remoteHome
            .appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(
            at: configuration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("[plugins]\n".utf8).write(to: configuration)

        let install = try await engine.planPluginAction(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agentVersion: "codex-cli 0.145.0",
            agent: .codex,
            action: .install,
            package: package,
            source: source,
            installation: nil,
            executablePath: fixture.executablePath,
            configurationPath: configuration.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )
        let uninstall = try await engine.planPluginAction(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agentVersion: "codex-cli 0.145.0",
            agent: .codex,
            action: .uninstall,
            package: package,
            source: source,
            installation: installation,
            executablePath: fixture.executablePath,
            configurationPath: configuration.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )

        for plan in [install, uninstall] {
            let result = await applyRecordingPlan(
                engine: engine,
                plan: plan,
                fixture: fixture,
                session: session,
                agentVersion: "codex-cli 0.145.0"
            )
            XCTAssertEqual(result.state, .completed)
        }
        let commands = await session.nativeRequests()
        XCTAssertEqual(
            commands.suffix(2).map(\.arguments),
            [
                ["plugin", "add", "formatter@team", "--json"],
                ["plugin", "remove", "formatter@team", "--json"]
            ]
        )

        do {
            _ = try await engine.planPluginAction(
                host: fixture.host,
                hostIdentity: fixture.identity,
                agentVersion: "codex-cli 0.145.0",
                agent: .codex,
                action: .update,
                package: package,
                source: source,
                installation: installation,
                executablePath: fixture.executablePath,
                configurationPath: configuration.path,
                remoteHomeDirectory: fixture.remoteHome.path,
                session: session,
                basedOnSnapshotAt: fixture.baseline,
                createdAt: fixture.baseline
            )
            XCTFail("Expected remote Codex update to remain unsupported.")
        } catch let error as RemotePluginOperationError {
            XCTAssertEqual(error, .unsupportedOperation)
        }
    }

    private func apply(
        engine: RemotePluginOperationEngine,
        plan: OperationPlan,
        fixture: RemotePluginFixture,
        session: LoopbackRemotePluginSession
    ) async -> OperationRecord {
        await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.baseline,
                targetStateMatchesPlan: true,
                verifiedHostIdentity: fixture.identity.value,
                verifiedAgentVersion: "2.1.207"
            ),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: {
                await session.pluginState() == .enabled
            },
            verifyRolledBackState: {
                await session.pluginState() == .disabled
            }
        )
    }

    private func applyRecordingPlan(
        engine: RemotePluginOperationEngine,
        plan: OperationPlan,
        fixture: RemotePluginFixture,
        session: RecordingRemotePluginSession,
        agentVersion: String
    ) async -> OperationRecord {
        await engine.apply(
            plan: plan,
            approval: OperationApproval(
                plan: plan,
                approvedAt: fixture.baseline.addingTimeInterval(1)
            ),
            preflight: OperationPreflight(
                inspectedAt: fixture.baseline,
                targetStateMatchesPlan: true,
                verifiedHostIdentity: fixture.identity.value,
                verifiedAgentVersion: agentVersion
            ),
            session: session,
            now: fixture.baseline.addingTimeInterval(2),
            verifyExpectedState: { true },
            verifyRolledBackState: { false }
        )
    }

    private func makePlan(
        engine: RemotePluginOperationEngine,
        fixture: RemotePluginFixture,
        session: LoopbackRemotePluginSession,
        action: NativePluginAction
    ) async throws -> OperationPlan {
        try await engine.planClaudeToggle(
            host: fixture.host,
            hostIdentity: fixture.identity,
            agentVersion: "2.1.207",
            action: action,
            package: fixture.package,
            source: fixture.source,
            installation: fixture.installation,
            executablePath: fixture.executablePath,
            configurationPath: fixture.configuration.path,
            remoteHomeDirectory: fixture.remoteHome.path,
            session: session,
            basedOnSnapshotAt: fixture.baseline,
            createdAt: fixture.baseline
        )
    }

    private func makeFixture(
        state: EffectiveState
    ) throws -> RemotePluginFixture {
        let temporaryPath = FileManager.default.temporaryDirectory.path
        let canonicalTemporaryPath = temporaryPath.hasPrefix("/var/")
            ? "/private" + temporaryPath
            : temporaryPath
        let root = URL(fileURLWithPath: canonicalTemporaryPath)
            .appendingPathComponent(
                "kitroom-remote-plugin-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let remoteHome = root.appendingPathComponent(
            "remote-home",
            isDirectory: true
        )
        let configuration = remoteHome
            .appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: configuration.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data(
            "{\"enabledPlugins\":{\"formatter@team\":false}}\n".utf8
        )
        try original.write(to: configuration)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let host = ManagedHost(
            name: "Fixture host",
            connection: .ssh(alias: "fixture-host")
        )
        let source = CatalogSource(
            id: "claude:source:team",
            agent: .claude,
            name: "team",
            kind: .marketplace,
            reference: "https://example.invalid/team.git",
            capturedAt: Date(timeIntervalSince1970: 40_000)
        )
        let package = PackageRecord(
            id: "claude:package:team:formatter",
            agent: .claude,
            name: "formatter",
            sourceID: source.id,
            version: "1.2.3",
            manifestDigest: "fixture-package-digest"
        )
        let installation = InstallationRecord(
            id: "claude:installation:team:formatter",
            hostID: host.id,
            agent: .claude,
            packageID: package.id,
            scope: .user,
            origin: .marketplace,
            state: state,
            installedVersion: "1.2.3",
            restriction: .agentManaged
        )
        return RemotePluginFixture(
            root: root,
            remoteHome: remoteHome,
            configuration: configuration,
            originalConfiguration: original,
            executablePath: root
                .appendingPathComponent("bin/claude")
                .path,
            host: host,
            identity: HostIdentityEvidence(
                kind: .machineID,
                value: "fixture-machine-id",
                source: "fixture"
            ),
            source: source,
            package: package,
            installation: installation,
            baseline: Date(timeIntervalSince1970: 40_000)
        )
    }
}

private struct RemotePluginFixture {
    let root: URL
    let remoteHome: URL
    let configuration: URL
    let originalConfiguration: Data
    let executablePath: String
    let host: ManagedHost
    let identity: HostIdentityEvidence
    let source: CatalogSource
    let package: PackageRecord
    let installation: InstallationRecord
    let baseline: Date
}

private actor LoopbackRemotePluginSession: HostSession {
    nonisolated let host: ManagedHost
    private let executor = SystemProcessExecutor()
    private var currentState: EffectiveState
    private let configuration: URL
    private let disconnectAfterFirstNativeApply: Bool
    private var nativeExecutionCount = 0
    private var requests: [CommandRequest] = []

    init(
        host: ManagedHost,
        state: EffectiveState,
        configuration: URL,
        disconnectAfterFirstNativeApply: Bool = false
    ) {
        self.host = host
        currentState = state
        self.configuration = configuration
        self.disconnectAfterFirstNativeApply =
            disconnectAfterFirstNativeApply
    }

    func execute(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        if request.executable == "/bin/sh" {
            return try await executor.execute(request)
        }
        nativeExecutionCount += 1
        let action = request.arguments.count > 1
            ? request.arguments[1]
            : ""
        switch action {
        case "enable":
            currentState = .enabled
        case "disable":
            currentState = .disabled
        default:
            return CommandResult(
                standardOutput: "",
                standardError: "unsupported fixture action",
                exitCode: 2
            )
        }
        try Data(
            "{\"fixtureState\":\"\(currentState.rawValue)\"}\n".utf8
        ).write(to: configuration)
        if disconnectAfterFirstNativeApply,
           nativeExecutionCount == 1 {
            throw HostSessionError.connectionLost(
                "Fixture disconnected after remote native apply."
            )
        }
        return CommandResult(
            standardOutput: "{}",
            standardError: "",
            exitCode: 0
        )
    }

    func pluginState() -> EffectiveState {
        currentState
    }

    func capturedRequests() -> [CommandRequest] {
        requests
    }
}

private actor RecordingRemotePluginSession: HostSession {
    nonisolated let host: ManagedHost
    private let executor = SystemProcessExecutor()
    private var requests: [CommandRequest] = []

    init(host: ManagedHost) {
        self.host = host
    }

    func execute(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        if request.executable == "/bin/sh" {
            return try await executor.execute(request)
        }
        return CommandResult(
            standardOutput: "{}",
            standardError: "",
            exitCode: 0
        )
    }

    func nativeRequests() -> [CommandRequest] {
        requests.filter { $0.executable != "/bin/sh" }
    }
}
