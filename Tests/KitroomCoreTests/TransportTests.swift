import XCTest
@testable import KitroomCore

final class TransportTests: XCTestCase {
    func testHostAliasValidationRejectsOptionInjectionAndPathSyntax() {
        XCTAssertTrue(HostAliasValidator.isValid("build-host_01.example"))
        XCTAssertFalse(HostAliasValidator.isValid("-oProxyCommand=bad"))
        XCTAssertFalse(HostAliasValidator.isValid("team/host"))
        XCTAssertFalse(HostAliasValidator.isValid("host name"))
        XCTAssertFalse(HostAliasValidator.isValid(".."))
    }

    func testPOSIXQuotingCoversSpacesQuotesUnicodeNewlinesAndMetacharacters() throws {
        XCTAssertEqual(try RemoteCommandEncoder.quotePOSIX("two words"), "'two words'")
        XCTAssertEqual(
            try RemoteCommandEncoder.quotePOSIX("it's"),
            "'it'\"'\"'s'"
        )
        XCTAssertEqual(try RemoteCommandEncoder.quotePOSIX("مرحبا"), "'مرحبا'")
        XCTAssertEqual(try RemoteCommandEncoder.quotePOSIX("a\nb"), "'a\nb'")
        XCTAssertEqual(
            try RemoteCommandEncoder.quotePOSIX("$HOME; rm -rf /"),
            "'$HOME; rm -rf /'"
        )
    }

    func testRemoteEncoderSortsAndQuotesEnvironment() throws {
        let encoded = try RemoteCommandEncoder.encode(
            CommandRequest(
                executable: "/usr/bin/printenv",
                arguments: ["A"],
                environment: ["B": "two words", "A": "one"]
            )
        )

        XCTAssertEqual(
            encoded,
            "exec /usr/bin/env 'A=one' 'B=two words' '/usr/bin/printenv' 'A'"
        )
    }

    func testRemotePOSIXPathsAreLexicalAndRootSafe() {
        XCTAssertTrue(
            RemotePOSIXPath.isNormalizedAbsolute(
                "/private/var/lib/kitroom"
            )
        )
        XCTAssertTrue(RemotePOSIXPath.isNormalizedAbsolute("/"))
        XCTAssertFalse(
            RemotePOSIXPath.isNormalizedAbsolute("/var/../private")
        )
        XCTAssertFalse(
            RemotePOSIXPath.isNormalizedAbsolute("/var//lib")
        )
        XCTAssertEqual(
            RemotePOSIXPath.appending(
                relativePath: ".kitroom/backups/plan/config.toml",
                to: "/"
            ),
            "/.kitroom/backups/plan/config.toml"
        )
        XCTAssertEqual(
            RemotePOSIXPath.deletingLastComponent("/skill"),
            "/"
        )
        XCTAssertEqual(
            RemotePOSIXPath.lastComponent("/skills/example"),
            "example"
        )
    }

    func testSSHSessionUsesBatchModeAndPreservesHostKeyPolicy() async throws {
        let executor = RecordingProcessExecutor(
            result: CommandResult(
                standardOutput: "Darwin\n",
                standardError: "",
                exitCode: 0
            )
        )
        let host = ManagedHost(name: "Build host", connection: .ssh(alias: "build"))
        let session = try SSHHostSession(host: host, executor: executor)

        let result = try await session.execute(
            CommandRequest(
                executable: "/usr/bin/uname",
                arguments: ["-s"],
                standardInput: Data("bounded".utf8)
            )
        )
        let request = await executor.lastRequest

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(request?.executable, "/usr/bin/ssh")
        XCTAssertEqual(
            request?.arguments,
            [
                "-o", "BatchMode=yes",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "ConnectionAttempts=1",
                "-o", "ConnectTimeout=10",
                "--",
                "build",
                "exec '/usr/bin/uname' '-s'"
            ]
        )
        XCTAssertFalse(request?.arguments.contains("StrictHostKeyChecking=no") ?? true)
        XCTAssertEqual(request?.standardInput, Data("bounded".utf8))
    }

    func testSSHFailureClassification() {
        XCTAssertEqual(
            SSHHostSession.classifyFailure("Permission denied (publickey)."),
            .authenticationRequired
        )
        XCTAssertEqual(
            SSHHostSession.classifyFailure("REMOTE HOST IDENTIFICATION HAS CHANGED!"),
            .hostIdentityChanged
        )
        XCTAssertEqual(
            SSHHostSession.classifyFailure("ssh: Could not resolve hostname example"),
            .unreachable("ssh: Could not resolve hostname example")
        )
        XCTAssertEqual(
            SSHHostSession.classifyFailure("Connection reset by peer"),
            .connectionLost("Connection reset by peer")
        )
    }
}

private actor RecordingProcessExecutor: ProcessExecutor {
    private(set) var lastRequest: CommandRequest?
    private let result: CommandResult

    init(result: CommandResult) {
        self.result = result
    }

    func execute(_ request: CommandRequest) -> CommandResult {
        lastRequest = request
        return result
    }
}
