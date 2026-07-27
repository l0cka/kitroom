import KitroomCore

struct AppDependencies: Sendable {
    let clock: any KitroomClock
    let processExecutor: any ProcessExecutor
    let hostConnectionFactory: any HostConnectionFactory
    let hostDiscovery: any HostDiscovering
    let sshConfigurationResolver: any SSHConfigurationResolving
    let adapterRegistry: any AgentAdapterRegistry
    let persistence: any KitroomPersistence
    let approvalStore: any OperationApprovalStore
    let logger: any KitroomLogging

    static func live() -> Self {
        let processExecutor = SystemProcessExecutor()
        let hostConnectionFactory = DefaultHostConnectionFactory(
            executor: processExecutor
        )

        return Self(
            clock: SystemKitroomClock(),
            processExecutor: processExecutor,
            hostConnectionFactory: hostConnectionFactory,
            hostDiscovery: HostDiscoveryService(
                connectionFactory: hostConnectionFactory
            ),
            sshConfigurationResolver: SSHConfigurationResolver(
                executor: processExecutor
            ),
            adapterRegistry: DefaultAgentAdapterRegistry(),
            persistence: InMemoryKitroomPersistence(),
            approvalStore: InMemoryOperationApprovalStore(),
            logger: SystemKitroomLogger()
        )
    }
}
