import Foundation
import XCTest
@testable import KitroomCore

final class NativePluginOperationTests: XCTestCase {
    func testClaudeTogglePlanUsesTypedNativeCommandAndConfigurationDigest() async throws {
        let fixture = try makeFixture(state: .disabled)
        let engine = NativePluginOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let plan = try await engine.planClaudeToggle(
            host: fixture.host,
            hostIdentity: "local-fixture",
            action: .enable,
            package: fixture.package,
            source: fixture.source,
            installation: fixture.installation,
            executablePath: "/usr/local/bin/claude",
            configurationPaths: [fixture.configuration.path],
            basedOnSnapshotAt: fixture.capturedAt,
            createdAt: fixture.capturedAt
        )

        XCTAssertEqual(plan.kind, .enable)
        XCTAssertEqual(plan.scope, .user)
        XCTAssertEqual(plan.extensionID, "formatter@team")
        guard case let .nativePlugin(spec) = plan.execution else {
            return XCTFail("Expected a native plugin execution spec.")
        }
        XCTAssertEqual(spec.action, .enable)
        XCTAssertEqual(spec.selector, "formatter@team")
        XCTAssertNotNil(spec.configurationStates.first?.contentDigest)
        XCTAssertTrue(
            plan.changes.contains {
                $0.commandPreview?.contains(
                "plugin enable formatter@team --scope user"
                ) == true
            }
        )
        XCTAssertTrue(
            plan.changes.contains {
                $0.target == fixture.configuration.path
                    && $0.commandPreview?.contains("private backup") == true
            }
        )
    }

