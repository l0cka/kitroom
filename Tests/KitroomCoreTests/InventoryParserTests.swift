import Foundation
@testable import KitroomCore
import XCTest

final class InventoryParserTests: XCTestCase {
    private let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)

    func testCodexPluginFixturePreservesPackageAndManagementIdentity() throws {
        let inventory = try CodexInventoryParser.parsePlugins(
            fixture("Codex/plugin-list.json"),
            hostID: hostID,
            capturedAt: capturedAt
        )

        XCTAssertEqual(inventory.packages.map(\.id), [
            "codex:plugin:tools@bundled",
            "codex:plugin:review@team"
        ])
        XCTAssertEqual(inventory.installations.map(\.origin), [
            .bundled,
            .marketplace
        ])
        XCTAssertEqual(inventory.installations.map(\.state), [
            .enabled,
            .disabled
        ])
        XCTAssertEqual(
            inventory.installations.last?.restriction,
            .administratorManaged
        )
    }

    func testCodexMarketplaceAndMCPFixturesIgnoreSensitiveTransportValues() throws {
        let sources = try CodexInventoryParser.parseMarketplaces(
            fixture("Codex/marketplaces.json"),
            capturedAt: capturedAt
        )
        let mcp = try CodexInventoryParser.parseMCPServers(
            fixture("Codex/mcp-list.json"),
            hostID: hostID
        )

        XCTAssertEqual(sources.map(\.kind), [.bundled, .git])
        XCTAssertEqual(mcp.capabilities.map(\.name), [
            "docs",
            "disabled-server",
            "approval-server"
        ])
        XCTAssertEqual(mcp.installations.map(\.state), [
            .configured,
            .disabled,
            .pendingApproval
        ])
        XCTAssertFalse(
            String(describing: mcp).contains("fixture-secret-never-retain")
        )
    }

    func testClaudePluginFixturePreservesScopeAndManagedRestriction() throws {
        let inventory = try ClaudeInventoryParser.parsePlugins(
            fixture("Claude/plugin-list.json"),
            hostID: hostID,
            capturedAt: capturedAt
        )

        XCTAssertEqual(inventory.installations.map(\.scope), [.user, .managed])
        XCTAssertEqual(inventory.installations.last?.state, .disabled)
        XCTAssertEqual(
            inventory.installations.last?.restriction,
            .administratorManaged
        )
    }

    func testClaudeMCPParserExtractsNamesWithoutSecrets() throws {
        let inventory = try ClaudeMCPConfigurationParser.parse(
            fixture("Claude/configuration.json"),
            hostID: hostID
        )

        XCTAssertEqual(inventory.capabilities.map(\.name), [
            "disabled-user-server",
            "user-docs",
            "project-server"
        ])
        XCTAssertEqual(inventory.installations.map(\.scope), [
            .user,
            .user,
            .localProject
        ])
        XCTAssertFalse(
            String(describing: inventory).contains("fixture-secret-never-retain")
        )
        XCTAssertFalse(inventory.capabilities.map(\.name).contains("apiToken"))
    }

    func testClaudeProjectMCPParserPreservesApprovalStateWithoutValues() throws {
        let project = Data(
            """
            {
              "mcpServers": {
                "approved": {"env":{"TOKEN":"fixture-secret-never-retain"}},
                "denied": {"command":"fixture-secret-never-retain"},
                "pending": {"url":"https://example.invalid"}
              }
            }
            """.utf8
        )
        let user = Data(
            """
            {
              "projects": {
                "/fixtures/project": {
                  "enabledMcpjsonServers": ["approved"],
                  "disabledMcpjsonServers": ["denied"]
                }
              }
            }
            """.utf8
        )

        let inventory = try ClaudeMCPConfigurationParser
            .parseProjectConfiguration(
                project,
                userConfigurationData: user,
                hostID: hostID,
                projectRoot: "/fixtures/project"
            )

        XCTAssertEqual(
            inventory.capabilities.map(\.name),
            ["approved", "denied", "pending"]
        )
        XCTAssertEqual(
            inventory.installations.map(\.state),
            [.configured, .disabled, .pendingApproval]
        )
        XCTAssertFalse(
            String(describing: inventory).contains(
                "fixture-secret-never-retain"
            )
        )
    }

    func testMalformedAndFutureFieldsHaveExplicitOutcomes() throws {
        XCTAssertThrowsError(
            try CodexInventoryParser.parsePlugins(
                fixture("malformed.json"),
                hostID: hostID,
                capturedAt: capturedAt
            )
        )

        let forwardCompatible = try CodexInventoryParser.parsePlugins(
            fixture("Codex/plugin-list.json"),
            hostID: hostID,
            capturedAt: capturedAt
        )
        XCTAssertEqual(forwardCompatible.packages.count, 2)
    }

    func testCodexSkillConfigurationParsesOverridesWithoutOtherSettings() throws {
        let overrides = try CodexInventoryParser.parseSkillConfiguration(
            """
            model = "fixture"

            [[skills.config]]
            path = "/fixtures/skills/enabled/SKILL.md"
            enabled = true
            future_field = "ignored"

            [[skills.config]]
            path = '~/.agents/skills/disabled/SKILL.md'
            enabled = false

            [[skills.config]]
            # path = "/path/to/skill/SKILL.md"
            # enabled = false

            [[skills.config]]
            path = "/fixtures/skills/default-enabled/SKILL.md"

            [features]
            remote_plugin = true
            """
        )

        XCTAssertEqual(
            overrides,
            [
                CodexSkillConfigurationOverride(
                    path: "/fixtures/skills/enabled/SKILL.md",
                    enabled: true
                ),
                CodexSkillConfigurationOverride(
                    path: "~/.agents/skills/disabled/SKILL.md",
                    enabled: false
                ),
                CodexSkillConfigurationOverride(
                    path: "/fixtures/skills/default-enabled/SKILL.md",
                    enabled: true
                )
            ]
        )
        XCTAssertThrowsError(
            try CodexInventoryParser.parseSkillConfiguration(
                """
                [[skills.config]]
                path = "/fixtures/skills/malformed/SKILL.md"
                enabled = "sometimes"
                """
            )
        )
    }

    func testDiagnosticRedactionCoversTokensCredentialsAndURLs() {
        let value = SensitiveValueRedactor.redact(
            "Authorization: Bearer abc.def token=supersecret "
                + "https://user:password@example.invalid sk-example123456789"
        )

        XCTAssertFalse(value.contains("abc.def"))
        XCTAssertFalse(value.contains("supersecret"))
        XCTAssertFalse(value.contains(":password@"))
        XCTAssertFalse(value.contains("example123456789"))
        XCTAssertTrue(value.contains("<redacted>"))
    }

    func testDuplicateAndSymlinkedSkillsRemainDistinctEvidence() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let userRoot = temporaryRoot.appendingPathComponent("user", isDirectory: true)
        let repositoryRoot = temporaryRoot.appendingPathComponent("repo", isDirectory: true)
        let target = userRoot.appendingPathComponent("shared", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(
            """
            ---
            name: duplicate
            description: Fixture skill
            ---
            Instructions.
            """.utf8
        ).write(to: target.appendingPathComponent("SKILL.md"))
        try fileManager.createDirectory(
            at: repositoryRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: repositoryRoot.appendingPathComponent("linked"),
            withDestinationURL: target
        )

        let host = ManagedHost(name: "Fixture", connection: .local)
        let session = try LocalHostSession(
            host: host,
            executor: SystemProcessExecutor()
        )
        let user = await SkillInventoryScanner.scan(
            session: session,
            agent: .codex,
            root: userRoot.path,
            scope: .user,
            origin: .standalone,
            capturedAt: capturedAt,
            parserVersion: "fixture",
            environment: HostEnvironment.standard
        )
        let repository = await SkillInventoryScanner.scan(
            session: session,
            agent: .codex,
            root: repositoryRoot.path,
            scope: .repository,
            origin: .shared,
            capturedAt: capturedAt,
            parserVersion: "fixture",
            environment: HostEnvironment.standard
        )

        XCTAssertEqual(
            user.capabilities.map(\.name),
            ["duplicate"],
            "\(user.evidence) \(user.issues)"
        )
        XCTAssertEqual(
            repository.capabilities.map(\.name),
            ["duplicate"],
            "\(repository.evidence) \(repository.issues)"
        )
        XCTAssertNotEqual(
            user.capabilities.first?.id,
            repository.capabilities.first?.id
        )
        XCTAssertTrue(
            Set(user.evidence.map(\.id))
                .isDisjoint(with: Set(repository.evidence.map(\.id)))
        )
        XCTAssertEqual(repository.installations.first?.scope, .repository)
    }

    func testPluginComponentsExposeNamesWithoutConfigurationValues() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: root.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(
            to: root.appendingPathComponent("bin/kit-tool")
        )
        try Data(
            """
            {
              "mcpServers": {
                "plugin-docs": {
                  "env": {
                    "API_TOKEN": "fixture-secret-never-retain"
                  }
                }
              }
            }
            """.utf8
        ).write(to: root.appendingPathComponent(".mcp.json"))
        try Data(
            """
            {"languageServers":{"swift-lsp":{"command":"fixture-secret-never-retain"}}}
            """.utf8
        ).write(to: root.appendingPathComponent(".lsp.json"))

        let host = ManagedHost(name: "Fixture", connection: .local)
        let session = try LocalHostSession(
            host: host,
            executor: SystemProcessExecutor()
        )
        let scan = await PluginComponentScanner.scan(
            session: session,
            agent: .claude,
            packageID: "claude:plugin:fixture",
            root: root.path,
            capturedAt: capturedAt,
            parserVersion: "fixture",
            environment: HostEnvironment.standard
        )

        XCTAssertEqual(
            Set(scan.capabilities.map(\.name)),
            Set(["kit-tool", "plugin-docs", "swift-lsp"])
        )
        XCTAssertEqual(
            Set(scan.capabilities.map(\.kind)),
            Set([.executable, .mcpServer, .lspServer])
        )
        XCTAssertFalse(
            String(describing: scan).contains("fixture-secret-never-retain")
        )
        XCTAssertTrue(scan.issues.isEmpty, "\(scan.issues)")
    }

    func testPluginProvidedCapabilityWinsOverStandaloneDuplicate() {
        let direct = ProvidedCapability(
            id: "direct",
            agent: .codex,
            kind: .mcpServer,
            name: "docs"
        )
        let plugin = ProvidedCapability(
            id: "plugin",
            agent: .codex,
            packageID: "package",
            kind: .mcpServer,
            name: "docs"
        )
        let directInstallation = InstallationRecord(
            id: "direct-installation",
            hostID: hostID,
            agent: .codex,
            capabilityID: direct.id,
            scope: .user,
            origin: .standalone,
            state: .configured
        )
        let pluginInstallation = InstallationRecord(
            id: "plugin-installation",
            hostID: hostID,
            agent: .codex,
            packageID: "package",
            capabilityID: plugin.id,
            scope: .user,
            origin: .pluginProvided,
            state: .enabled
        )

        let normalized = InventoryNormalizer
            .removingStandaloneDuplicatesOfPluginCapabilities(
                capabilities: [direct, plugin],
                installations: [directInstallation, pluginInstallation]
            )

        XCTAssertEqual(normalized.capabilities.map(\.id), ["plugin"])
        XCTAssertEqual(normalized.installations.map(\.id), ["plugin-installation"])
    }

    func testPathInspectionDistinguishesAbsentFromDenied() async {
        let host = ManagedHost(name: "Fixture", connection: .local)
        let absent = ScriptedInventorySession(
            host: host,
            results: [
                "/bin/test": CommandResult(
                    standardOutput: "",
                    standardError: "",
                    exitCode: 1
                ),
                "/bin/ls": CommandResult(
                    standardOutput: "",
                    standardError: "No such file or directory",
                    exitCode: 2
                )
            ]
        )
        let denied = ScriptedInventorySession(
            host: host,
            results: [
                "/bin/test": CommandResult(
                    standardOutput: "",
                    standardError: "",
                    exitCode: 1
                ),
                "/bin/ls": CommandResult(
                    standardOutput: "",
                    standardError: "Permission denied",
                    exitCode: 2
                )
            ]
        )

        let absentResult = await PathInventoryInspector.inspect(
            session: absent,
            path: "/fixtures/absent",
            kind: .directory,
            name: "fixture-path",
            parserVersion: "fixture",
            capturedAt: capturedAt,
            environment: [:]
        )
        let deniedResult = await PathInventoryInspector.inspect(
            session: denied,
            path: "/fixtures/denied",
            kind: .directory,
            name: "fixture-path",
            parserVersion: "fixture",
            capturedAt: capturedAt,
            environment: [:]
        )

        XCTAssertEqual(absentResult.isPresent, false)
        XCTAssertNil(absentResult.issue)
        XCTAssertNil(deniedResult.isPresent)
        XCTAssertNotNil(deniedResult.issue)
    }

    func testProjectDirectoryInspectionBuildsRootToWorkingDirectoryHierarchy() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let nested = root.appendingPathComponent("packages/client", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)

        let host = ManagedHost(name: "Fixture", connection: .local)
        let session = try LocalHostSession(
            host: host,
            executor: SystemProcessExecutor()
        )
        let initialization = try await session.execute(
            CommandRequest(
                executable: "/usr/bin/git",
                arguments: ["-C", root.path, "init", "--quiet"],
                environment: HostEnvironment.standard
            )
        )
        XCTAssertTrue(initialization.succeeded)

        let inspection = await ProjectDirectoryInspector.inspect(
            session: session,
            workingDirectory: nested.path,
            agent: .codex,
            parserVersion: "fixture",
            capturedAt: capturedAt,
            environment: HostEnvironment.standard
        )

        let rootResult = try await session.execute(
            CommandRequest(
                executable: "/usr/bin/git",
                arguments: ["-C", root.path, "rev-parse", "--show-toplevel"],
                environment: HostEnvironment.standard
            )
        )
        let canonicalRoot = URL(
            fileURLWithPath: rootResult.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let canonicalNested = canonicalRoot
            .appendingPathComponent("packages/client")
        XCTAssertEqual(inspection.root, canonicalRoot.path)
        XCTAssertEqual(
            inspection.hierarchy,
            [
                canonicalRoot.path,
                canonicalRoot.appendingPathComponent("packages").path,
                canonicalNested.path
            ]
        )
        XCTAssertTrue(inspection.issues.isEmpty, "\(inspection.issues)")
    }

    func testCodexAdapterHandlesOlderHelpAndDeduplicatesPluginMCP() async throws {
        let host = ManagedHost(name: "Fixture", connection: .local)
        let pluginMCPPath = "/fixtures/codex/marketplaces/bundled/tools/.mcp.json"
        let pluginList = fixtureText("Codex/plugin-list.json")
            .replacingOccurrences(
                of: "/fixtures/codex/plugins/tools",
                with: "tools"
            )
            .replacingOccurrences(
                of: "/fixtures/codex/plugins/review",
                with: "review"
            )
        let session = FixtureInventorySession(
            host: host,
            results: [
                requestKey("/usr/bin/which", ["codex"]): successResult(
                    "/fixtures/bin/codex\n"
                ),
                requestKey("/fixtures/bin/codex", ["--version"]): successResult(
                    "codex-cli fixture\n"
                ),
                requestKey(
                    "/fixtures/bin/codex",
                    ["plugin", "--help"]
                ): successResult("Usage: codex plugin list\n"),
                requestKey(
                    "/fixtures/bin/codex",
                    ["plugin", "list", "--json"]
                ): successResult(pluginList),
                requestKey(
                    "/fixtures/bin/codex",
                    ["plugin", "marketplace", "list", "--json"]
                ): successResult(fixtureText("Codex/marketplaces.json")),
                requestKey(
                    "/fixtures/bin/codex",
                    ["mcp", "list", "--json"]
                ): successResult(fixtureText("Codex/mcp-list.json")),
                requestKey("/usr/bin/printenv", ["HOME"]): successResult(
                    "/fixtures/home\n"
                ),
                requestKey(
                    "/usr/bin/find",
                    [
                        "-L",
                        "/fixtures/codex/marketplaces/bundled/tools",
                        "-type",
                        "f",
                        "-print0"
                    ]
                ): successResult(pluginMCPPath + "\0"),
                requestKey(
                    "/usr/bin/find",
                    [
                        "-L",
                        "/fixtures/codex/marketplaces/team/review",
                        "-type",
                        "f",
                        "-print0"
                    ]
                ): successResult(),
                requestKey("/bin/cat", [pluginMCPPath]): successResult(
                    """
                    {"mcpServers":{"docs":{"env":{"TOKEN":"fixture-secret-never-retain"}}}}
                    """
                )
            ],
            fallback: { request in
                if request.executable == "/bin/test" {
                    return failedResult()
                }
                if request.executable == "/bin/ls" {
                    return failedResult(
                        error: "No such file or directory"
                    )
                }
                throw HostSessionError.transportFailure(
                    "No fixture for \(request.executable) \(request.arguments)."
                )
            }
        )

        let snapshot = try await CodexAdapter(
            clock: FixedKitroomClock(now: capturedAt)
        ).inspect(using: session)

        XCTAssertEqual(snapshot.status, .complete, "\(snapshot.issues)")
        XCTAssertEqual(snapshot.agentVersion, "codex-cli fixture")
        XCTAssertEqual(
            snapshot.capabilities.first {
                $0.feature == .installPlugin
            }?.support,
            .unknown
        )
        let docs = snapshot.providedCapabilities.filter {
            $0.kind == .mcpServer && $0.name == "docs"
        }
        XCTAssertEqual(docs.count, 1)
        XCTAssertNotNil(docs.first?.packageID)
        XCTAssertTrue(snapshot.packages.allSatisfy { !$0.evidenceIDs.isEmpty })
        XCTAssertTrue(
            snapshot.providedCapabilities.allSatisfy {
                !$0.evidenceIDs.isEmpty
            }
        )
        XCTAssertTrue(
            snapshot.installations.allSatisfy { !$0.evidenceIDs.isEmpty }
        )
        XCTAssertFalse(
            String(describing: snapshot).contains(
                "fixture-secret-never-retain"
            )
        )
    }

    func testClaudeAdapterTreatsMissingRootsAsCompleteAndKeepsMCPState() async throws {
        let host = ManagedHost(name: "Fixture", connection: .local)
        let session = FixtureInventorySession(
            host: host,
            results: [
                requestKey("/usr/bin/which", ["claude"]): successResult(
                    "/fixtures/bin/claude\n"
                ),
                requestKey("/fixtures/bin/claude", ["--version"]): successResult(
                    "2.fixture\n"
                ),
                requestKey(
                    "/fixtures/bin/claude",
                    ["plugin", "--help"]
                ): successResult(
                    """
                    Commands:
                      list       List plugins
                      install    Install a plugin
                    """
                ),
                requestKey(
                    "/fixtures/bin/claude",
                    ["plugin", "list", "--json"]
                ): successResult(fixtureText("Claude/plugin-list.json")),
                requestKey(
                    "/fixtures/bin/claude",
                    ["plugin", "marketplace", "list", "--json"]
                ): successResult(fixtureText("Claude/marketplaces.json")),
                requestKey("/usr/bin/printenv", ["HOME"]): successResult(
                    "/fixtures/home\n"
                ),
                requestKey(
                    "/bin/test",
                    ["-f", "/fixtures/home/.claude.json"]
                ): successResult(),
                requestKey(
                    "/bin/cat",
                    ["/fixtures/home/.claude.json"]
                ): successResult(fixtureText("Claude/configuration.json")),
                requestKey(
                    "/usr/bin/find",
                    [
                        "-L",
                        "/fixtures/claude/plugins/formatter",
                        "-type",
                        "f",
                        "-print0"
                    ]
                ): successResult(),
                requestKey(
                    "/usr/bin/find",
                    [
                        "-L",
                        "/fixtures/claude/plugins/policy",
                        "-type",
                        "f",
                        "-print0"
                    ]
                ): successResult()
            ],
            fallback: { request in
                if request.executable == "/bin/test" {
                    return failedResult()
                }
                if request.executable == "/bin/ls" {
                    return failedResult(
                        error: "No such file or directory"
                    )
                }
                throw HostSessionError.transportFailure(
                    "No fixture for \(request.executable) \(request.arguments)."
                )
            }
        )

        let snapshot = try await ClaudeAdapter(
            clock: FixedKitroomClock(now: capturedAt)
        ).inspect(using: session)

        XCTAssertEqual(snapshot.status, .complete, "\(snapshot.issues)")
        let observedStates = Set(snapshot.installations.map(\.state))
        XCTAssertFalse(
            observedStates.intersection([
                EffectiveState.pendingApproval,
                .disabled,
                .configured
            ]).isEmpty
        )
        XCTAssertEqual(
            snapshot.capabilities.first {
                $0.feature == .updatePlugin
            }?.support,
            .unknown
        )
        XCTAssertTrue(snapshot.packages.allSatisfy { !$0.evidenceIDs.isEmpty })
        XCTAssertTrue(
            snapshot.providedCapabilities.allSatisfy {
                !$0.evidenceIDs.isEmpty
            }
        )
        XCTAssertTrue(
            snapshot.installations.allSatisfy { !$0.evidenceIDs.isEmpty }
        )
        XCTAssertFalse(
            String(describing: snapshot).contains(
                "fixture-secret-never-retain"
            )
        )
    }

    private func fixture(_ relativePath: String) -> Data {
        let testDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        return try! Data(
            contentsOf: testDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures")
                .appendingPathComponent(relativePath)
        )
    }

    private func fixtureText(_ relativePath: String) -> String {
        String(decoding: fixture(relativePath), as: UTF8.self)
    }
}

