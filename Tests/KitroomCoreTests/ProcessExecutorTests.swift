import XCTest
@testable import KitroomCore

final class ProcessExecutorTests: XCTestCase {
    private let executor = SystemProcessExecutor()

    func testExecutesWithoutImplicitShell() async throws {
        let result = try await executor.execute(
            CommandRequest(
                executable: "/bin/echo",
                arguments: ["hello; printf unsafe"]
            )
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, "hello; printf unsafe\n")
    }

    func testUsesOnlyExplicitEnvironment() async throws {
        let visible = try await executor.execute(
            CommandRequest(
                executable: "/usr/bin/printenv",
                arguments: ["KITROOM_VISIBLE"],
                environment: ["KITROOM_VISIBLE": "yes"]
            )
        )
        let inheritedHome = try await executor.execute(
            CommandRequest(
                executable: "/usr/bin/printenv",
                arguments: ["HOME"]
            )
        )

        XCTAssertEqual(visible.standardOutput, "yes\n")
        XCTAssertTrue(visible.succeeded)
        XCTAssertEqual(inheritedHome.exitCode, 1)
        XCTAssertEqual(inheritedHome.standardOutput, "")
    }

    func testBoundsLargeOutputAndRecordsTruncation() async throws {
        let result = try await executor.execute(
            CommandRequest(
                executable: "/bin/echo",
                arguments: [String(repeating: "x", count: 200)],
                maximumOutputBytes: 32
            )
        )

        XCTAssertEqual(result.standardOutput.utf8.count, 32)
        XCTAssertTrue(result.standardOutputWasTruncated)
        XCTAssertFalse(result.standardErrorWasTruncated)
    }

    func testReportsNonZeroExit() async throws {
        let result = try await executor.execute(
            CommandRequest(executable: "/usr/bin/false")
        )

        XCTAssertEqual(result.termination, .exited(code: 1))
        XCTAssertFalse(result.succeeded)
    }

    func testReportsUncaughtSignal() async throws {
        let result = try await executor.execute(
            CommandRequest(
                executable: "/bin/sh",
                arguments: ["-c", "kill -TERM $$"]
            )
        )

        XCTAssertEqual(result.termination, .uncaughtSignal(15))
        XCTAssertFalse(result.succeeded)
    }

    func testTimesOutAndStopsChild() async {
        do {
            _ = try await executor.execute(
                CommandRequest(
                    executable: "/bin/sleep",
                    arguments: ["2"],
                    timeout: .milliseconds(50)
                )
            )
            XCTFail("Expected the command to time out")
        } catch let error as HostSessionError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellationStopsChild() async throws {
        let executor = SystemProcessExecutor()
        let task = Task {
            try await executor.execute(
                CommandRequest(
                    executable: "/bin/sleep",
                    arguments: ["2"]
                )
            )
        }

        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected the command to be cancelled")
        } catch let error as HostSessionError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testRejectsRelativeExecutable() async {
        do {
            _ = try await executor.execute(CommandRequest(executable: "echo"))
            XCTFail("Expected validation to fail")
        } catch let error as HostSessionError {
            XCTAssertEqual(
                error,
                .invalidRequest("The executable must be an absolute path.")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
