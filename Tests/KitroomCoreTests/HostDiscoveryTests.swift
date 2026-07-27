import XCTest
@testable import KitroomCore

final class HostDiscoveryTests: XCTestCase {
    func testCompleteDiscoveryNormalizesPlatformIdentityPathsAndAgents() async {
        let host = ManagedHost(name: "Test Mac", connection: .local)
        let session = FixtureHostSession(
            host: host,
            results: [
                key("/usr/bin/uname", ["-s"]): success("Darwin\n"),
                key("/usr/bin/uname", ["-m"]): success("arm64\n"),
                key("/usr/bin/printenv", ["HOME"]): success("/Users/test\n"),
                key("/usr/bin/printenv", ["SHELL"]): success("/bin/zsh\n"),
                key("/bin/hostname"): success("test-mac\n"),
                key(
                    "/usr/sbin/ioreg",
                    ["-rd1", "-c", "IOPlatformExpertDevice"]
                ): success("\"IOPlatformUUID\" = \"11111111-2222-3333-4444-555555555555\"\n"),
                key("/usr/bin/which", ["codex"]): success("/opt/homebrew/bin/codex\n"),
                key("/opt/homebrew/bin/codex", ["--version"]): success("codex-cli 1.0\n"),
                key("/usr/bin/which", ["claude"]): failure(1),
                key("/usr/bin/test", ["-e", "/Users/test/.codex"]): success(),
                key("/usr/bin/test", ["-r", "/Users/test/.codex"]): success(),
                key("/usr/bin/test", ["-w", "/Users/test/.codex"]): failure(1),
                key("/usr/bin/test", ["-e", "/Users/test/.agents"]): failure(1),
                key("/usr/bin/test", ["-e", "/Users/test/.claude"]): failure(1),
                key("/usr/bin/test", ["-e", "/Users/test/.ssh"]): failure(1)
            ]
        )
        let service = HostDiscoveryService(
            connectionFactory: FixtureConnectionFactory(session: session),
            clock: FixedKitroomClock(now: Date(timeIntervalSince1970: 100))
        )

        let snapshot = await service.discover(host: host)

        XCTAssertEqual(snapshot.connectionState, .reachable)
        XCTAssertEqual(snapshot.platform?.operatingSystem, "Darwin")
        XCTAssertEqual(snapshot.platform?.architecture, "arm64")
        XCTAssertEqual(snapshot.platform?.homeDirectory, "/Users/test")
        XCTAssertEqual(snapshot.identity?.kind, .platformUUID)
        XCTAssertEqual(
            snapshot.identity?.value,
            "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertEqual(snapshot.pathAccess.first?.state, .readOnly)
        XCTAssertEqual(snapshot.pathAccess.dropFirst().map(\.state), [
            .missing, .missing, .missing
        ])
        XCTAssertEqual(snapshot.agents.first?.availability, .available)
        XCTAssertEqual(snapshot.agents.first?.version, "codex-cli 1.0")
        XCTAssertEqual(snapshot.agents.last?.availability, .notInstalled)
        XCTAssertTrue(snapshot.issues.isEmpty)
    }

    func testConnectionLossAfterReachabilityProducesPartialDiscovery() async {
        let host = ManagedHost(name: "Remote", connection: .ssh(alias: "fixture"))
        let session = LossyHostSession(host: host)
        let service = HostDiscoveryService(
            connectionFactory: FixtureConnectionFactory(session: session)
        )

        let snapshot = await service.discover(host: host)

        XCTAssertEqual(snapshot.connectionState, .partialDiscovery)
        XCTAssertEqual(snapshot.platform?.operatingSystem, "Linux")
        XCTAssertFalse(snapshot.issues.isEmpty)
    }

    func testAuthenticationFailureIsNotAnEmptySuccessfulDiscovery() async {
        let host = ManagedHost(name: "Remote", connection: .ssh(alias: "fixture"))
        let service = HostDiscoveryService(
            connectionFactory: FailingConnectionFactory(
                error: .authenticationRequired
            )
        )

        let snapshot = await service.discover(host: host)

        XCTAssertEqual(snapshot.connectionState, .authenticationRequired)
        XCTAssertNil(snapshot.platform)
        XCTAssertTrue(snapshot.agents.isEmpty)
        XCTAssertEqual(snapshot.issues.count, 1)
    }

    func testSSHConfigurationResolverReturnsOnlyBoundedSummary() async throws {
        let executor = StaticProcessExecutor(
            result: success(
                """
                host fixture
                user developer
                hostname 192.0.2.10
                port 2222
                identityfile /Users/private/.ssh/id_ed25519
                proxycommand token-secret

                """
            )
        )
        let resolver = SSHConfigurationResolver(
            executor: executor,
            environment: [:]
        )

        let summary = try await resolver.resolve(alias: "fixture")

        XCTAssertEqual(summary.alias, "fixture")
        XCTAssertEqual(summary.hostname, "192.0.2.10")
        XCTAssertEqual(summary.user, "developer")
        XCTAssertEqual(summary.port, 2222)
        XCTAssertEqual(summary.resolvedDescription, "developer@192.0.2.10:2222")
        XCTAssertFalse(String(describing: summary).contains("token-secret"))
        XCTAssertFalse(String(describing: summary).contains("identityfile"))
    }
}

private func key(_ executable: String, _ arguments: [String] = []) -> String {
    ([executable] + arguments).joined(separator: "\u{1f}")
}

private func success(_ output: String = "") -> CommandResult {
    CommandResult(standardOutput: output, standardError: "", exitCode: 0)
}

private func failure(_ code: Int32, error: String = "") -> CommandResult {
    CommandResult(standardOutput: "", standardError: error, exitCode: code)
}

private actor FixtureHostSession: HostSession {
    nonisolated let host: ManagedHost
    private let results: [String: CommandResult]

    init(host: ManagedHost, results: [String: CommandResult]) {
        self.host = host
        self.results = results
    }

    func execute(_ request: CommandRequest) throws -> CommandResult {
        guard let result = results[key(request.executable, request.arguments)] else {
            throw HostSessionError.transportFailure(
                "Missing fixture for \(request.executable)"
            )
        }
        return result
    }
}

private actor LossyHostSession: HostSession {
    nonisolated let host: ManagedHost
    private var didReturnPlatform = false

    init(host: ManagedHost) {
        self.host = host
    }

    func execute(_ request: CommandRequest) throws -> CommandResult {
        if !didReturnPlatform,
           request.executable == "/usr/bin/uname",
           request.arguments == ["-s"] {
            didReturnPlatform = true
            return success("Linux\n")
        }
        throw HostSessionError.connectionLost("fixture disconnect")
    }
}

private struct FixtureConnectionFactory<Session: HostSession>: HostConnectionFactory {
    let session: Session

    func connect(to host: ManagedHost) -> any HostSession {
        session
    }
}

private struct FailingConnectionFactory: HostConnectionFactory {
    let error: HostSessionError

    func connect(to host: ManagedHost) throws -> any HostSession {
        throw error
    }
}

private struct StaticProcessExecutor: ProcessExecutor {
    let result: CommandResult

    func execute(_ request: CommandRequest) -> CommandResult {
        result
    }
}
