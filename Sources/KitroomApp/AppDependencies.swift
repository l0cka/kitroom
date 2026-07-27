import KitroomCore

struct AppDependencies: Sendable {
    let clock: any KitroomClock
    let processExecutor: any ProcessExecutor
    let hostConnectionFactory: any HostConnectionFactory
    let hostDiscovery: any HostDiscovering
    let sshConfigurationResolver: any SSHConfigurationResolving
    let adapterRegistry: any AgentAdapterRegistry
    let persistence: any KitroomPersistence
    let persistenceIssue: String?
    let approvalStore: any OperationApprovalStore
    let logger: any KitroomLogging

    static func live() -> Self {
        let processExecutor = SystemProcessExecutor()
        let hostConnectionFactory = DefaultHostConnectionFactory(
            executor: processExecutor
        )
        let persistence: any KitroomPersistence
        let persistenceIssue: String?
        do {
            persistence = try SwiftDataKitroomPersistence.live()
            persistenceIssue = nil
        } catch {
            persistence = InMemoryKitroomPersistence()
            persistenceIssue = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
        }

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
            persistence: persistence,
            persistenceIssue: persistenceIssue,
            approvalStore: InMemoryOperationApprovalStore(),
            logger: SystemKitroomLogger()
        )
    }
}