    func testSuccessfulToggleRequiresFreshExpectedState() async throws {
        let fixture = try makeFixture(state: .disabled)
        let engine = NativePluginOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture,
            action: .enable
        )
        let session = ScriptedPluginSession(
            host: fixture.host,
            results: [
                CommandResult(
                    standardOutput: "{}",
                    standardError: "",
                    exitCode: 0
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
            verifyExpectedState: { true },
            verifyRolledBackState: { false }
        )

        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.rollbackState, .available)
        let requests = await session.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests[0].arguments,
            ["plugin", "enable", "formatter@team", "--scope", "user"]
        )
        XCTAssertEqual(requests[0].executable, "/usr/local/bin/claude")
    }

    func testVerificationMismatchRunsInverseAndRestoresConfiguration() async throws {
        let fixture = try makeFixture(state: .enabled)
        let engine = NativePluginOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture,
            action: .disable
        )
        let changedData = Data("{\"changed\":true}".utf8)
        let session = ScriptedPluginSession(
            host: fixture.host,
            results: [
                CommandResult(
                    standardOutput: "{}",
                    standardError: "",
                    exitCode: 0
                ),
                CommandResult(
                    standardOutput: "{}",
                    standardError: "",
                    exitCode: 0
                )
            ],
            onExecute: { index in
                if index == 0 {
                    try? changedData.write(to: fixture.configuration)
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
        XCTAssertEqual(requests[0].arguments[1], "disable")
        XCTAssertEqual(requests[1].arguments[1], "enable")
    }

    func testConfigurationChangeInvalidatesApprovalBeforeCommand() async throws {
        let fixture = try makeFixture(state: .disabled)
        let engine = NativePluginOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture,
            action: .enable
        )
        try Data("{\"changed\":true}".utf8).write(
            to: fixture.configuration
        )
        let session = ScriptedPluginSession(
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

    func testUnsafePluginSelectorIsRejected() async throws {
        let fixture = try makeFixture(state: .disabled)
        let engine = NativePluginOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let unsafePackage = PackageRecord(
            id: fixture.package.id,
            agent: .claude,
            name: "--all",
            sourceID: fixture.source.id
        )

        do {
            _ = try await engine.planClaudeToggle(
                host: fixture.host,
                hostIdentity: "local-fixture",
                action: .enable,
                package: unsafePackage,
                source: fixture.source,
                installation: fixture.installation,
                executablePath: "/usr/local/bin/claude",
                configurationPaths: [fixture.configuration.path],
                basedOnSnapshotAt: fixture.capturedAt,
                createdAt: fixture.capturedAt
            )
            XCTFail("Expected the selector to be rejected.")
        } catch let error as NativePluginOperationError {
            XCTAssertEqual(error, .invalidSelector)
        }
    }

    func testOriginallyAbsentConfigurationIsRemovedOnRollback() async throws {
        let fixture = try makeFixture(state: .disabled)
        try FileManager.default.removeItem(at: fixture.configuration)
        let engine = NativePluginOperationEngine(
            backupRoot: fixture.backupRoot
        )
        let plan = try await makePlan(
            engine: engine,
            fixture: fixture,
            action: .enable
        )
        let configuration = fixture.configuration
        let session = ScriptedPluginSession(
            host: fixture.host,
            results: [
                CommandResult(
                    standardOutput: "{}",
                    standardError: "",
                    exitCode: 0
                ),
                CommandResult(
                    standardOutput: "{}",
                    standardError: "",
                    exitCode: 0
                )
            ],
            onExecute: { index in
                if index == 0 {
                    try? Data("{\"created\":true}".utf8)
                        .write(to: configuration)
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
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.configuration.path
            )
        )
    }

    func testClaudeInstallPlanUsesNativeInstallAndCataloguePreflight() async throws {
        let fixture = try makeFixture(state: .enabled)
        let engine = NativePluginOperationEngine(
            backupRoot: fixture.backupRoot
        )

        let plan = try await engine.planPluginAction(
            host: fixture.host,
            hostIdentity: "local-fixture",
            agent: .claude,
            action: .install,
            package: fixture.package,
            source: fixture.source,
            installation: nil,
            executablePath: "/usr/local/bin/claude",
            configurationPaths: [fixture.configuration.path],
            basedOnSnapshotAt: fixture.capturedAt,
            createdAt: fixture.capturedAt
        )

        XCTAssertEqual(plan.kind, .install)
        guard case let .nativePlugin(spec) = plan.execution else {
            return XCTFail("Expected a native plugin execution spec.")
        }
        XCTAssertFalse(spec.expectedBeforeInstalled)
        XCTAssertTrue(spec.expectedAfterInstalled)
        XCTAssertTrue(spec.requiresCataloguePreflight)
        XCTAssertTrue(
            plan.changes.contains {
                $0.commandPreview?.contains(
                    "plugin install formatter@team --scope user"
                ) == true
            }
        )
    }

    func testCodexInstallAndUninstallUseAddAndRemoveJSONCommands() async throws {
        let fixture = try makeFixture(state: .enabled)
        let codexPackage = PackageRecord(
            id: "codex:plugin:formatter@team",
            agent: .codex,
            name: fixture.package.name,
            sourceID: "codex:marketplace:team",
            version: fixture.package.version
        )
        let codexSource = CatalogSource(
            id: "codex:marketplace:team",
            agent: .codex,
            name: fixture.source.name,
            kind: .marketplace,
            capturedAt: fixture.capturedAt
        )
        let codexInstallation = InstallationRecord(
            id: "codex-installation",
            hostID: fixture.host.id,
            agent: .codex,
            packageID: codexPackage.id,
            scope: .user,
            origin: .marketplace,
            state: .enabled,
            installedVersion: codexPackage.version,
            restriction: .agentManaged
        )
        let engine = NativePluginOperationEngine(
            backupRoot: fixture.backupRoot
        )

        let install = try await engine.planPluginAction(
            host: fixture.host,
            hostIdentity: "local-fixture",
            agent: .codex,
            action: .install,
            package: codexPackage,
            source: codexSource,
            installation: nil,
            executablePath: "/usr/local/bin/codex",
            configurationPaths: [fixture.configuration.path],
            basedOnSnapshotAt: fixture.capturedAt,
            createdAt: fixture.capturedAt
        )
        let uninstall = try await engine.planPluginAction(
            host: fixture.host,
            hostIdentity: "local-fixture",
            agent: .codex,
            action: .uninstall,
            package: codexPackage,
            source: codexSource,
            installation: codexInstallation,
            executablePath: "/usr/local/bin/codex",
            configurationPaths: [fixture.configuration.path],
            basedOnSnapshotAt: fixture.capturedAt,
            createdAt: fixture.capturedAt
        )

        XCTAssertTrue(
            install.changes.contains {
                $0.commandPreview?.contains(
                    "plugin add formatter@team --json"
                ) == true
            }
        )
        XCTAssertTrue(
            uninstall.changes.contains {
                $0.commandPreview?.contains(
                    "plugin remove formatter@team --json"
                ) == true
            }
        )
    }

    func testClaudeUpdateIsHighRiskAndHasNoFalseRollbackPromise() async throws {
        let fixture = try makeFixture(state: .enabled)
        let availablePackage = PackageRecord(
            id: fixture.package.id,
            agent: .claude,
            name: fixture.package.name,
            sourceID: fixture.package.sourceID,
            version: "2.0.0"
        )
        let installed = InstallationRecord(
            id: fixture.installation.id,
            hostID: fixture.host.id,
            agent: .claude,
            packageID: availablePackage.id,
            scope: .user,
            origin: .marketplace,
            state: .enabled,
            installedVersion: "1.2.3",
            updateStatus: .updateAvailable,
            restriction: .agentManaged
        )
        let engine = NativePluginOperationEngine(
            backupRoot: fixture.backupRoot
        )

        let plan = try await engine.planPluginAction(
            host: fixture.host,
            hostIdentity: "local-fixture",
            agent: .claude,
            action: .update,
            package: availablePackage,
            source: fixture.source,
            installation: installed,
            executablePath: "/usr/local/bin/claude",
            configurationPaths: [fixture.configuration.path],
            basedOnSnapshotAt: fixture.capturedAt,
            createdAt: fixture.capturedAt
        )

        XCTAssertEqual(plan.kind, .update)
        XCTAssertEqual(plan.risk, .high)
        XCTAssertTrue(plan.warnings.contains { $0.contains("incomplete") })
        XCTAssertTrue(
            plan.changes.contains {
                $0.commandPreview?.contains(
                    "plugin update formatter@team --scope user"
                ) == true
            }
        )
    }

    func testCodexUpdateIsRejectedAsUnsupported() async throws {
        let fixture = try makeFixture(state: .enabled)
        let package = PackageRecord(
            id: "codex:plugin:formatter@team",
            agent: .codex,
            name: "formatter",
            sourceID: "codex:marketplace:team",
            version: "2.0.0"
        )
        let source = CatalogSource(
            id: "codex:marketplace:team",
            agent: .codex,
            name: "team",
            kind: .marketplace,
            capturedAt: fixture.capturedAt
        )
        let installation = InstallationRecord(
            id: "codex-installation",
            hostID: fixture.host.id,
            agent: .codex,
            packageID: package.id,
            scope: .user,
            origin: .marketplace,
            state: .enabled,
            installedVersion: "1.2.3",
            updateStatus: .updateAvailable,
            restriction: .agentManaged
        )
        let engine = NativePluginOperationEngine(
            backupRoot: fixture.backupRoot
        )

        do {
            _ = try await engine.planPluginAction(
                host: fixture.host,
                hostIdentity: "local-fixture",
                agent: .codex,
                action: .update,
                package: package,
                source: source,
                installation: installation,
                executablePath: "/usr/local/bin/codex",
                configurationPaths: [fixture.configuration.path],
                basedOnSnapshotAt: fixture.capturedAt,
                createdAt: fixture.capturedAt
            )
            XCTFail("Expected Codex update to be rejected.")
        } catch let error as NativePluginOperationError {
            XCTAssertEqual(error, .unsupportedAction)
        }
    }

    private func makePlan(
        engine: NativePluginOperationEngine,
        fixture: PluginFixture,
        action: NativePluginAction
    ) async throws -> OperationPlan {
        try await engine.planClaudeToggle(
            host: fixture.host,
            hostIdentity: "local-fixture",
            action: action,
            package: fixture.package,
            source: fixture.source,
            installation: fixture.installation,
            executablePath: "/usr/local/bin/claude",
            configurationPaths: [fixture.configuration.path],
            basedOnSnapshotAt: fixture.capturedAt,
            createdAt: fixture.capturedAt
        )
    }

    private func makeFixture(
        state: EffectiveState
    ) throws -> PluginFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kitroom-native-plugin-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let configuration = root.appendingPathComponent("settings.json")
        let originalConfiguration = Data("{\"enabled\":true}".utf8)
        try originalConfiguration.write(to: configuration)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let host = ManagedHost(name: "Local", connection: .local)
        let capturedAt = Date(timeIntervalSince1970: 10_000)
        let package = PackageRecord(
            id: "claude:plugin:formatter@team",
            agent: .claude,
            name: "formatter",
            sourceID: "claude:marketplace:team",
            version: "1.2.3"
        )
        let source = CatalogSource(
            id: "claude:marketplace:team",
            agent: .claude,
            name: "team",
            kind: .marketplace,
            capturedAt: capturedAt
        )
        let installation = InstallationRecord(
            id: "installation",
            hostID: host.id,
            agent: .claude,
            packageID: package.id,
            scope: .user,
            origin: .marketplace,
            state: state,
            installedVersion: "1.2.3",
            restriction: .agentManaged
        )
        return PluginFixture(
            root: root,
            backupRoot: root.appendingPathComponent("backups"),
            configuration: configuration,
            originalConfiguration: originalConfiguration,
            host: host,
            capturedAt: capturedAt,
            package: package,
            source: source,
            installation: installation
        )
    }
}

private struct PluginFixture {
    let root: URL
    let backupRoot: URL
    let configuration: URL
    let originalConfiguration: Data
    let host: ManagedHost
    let capturedAt: Date
    let package: PackageRecord
    let source: CatalogSource
    let installation: InstallationRecord
}

private actor ScriptedPluginSession: HostSession {
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
