import Foundation
@testable import KitroomCore
import XCTest

final class PersistenceProductTests: XCTestCase {
    func testSwiftDataStoreBootstrapsEmptyAndSurvivesReopen() async throws {
        let directory = temporaryDirectory()
        let storeURL = directory.appendingPathComponent("Kitroom.store")
        let host = ManagedHost(name: "Fixture Mac", connection: .local)
        let snapshot = fixtureSnapshot(
            hostID: host.id,
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        let firstStore = try SwiftDataKitroomPersistence(storeURL: storeURL)
        let initiallyEmpty = try await firstStore.loadHosts()
        XCTAssertEqual(initiallyEmpty, [])

        try await firstStore.saveHosts([host])
        try await firstStore.saveInventorySnapshot(snapshot)

        let reopenedStore = try SwiftDataKitroomPersistence(storeURL: storeURL)
        let hosts = try await reopenedStore.loadHosts()
        let snapshots = try await reopenedStore.loadInventorySnapshots()

        XCTAssertEqual(hosts, [host])
        XCTAssertEqual(snapshots, [snapshot])
        XCTAssertEqual(
            SwiftDataKitroomPersistence.currentSchemaVersion,
            1
        )
    }

    func testPersistenceLoadsLatestSnapshotAndRetainsHistory() async throws {
        let directory = temporaryDirectory()
        let store = try SwiftDataKitroomPersistence(
            storeURL: directory.appendingPathComponent("Kitroom.store")
        )
        let hostID = UUID()
        let first = fixtureSnapshot(
            hostID: hostID,
            capturedAt: Date(timeIntervalSince1970: 100),
            status: .partial
        )
        let replacement = fixtureSnapshot(
            hostID: hostID,
            capturedAt: Date(timeIntervalSince1970: 200),
            status: .complete
        )

        try await store.saveInventorySnapshot(first)
        try await store.saveInventorySnapshot(replacement)

        let current = try await store.loadInventorySnapshots()
        let history = try await store.loadInventoryHistory(
            hostID: hostID,
            agent: .codex,
            limit: 10
        )

        XCTAssertEqual(current, [replacement])
        XCTAssertEqual(history, [replacement, first])
    }

    func testPersistenceLoadsLatestCatalogueAndRetainsHistory() async throws {
        let directory = temporaryDirectory()
        let store = try SwiftDataKitroomPersistence(
            storeURL: directory.appendingPathComponent("Kitroom.store")
        )
        let hostID = UUID()
        let first = CatalogueSnapshot(
            hostID: hostID,
            agent: .claude,
            capturedAt: Date(timeIntervalSince1970: 100),
            status: .partial
        )
        let replacement = CatalogueSnapshot(
            hostID: hostID,
            agent: .claude,
            capturedAt: Date(timeIntervalSince1970: 200),
            status: .complete
        )

        try await store.saveCatalogueSnapshot(first)
        try await store.saveCatalogueSnapshot(replacement)

        let current = try await store.loadCatalogueSnapshots()
        let history = try await store.loadCatalogueHistory(
            hostID: hostID,
            agent: .claude,
            limit: 10
        )

        XCTAssertEqual(current, [replacement])
        XCTAssertEqual(history, [replacement, first])
    }

    func testFreshnessTransitionsAreExplicit() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            InventoryFreshness.evaluate(
                capturedAt: now.addingTimeInterval(-899),
                now: now
            ),
            .current
        )
        XCTAssertEqual(
            InventoryFreshness.evaluate(
                capturedAt: now.addingTimeInterval(-901),
                now: now
            ),
            .stale
        )
        XCTAssertEqual(
            InventoryFreshness.evaluate(
                capturedAt: now.addingTimeInterval(61),
                now: now
            ),
            .futureDated
        )
    }

    func testInventoryQueryCombinesSearchAndStructuredFilters() {
        let fixture = fixtureItems()
        let matching = InventoryQuery(
            searchText: "review",
            agent: .codex,
            kind: .skill,
            scope: .repository,
            origin: .standalone,
            state: .enabled,
            updateStatus: .unknown
        )
        let wrongScope = InventoryQuery(
            searchText: "review",
            scope: .user
        )

        XCTAssertTrue(
            matching.matches(
                package: fixture.package,
                capability: fixture.capability,
                installation: fixture.installation
            )
        )
        XCTAssertFalse(
            wrongScope.matches(
                package: fixture.package,
                capability: fixture.capability,
                installation: fixture.installation
            )
        )
    }

    func testAccessibilityDescriptionHasStableLabelValueAndHint() {
        let fixture = fixtureItems()
        let description = InventoryAccessibilityDescription(
            package: fixture.package,
            capability: fixture.capability,
            installation: fixture.installation,
            evidenceStatus: .success
        )

        XCTAssertEqual(description.label, "Review helper")
        XCTAssertTrue(description.value.contains("skill"))
        XCTAssertTrue(description.value.contains("repository"))
        XCTAssertTrue(description.value.contains("Evidence success"))
        XCTAssertEqual(description.hint, "Shows source and evidence details")
    }

    func testDiagnosticReportOmitsAliasesPathsAndSensitiveValues() throws {
        let host = ManagedHost(
            name: "Remote Fixture",
            connection: .ssh(alias: "private-fixture-alias")
        )
        let capturedAt = Date(timeIntervalSince1970: 100)
        let evidence = EvidenceRecord(
            id: "evidence",
            probeName: "plugin inventory",
            sourceReference: "/private/example/skills",
            capturedAt: capturedAt,
            parserVersion: "fixture-v1",
            status: .failure,
            diagnostic: "token=fixture-secret-never-retain"
        )
        let inventory = InventorySnapshot(
            hostID: host.id,
            agent: .codex,
            capturedAt: capturedAt,
            status: .partial,
            installations: [
                InstallationRecord(
                    id: "installation",
                    hostID: host.id,
                    agent: .codex,
                    scope: .user,
                    origin: .standalone,
                    state: .enabled,
                    physicalOrigin: "/private/example/skills",
                    evidenceIDs: [evidence.id]
                )
            ],
            evidence: [evidence],
            issues: [
                InventoryIssue(
                    summary: "token=fixture-secret-never-retain",
                    detail: "/private/example/skills"
                )
            ]
        )

        let data = try DiagnosticReportBuilder.makeReport(
            generatedAt: capturedAt,
            hosts: [host],
            discoveries: [],
            inventories: [inventory]
        )
        let report = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(report.contains("private-fixture-alias"))
        XCTAssertFalse(report.contains("/private/example/skills"))
        XCTAssertFalse(report.contains("fixture-secret-never-retain"))
        XCTAssertTrue(report.contains("<redacted>"))
        XCTAssertTrue(report.contains("\"transport\" : \"ssh\""))
    }

    private func fixtureSnapshot(
        hostID: UUID,
        capturedAt: Date,
        status: InventoryStatus = .complete
    ) -> InventorySnapshot {
        InventorySnapshot(
            hostID: hostID,
            agent: .codex,
            capturedAt: capturedAt,
            status: status
        )
    }

    private func fixtureItems() -> (
        package: PackageRecord,
        capability: ProvidedCapability,
        installation: InstallationRecord
    ) {
        let package = PackageRecord(
            id: "package",
            agent: .codex,
            name: "review-tools",
            displayName: "Review tools"
        )
        let capability = ProvidedCapability(
            id: "capability",
            agent: .codex,
            packageID: package.id,
            kind: .skill,
            name: "review-helper",
            displayName: "Review helper"
        )
        let installation = InstallationRecord(
            id: "installation",
            hostID: UUID(),
            agent: .codex,
            packageID: package.id,
            capabilityID: capability.id,
            scope: .repository,
            origin: .standalone,
            state: .enabled
        )
        return (package, capability, installation)
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kitroom-persistence-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
