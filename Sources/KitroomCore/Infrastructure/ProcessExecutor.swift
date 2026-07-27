import Darwin
import Foundation

public protocol ProcessExecutor: Sendable {
    func execute(_ request: CommandRequest) async throws -> CommandResult
}

public struct SystemProcessExecutor: ProcessExecutor {
    public init() {}

    public func execute(_ request: CommandRequest) async throws -> CommandResult {
        try CommandRequestValidator.validate(request)

        let process = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        let standardOutput = BoundedOutputBuffer(limit: request.maximumOutputBytes)
        let standardError = BoundedOutputBuffer(limit: request.maximumOutputBytes)
        let clock = ContinuousClock()
        let startedAt = clock.now

        process.executableURL = URL(fileURLWithPath: request.executable)
        process.arguments = request.arguments
        process.environment = request.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutputPipe
        process.standardError = standardErrorPipe

        if let workingDirectory = request.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }

        standardOutputPipe.fileHandleForReading.readabilityHandler = { handle in
            standardOutput.append(handle.availableData)
        }
        standardErrorPipe.fileHandleForReading.readabilityHandler = { handle in
            standardError.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            stopReading(standardOutputPipe, standardErrorPipe)
            throw HostSessionError.transportFailure(
                "Could not launch \(request.executable): \(error.localizedDescription)"
            )
        }

        do {
            try await waitForExit(
                process,
                timeout: request.timeout,
                clock: clock
            )
        } catch {
            terminate(process)
            finishReading(
                standardOutputPipe,
                standardErrorPipe,
                standardOutput,
                standardError
            )
            throw error
        }

        finishReading(
            standardOutputPipe,
            standardErrorPipe,
            standardOutput,
            standardError
        )

        let termination: CommandTermination
        switch process.terminationReason {
        case .exit:
            termination = .exited(code: process.terminationStatus)
        case .uncaughtSignal:
            termination = .uncaughtSignal(process.terminationStatus)
        @unknown default:
            termination = .uncaughtSignal(process.terminationStatus)
        }

        return CommandResult(
            standardOutput: standardOutput.string,
            standardError: standardError.string,
            standardOutputWasTruncated: standardOutput.wasTruncated,
            standardErrorWasTruncated: standardError.wasTruncated,
            termination: termination,
            duration: startedAt.duration(to: clock.now)
        )
    }

    private func waitForExit(
        _ process: Process,
        timeout: Duration,
        clock: ContinuousClock
    ) async throws {
        let deadline = clock.now.advanced(by: timeout)

        do {
            while process.isRunning {
                try Task.checkCancellation()

                guard clock.now < deadline else {
                    throw HostSessionError.timedOut
                }

                try await Task.sleep(for: .milliseconds(20))
            }
        } catch is CancellationError {
            throw HostSessionError.cancelled
        }
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else {
            return
        }

        process.terminate()

        for _ in 0 ..< 20 where process.isRunning {
            usleep(10_000)
        }

        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }

        process.waitUntilExit()
    }

    private func stopReading(_ output: Pipe, _ error: Pipe) {
        output.fileHandleForReading.readabilityHandler = nil
        error.fileHandleForReading.readabilityHandler = nil
    }

    private func finishReading(
        _ output: Pipe,
        _ error: Pipe,
        _ outputBuffer: BoundedOutputBuffer,
        _ errorBuffer: BoundedOutputBuffer
    ) {
        stopReading(output, error)
        outputBuffer.append(output.fileHandleForReading.readDataToEndOfFile())
        errorBuffer.append(error.fileHandleForReading.readDataToEndOfFile())
    }
}

public struct UnavailableProcessExecutor: ProcessExecutor {
    public init() {}

    public func execute(_ request: CommandRequest) async throws -> CommandResult {
        throw HostSessionError.transportFailure(
            "Process execution is not implemented in this build."
        )
    }
}

private enum CommandRequestValidator {
    static func validate(_ request: CommandRequest) throws {
        guard request.executable.hasPrefix("/") else {
            throw HostSessionError.invalidRequest(
                "The executable must be an absolute path."
            )
        }

        guard !request.executable.utf8.contains(0) else {
            throw HostSessionError.invalidRequest("The executable contains a null byte.")
        }

        guard request.arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw HostSessionError.invalidRequest("An argument contains a null byte.")
        }

        guard request.timeout > .zero else {
            throw HostSessionError.invalidRequest("The timeout must be greater than zero.")
        }

        guard (1 ... 16_777_216).contains(request.maximumOutputBytes) else {
            throw HostSessionError.invalidRequest(
                "The output limit must be between 1 byte and 16 MiB."
            )
        }

        if let workingDirectory = request.workingDirectory,
           !workingDirectory.hasPrefix("/") {
            throw HostSessionError.invalidRequest(
                "The working directory must be an absolute path."
            )
        }

        for (name, value) in request.environment {
            guard EnvironmentNameValidator.isValid(name) else {
                throw HostSessionError.invalidRequest(
                    "The environment variable name \(name) is invalid."
                )
            }

            guard !value.utf8.contains(0) else {
                throw HostSessionError.invalidRequest(
                    "The environment variable \(name) contains a null byte."
                )
            }
        }
    }
}

enum EnvironmentNameValidator {
    static func isValid(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.letters
                .union(CharacterSet(charactersIn: "_"))
                .contains(first)
        else {
            return false
        }

        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_"))

        return value.unicodeScalars.dropFirst().allSatisfy(allowed.contains)
    }
}

private final class BoundedOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            truncated = true
        }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    var wasTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }
}
