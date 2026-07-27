import Foundation
import XCTest
@testable import KitroomCore

final class PackageSourceTrustTests: XCTestCase {
    func testCodeIntroductionRequiresExactApprovalAndDigestEvidence() throws {
        let fixture = makeFixture()
        let approval = ApprovedPackageSource(
            agent: .claude,
            reference: try PackageSourceTrustPolicy.validatedReference(
                for: fixture.source
            ),
            approvedAt: fixture.now
        )

        XCTAssertFalse(
            PackageSourceTrustPolicy.allowsCodeIntroduction(
                package: fixture.package,
                state: fixture.state,
                source: fixture.source,
                approvals: []
            )
        )
        XCTAssertTrue(
            PackageSourceTrustPolicy.allowsCodeIntroduction(
                package: fixture.package,
                state: fixture.state,
                source: fixture.source,
                approvals: [approval.id]
            )
        )
        let noDigest = PackageRecord(
            id: fixture.package.id,
            agent: .claude,
            name: fixture.package.name,
            sourceID: fixture.source.id
        )
        XCTAssertFalse(
            PackageSourceTrustPolicy.allowsCodeIntroduction(
                package: noDigest,
                state: fixture.state,
                source: fixture.source,
                approvals: [approval.id]
            )
        )
    }

    func testTrustStorePersistsExactAllowanceWithPrivatePermissions() async throws {
        let fixture = makeFixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kitroom-source-trust-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let file = root.appendingPathComponent("allowlist.json")
        let store = PackageSourceTrustStore(fileURL: file)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }

        let approved = try await store.approve(
            source: fixture.source,
            at: fixture.now
        )
        XCTAssertEqual(approved.count, 1)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, approved)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: file.path
            )[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)

        let revoked = try await store.revoke(source: fixture.source)
        XCTAssertTrue(revoked.isEmpty)
        let afterRevocation = try await store.load()
        XCTAssertTrue(afterRevocation.isEmpty)
    }

    func testSourceReferenceControlCharactersAreRejected() {
        let source = CatalogSource(
            id: "source",
            agent: .codex,
            name: "unsafe",
            kind: .marketplace,
            reference: "https://example.invalid/repo\ninjected",
            capturedAt: Date()
        )
        XCTAssertThrowsError(
            try PackageSourceTrustPolicy.validatedReference(for: source)
        ) { error in
            XCTAssertEqual(
                error as? PackageSourceTrustError,
                .invalidReference
            )
        }
    }

    private func makeFixture() -> SourceTrustFixture {
        let now = Date(timeIntervalSince1970: 60_000)
        let source = CatalogSource(
            id: "claude:source:team",
            agent: .claude,
            name: "team",
            kind: .marketplace,
            reference: "https://example.invalid/team.git",
            capturedAt: now
        )
        let package = PackageRecord(
            id: "claude:package:team:formatter",
            agent: .claude,
            name: "formatter",
            sourceID: source.id,
            version: "2.0.0",
            manifestDigest: "declared-package-digest"
        )
        let state = CataloguePackageState(
            id: "state",
            hostID: UUID(),
            agent: .claude,
            packageID: package.id,
            availableVersion: "2.0.0",
            updateStatus: .notInstalled,
            restriction: .agentManaged,
            compatibility: .compatible,
            integrity: .digestDeclared
        )
        return SourceTrustFixture(
            now: now,
            source: source,
            package: package,
            state: state
        )
    }
}

private struct SourceTrustFixture {
    let now: Date
    let source: CatalogSource
    let package: PackageRecord
    let state: CataloguePackageState
}
