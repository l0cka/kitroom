public protocol ProcessExecutor: Sendable {
    func execute(_ request: CommandRequest) async throws -> CommandResult
}

public struct UnavailableProcessExecutor: ProcessExecutor {
    public init() {}

    public func execute(_ request: CommandRequest) async throws -> CommandResult {
        throw HostSessionError.transportFailure(
            "Process execution is not implemented in this build."
        )
    }
}
