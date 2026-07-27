import Foundation
@testable import KitroomCore
import XCTest

final class CatalogueTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_000)

    func testCodexCatalogueJoinsInstalledAndAvailablePackages() throws {
        let hostID = UUID()
        let marketplaces = try CodexInventoryParser.parseMarketplaces(
            fixture("Codex/marketplaces.json"),
            capturedAt: capturedAt,
            evidenceID: "codex-marketplaces"
        )
        let parsed = try CodexInventoryParser.parseCatalogue(
            fixture("Codex/catalogue.json"),
            hostID: hostID,
            capturedAt: capturedAt,
            installedInventory: nil,
            marketplaces: marketplaces,
            evidenceID: "codex-catalogue"
        )

        XCTAssertEqual(
            Set(parsed.packages.map(\.id)),
            [
                "codex:plugin:tools@team",
                "codex:plugin:managed@policy",
                "codex:plugin:new@team"
            ]
        )

        let tools = try XCTUnwrap(
            parsed.packageStates.first {
                $0.packageID == "codex:plugin:tools@team"
            }
        )
        XCTAssertEqual(tools.installedVersion, "1.0.0")
        XCTAssertEqual(tools.availableVersion, "2.0.0")
        XCTAssertEqual(tools.updateStatus, .updateAvailable)
        XCTAssertEqual(tools.integrity, .digestDeclared)

        let managed = try XCTUnwrap(
            parsed.packageStates.first {
                $0.packageID == "codex:plugin:managed@policy"
            }
        )
        XCTAssertEqual(managed.updateStatus, .incomparable)
        XCTAssertEqual(managed.restriction, .administratorManaged)

        let available = try XCTUnwrap(
            parsed.packageStates.first {
                $0.packageID == "codex:plugin:new@team"
            }
        )
        XCTAssertEqual(available.updateStatus, .notInstalled)
        XCTAssertEqual(available.compatibility, .incompatible)
        XCTAssertEqual(available.restriction, .readOnly)
        XCTAssertTrue(
            parsed.componentRoots.contains {
                $0.packageID == "codex:plugin:new@team"
                    && $0.containerPath
                        == "/fixtures/codex/marketplaces/team"
            }
        )
    }

    func testClaudeCataloguePreservesMarketplaceIdentityAndMissingMetadata() throws {
        let marketplaces = try ClaudeInventoryParser.parseMarketplaces(
            fixture("Claude/marketplaces.json"),
            capturedAt: capturedAt,
            evidenceID: "claude-marketplaces"
        )
        let parsed = try ClaudeInventoryParser.parseCatalogue(
            fixture("Claude/catalogue.json"),
            hostID: UUID(),
            capturedAt: capturedAt,
            installedInventory: nil,
            marketplaces: marketplaces,
            evidenceID: "claude-catalogue"
        )

        XCTAssertEqual(parsed.packages.count, 4)
        let formatter = try XCTUnwrap(
            parsed.packages.first {
                $0.id == "claude:plugin:formatter@team"
            }
        )
        XCTAssertEqual(formatter.publisher, "Fixture Tools")
        XCTAssertEqual(
            formatter.repository,
            "https://example.invalid/team/plugins"
        )
        XCTAssertEqual(formatter.revision, "v2.0.0")
        XCTAssertEqual(formatter.manifestDigest, "formatter-digest")

        let formatterState = try XCTUnwrap(
            parsed.packageStates.first {
                $0.packageID == formatter.id
            }
        )
        XCTAssertEqual(formatterState.installedVersion, "1.0.0")
        XCTAssertEqual(formatterState.availableVersion, "2.0.0")
        XCTAssertEqual(formatterState.updateStatus, .updateAvailable)

        let missingMetadata = try XCTUnwrap(
            parsed.packages.first {
                $0.id == "claude:plugin:review@team"
            }
        )
        XCTAssertNil(missingMetadata.publisher)
        XCTAssertNil(missingMetadata.revision)
        XCTAssertNil(missingMetadata.manifestDigest)

        XCTAssertTrue(
            parsed.packages.contains {
                $0.id == "claude:plugin:same-name@alternate"
                    && $0.name == "review"
            }
        )
        XCTAssertTrue(
            parsed.componentRoots.contains {
                $0.packageID == formatter.id
                    && $0.path
                        == "/fixtures/claude/marketplaces/team/plugins/formatter"
                    && $0.containerPath
                        == "/fixtures/claude/marketplaces/team"
            }
        )
    }

    func testComponentCollectorSkipsAbsentRootsFromMarketplaceIndex() async {
        let host = ManagedHost(name: "Fixture Mac", connection: .local)
        let container = "/fixtures/marketplace"
        let present = "\(container)/plugins/present"
        let absent = "\(container)/plugins/absent"
        let session = CatalogueFixtureSession(
            host: host,
            results: [
                requestKey(
                    "/usr/bin/find",
                    ["-L", container, "-type", "f", "-print0"]
                ): successResult(
                    "\(present)/skills/review/SKILL.md\0"
                )
            ]
        )

        let result = await CatalogueComponentCollector.scan(
            roots: [
                CatalogueComponentRoot(
                    packageID: "present-package",
                    path: present,
                    containerPath: container
                ),
                CatalogueComponentRoot(
                    packageID: "absent-package",
                    path: absent,
                    containerPath: container
                )
            ],
            session: session,
            agent: .claude,
            capturedAt: capturedAt,
            parserVersion: "fixture-v1",
            environment: [:]
        )

        XCTAssertEqual(result.issues, [])
        XCTAssertEqual(result.capabilities.count, 1)
        XCTAssertEqual(result.capabilities[0].packageID, "present-package")
        XCTAssertEqual(result.capabilities[0].kind, .skill)
        XCTAssertEqual(result.capabilities[0].name, "review")
        XCTAssertEqual(result.evidence.count, 1)
    }

    func testInventoryAnnotationUsesCatalogueUpdateState() throws {
        let hostID = UUID()
        let package = PackageRecord(
            id: "codex:plugin:tools@team",
            agent: .codex,
            name: "tools"
        )
        let installation = InstallationRecord(
            id: "installed-tools",
            hostID: hostID,
            agent: .codex,
            packageID: package.id,
            scope: .user,
            origin: .marketplace,
            state: .enabled,
            installedVersion: "1.0.0"
        )
        let inventory = InventorySnapshot(
            hostID: hostID,
            agent: .codex,
            capturedAt: capturedAt,
            status: .complete,
            packages: [package],
            installations: [installation]
        )
        let catalogue = CatalogueSnapshot(
            hostID: hostID,
            agent: .codex,
            capturedAt: capturedAt,
            status: .complete,
            packageStates: [
                CataloguePackageState(
                    id: "tools-state",
                    hostID: hostID,
                    agent: .codex,
                    packageID: package.id,
                    installedVersion: "1.0.0",
                    availableVersion: "2.0.0",
                    updateStatus: .updateAvailable
                )
            ]
        )

        let annotated = inventory.annotated(with: catalogue)

        XCTAssertEqual(
            try XCTUnwrap(annotated.installations.first).updateStatus,
            .updateAvailable
        )
    }

    func testCatalogueFreshnessUsesSameExplicitStalePolicy() {
        let now = capturedAt.addingTimeInterval(1_000)

        XCTAssertEqual(
            InventoryFreshness.evaluate(
                capturedAt: capturedAt,
                now: now
            ),
            .stale
        )
    }

    func testHostComparisonFindsSourceVersionDigestAndStateDifferences() {
        let leftHostID = UUID()
        let rightHostID = UUID()
        let left = comparisonSnapshot(
            hostID: leftHostID,
            sourceName: "team",
            sourceReference: "https://example.invalid/team",
            version: "1.0.0",
            digest: "left-digest",
            state: .enabled
        )
        let right = comparisonSnapshot(
            hostID: rightHostID,
            sourceName: "alternate",
            sourceReference: "https://example.invalid/alternate",
            version: "2.0.0",
            digest: "right-digest",
            state: .disabled
        )

        let items = HostComparisonEngine.compare(
            leftHostID: leftHostID,
            rightHostID: rightHostID,
            left: [left],
            right: [right]
        )
        let package = try! XCTUnwrap(
            items.first { $0.entityKind == .package }
        )

        XCTAssertEqual(
            Set(package.findings),
            [
                .sourceMismatch,
                .versionMismatch,
                .enabledStateMismatch,
                .digestMismatch
            ]
        )
    }

    func testHostComparisonReportsMissingAndIncomparableItems() throws {
        let leftHostID = UUID()
        let rightHostID = UUID()
        let leftPackage = PackageRecord(
            id: "left-only",
            agent: .claude,
            name: "left-only"
        )
        let unknownVersion = PackageRecord(
            id: "shared",
            agent: .claude,
            name: "shared"
        )
        let left = InventorySnapshot(
            hostID: leftHostID,
            agent: .claude,
            capturedAt: capturedAt,
            status: .complete,
            packages: [leftPackage, unknownVersion],
            installations: [
                InstallationRecord(
                    id: "left-only-installation",
                    hostID: leftHostID,
                    agent: .claude,
                    packageID: leftPackage.id,
                    scope: .user,
                    origin: .marketplace,
                    state: .enabled,
                    installedVersion: "1.0.0"
                ),
                InstallationRecord(
                    id: "left-shared-installation",
                    hostID: leftHostID,
                    agent: .claude,
                    packageID: unknownVersion.id,
                    scope: .user,
                    origin: .marketplace,
                    state: .unknown
                )
            ]
        )
        let right = InventorySnapshot(
            hostID: rightHostID,
            agent: .claude,
            capturedAt: capturedAt,
            status: .complete,
            packages: [unknownVersion],
            installations: [
                InstallationRecord(
                    id: "right-shared-installation",
                    hostID: rightHostID,
                    agent: .claude,
                    packageID: unknownVersion.id,
                    scope: .user,
                    origin: .marketplace,
                    state: .enabled,
                    installedVersion: "1.0.0"
                )
            ]
        )

        let items = HostComparisonEngine.compare(
            leftHostID: leftHostID,
            rightHostID: rightHostID,
            left: [left],
            right: [right]
        )

        XCTAssertEqual(
            items.first { $0.name == "left-only" }?.findings,
            [.onlyOnLeft]
        )
        let shared = try XCTUnwrap(
            items.first { $0.name == "shared" }
        )
        XCTAssertTrue(shared.findings.contains(.incomparable))
        XCTAssertTrue(shared.findings.contains(.enabledStateMismatch))
    }

    func testCodexCatalogueReportsNoDirectPluginUpdateSupport() async throws {
        let host = ManagedHost(name: "Fixture Mac", connection: .local)
        let session = CatalogueFixtureSession(
            host: host,
            results: [
                requestKey("/usr/bin/which", ["codex"]):
                    successResult("/fixtures/bin/codex\n"),
                requestKey("/fixtures/bin/codex", ["--version"]):
                    successResult("codex-cli fixture\n"),
                requestKey(
                    "/fixtures/bin/codex",
                    ["plugin", "--help"]
                ): successResult(
                    """
                    Usage: codex plugin

                      list
                      add
                      remove
                    """
                ),
                requestKey(
                    "/fixtures/bin/codex",
                    ["plugin", "list", "--available", "--json"]
                ): successResult(fixtureText("Codex/catalogue.json")),
                requestKey(
                    "/fixtures/bin/codex",
                    ["plugin", "marketplace", "list", "--json"]
                ): successResult(fixtureText("Codex/marketplaces.json")),
                requestKey(
                    "/usr/bin/find",
                    [
                        "-L",
                        "/fixtures/codex/marketplaces/team",
                        "-type",
                        "f",
                        "-print0"
                    ]
                ): successResult(
                    "/fixtures/codex/marketplaces/team\0"
                )
            ]
        )

        let snapshot = try await CodexAdapter(
            clock: FixedKitroomClock(now: capturedAt)
        ).inspectCatalogue(installed: nil, using: session)

        XCTAssertEqual(snapshot.status, .complete, "\(snapshot.issues)")
        XCTAssertEqual(
            snapshot.capabilities.first {
                $0.feature == .updatePlugin
            }?.support,
            .unsupported
        )
        XCTAssertEqual(snapshot.packages.count, 3)
    }

    private func comparisonSnapshot(
        hostID: UUID,
        sourceName: String,
        sourceReference: String,
        version: String,
        digest: String,
        state: EffectiveState
    ) -> InventorySnapshot {
        let source = CatalogSource(
            id: "source",
            agent: .codex,
            name: sourceName,
            kind: .git,
            reference: sourceReference,
            capturedAt: capturedAt
        )
        let package = PackageRecord(
            id: "package",
            agent: .codex,
            name: "same-name",
            sourceID: source.id,
            repository: sourceReference,
            version: version,
            manifestDigest: digest
        )
        return InventorySnapshot(
            hostID: hostID,
            agent: .codex,
            capturedAt: capturedAt,
            status: .complete,
            catalogSources: [source],
            packages: [package],
            installations: [
                InstallationRecord(
                    id: "installation-\(hostID.uuidString)",
                    hostID: hostID,
                    agent: .codex,
                    packageID: package.id,
                    scope: .user,
                    origin: .marketplace,
                    state: state,
                    installedVersion: version
                )
            ]
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

private actor CatalogueFixtureSession: HostSession {
    nonisolated let host: ManagedHost
    private let results: [String: CommandResult]

    init(host: ManagedHost, results: [String: CommandResult]) {
        self.host = host
        self.results = results
    }

    func execute(_ request: CommandRequest) throws -> CommandResult {
        guard let result = results[
            requestKey(request.executable, request.arguments)
        ] else {
            throw HostSessionError.transportFailure(
                "No fixture for \(request.executable) \(request.arguments)."
            )
        }
        return result
    }
}

private func requestKey(_ executable: String, _ arguments: [String]) -> String {
    ([executable] + arguments).joined(separator: "\u{1f}")
}

private func successResult(_ output: String = "") -> CommandResult {
    CommandResult(standardOutput: output, standardError: "", exitCode: 0)
}
