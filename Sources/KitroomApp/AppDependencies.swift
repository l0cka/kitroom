import KitroomCore

struct AppDependencies: Sendable {
    let clock: any KitroomClock
    let processExecutor: any ProcessExecutor
    let hostConnectionFactory: any HostConnectionFactory
    let adapterRegistry: any AgentAdapterRegistry
    let persistence: any KitroomPersistence
    let approvalStore: any OperationApprovalStore
    let logger: any KitroomLogging

    static func live() -> Self {
        Self(
            clock: SystemKitroomClock(),
            processExecutor: UnavailableProcessExecutor(),
            hostConnectionFactory: UnavailableHostConnectionFactory(),
            adapterRegistry: DefaultAgentAdapterRegistry(),
            persistence: InMemoryKitroomPersistence(),
            approvalStore: InMemoryOperationApprovalStore(),
            logger: SystemKitroomLogger()
        )
    }
}
