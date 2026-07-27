import Foundation
@testable import KitroomCore
import XCTest

final class FoundationTests: XCTestCase {
    func testFixedClockReturnsInjectedDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = FixedKitroomClock(now: date)

        XCTAssertEqual(clock.now, date)
    }

    func testDefaultAdapterRegistryContainsInitialAgents() {
        let registry = DefaultAgentAdapterRegistry()

        XCTAssertEqual(Set(registry.supportedAgents), Set(AgentKind.allCases))
        XCTAssertEqual(registry.adapter(for: .codex)?.agent, .codex)
        XCTAssertEqual(registry.adapter(for: .claude)?.agent, .claude)
    }

    func testInMemoryPersistenceReplacesSnapshotAtAgentAndHostGrain() async {
        let host = ManagedHost(name: "Fixture", connection: .local)
        let store = InMemoryKitroomPersistence(hosts: [host])
        let first = InventorySnapshot(
            hostID: host.id,
            agent: .codex,
            capturedAt: Date(timeIntervalSince1970: 1),
            status: .partial,
            extensions: []
        )
        let replacement = InventorySnapshot(
            hostID: host.id,
            agent: .codex,
            capturedAt: Date(timeIntervalSince1970: 2),
            status: .complete,
            extensions: []
        )

        await store.saveInventorySnapshot(first)
        await store.saveInventorySnapshot(replacement)

        let snapshots = await store.loadInventorySnapshots()
        let hosts = await store.loadHosts()
        XCTAssertEqual(hosts, [host])
        XCTAssertEqual(snapshots, [replacement])
    }

    func testApprovalStorePreservesDigestBinding() async {
        let id = UUID()
        let hostID = UUID()
        let snapshotDate = Date(timeIntervalSince1970: 1)
        let createdAt = Date(timeIntervalSince1970: 2)
        let approvedPlan = OperationPlan(
            id: id,
            kind: .install,
            risk: .low,
            hostID: hostID,
            agent: .codex,
            extensionID: "example",
            basedOnSnapshotAt: snapshotDate,
            changes: [PlannedChange(summary: "Install", target: "/first")],
            createdAt: createdAt
        )
        let changedPlan = OperationPlan(
            id: id,
            kind: .install,
            risk: .low,
            hostID: hostID,
            agent: .codex,
            extensionID: "example",
            basedOnSnapshotAt: snapshotDate,
            changes: [PlannedChange(summary: "Install", target: "/second")],
            createdAt: createdAt
        )
        let store = InMemoryOperationApprovalStore()
        let approval = OperationApproval(
            plan: approvedPlan,
            approvedAt: Date(timeIntervalSince1970: 3)
        )

        await store.save(approval)

        let stored = await store.approval(for: id)
        XCTAssertTrue(stored?.isValid(for: approvedPlan) == true)
        XCTAssertFalse(stored?.isValid(for: changedPlan) == true)
    }

    func testLogDescriptionRedactsPrivateContext() {
        let event = KitroomLogEvent(
            level: .error,
            category: "persistence",
            name: "load-failed",
            publicMetadata: ["attempt": "1"],
            privateContext: "token=secret-value"
        )

        XCTAssertEqual(
            event.redactedDescription,
            "load-failed attempt=1 context=<private>"
        )
        XCTAssertFalse(event.redactedDescription.contains("secret-value"))
    }

    func testUnavailableProcessExecutorFailsClosed() async {
        let executor = UnavailableProcessExecutor()

        do {
            _ = try await executor.execute(
                CommandRequest(executable: "/usr/bin/true")
            )
            XCTFail("Unavailable process execution must not succeed")
        } catch {
            XCTAssertTrue(error is HostSessionError)
        }
    }
}
