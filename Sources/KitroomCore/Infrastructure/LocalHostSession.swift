public struct LocalHostSession: HostSession {
    public let host: ManagedHost
    private let executor: any ProcessExecutor

    public init(
        host: ManagedHost,
        executor: any ProcessExecutor
    ) throws {
        guard host.connection == .local else {
            throw HostSessionError.invalidRequest(
                "A local session requires a local host."
            )
        }

        self.host = host
        self.executor = executor
    }

    public func execute(_ request: CommandRequest) async throws -> CommandResult {
        try await executor.execute(request)
    }
}