private actor ScriptedInventorySession: HostSession {
    nonisolated let host: ManagedHost
    private let results: [String: CommandResult]

    init(host: ManagedHost, results: [String: CommandResult]) {
        self.host = host
        self.results = results
    }

    func execute(_ request: CommandRequest) throws -> CommandResult {
        guard let result = results[request.executable] else {
            throw HostSessionError.transportFailure(
                "No fixture for \(request.executable)."
            )
        }
        return result
    }
}

private actor FixtureInventorySession: HostSession {
    nonisolated let host: ManagedHost
    private let results: [String: CommandResult]
    private let fallback: @Sendable (CommandRequest) throws -> CommandResult

    init(
        host: ManagedHost,
        results: [String: CommandResult],
        fallback: @escaping @Sendable (CommandRequest) throws -> CommandResult
    ) {
        self.host = host
        self.results = results
        self.fallback = fallback
    }

    func execute(_ request: CommandRequest) throws -> CommandResult {
        if let result = results[requestKey(request.executable, request.arguments)] {
            return result
        }
        return try fallback(request)
    }
}

private func requestKey(_ executable: String, _ arguments: [String]) -> String {
    ([executable] + arguments).joined(separator: "\u{1f}")
}

private func successResult(_ output: String = "") -> CommandResult {
    CommandResult(standardOutput: output, standardError: "", exitCode: 0)
}

private func failedResult(
    _ code: Int32 = 1,
    error: String = ""
) -> CommandResult {
    CommandResult(standardOutput: "", standardError: error, exitCode: code)
}
