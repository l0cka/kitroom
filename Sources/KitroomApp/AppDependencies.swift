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
    let localSkillOperations: LocalSkillOperationEngine?
    let nativePluginOperations: NativePluginOperationEngine?
    let nativeMCPOperations: NativeMCPOperationEngine?
    let remoteSkillOperations: RemoteSkillOperationEngine?
    let remotePluginOperations: RemotePluginOperationEngine?
    let remoteMCPOperations: RemoteMCPOperationEngine?
    let backupRetention: BackupRetentionService?
    let packageSourceTrust: PackageSourceTrustStore?
    let operationIssue: String?
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
        let localSkillOperations: LocalSkillOperationEngine?
        let nativePluginOperations: NativePluginOperationEngine?
        let nativeMCPOperations: NativeMCPOperationEngine?
        let remoteSkillOperations: RemoteSkillOperationEngine? =
            RemoteSkillOperationEngine()
        let remotePluginOperations: RemotePluginOperationEngine? =
            RemotePluginOperationEngine()
        let remoteMCPOperations: RemoteMCPOperationEngine? =
            RemoteMCPOperationEngine()
        let backupRetention: BackupRetentionService?
        let packageSourceTrust: PackageSourceTrustStore?
        var operationIssues: [String] = []
        do {
            localSkillOperations = try LocalSkillOperationEngine.live()
        } catch {
            localSkillOperations = nil
            operationIssues.append(
                SensitiveValueRedactor.redact(error.localizedDescription)
            )
        }
        do {
            nativePluginOperations = try NativePluginOperationEngine.live()
        } catch {
            nativePluginOperations = nil
            operationIssues.append(
                SensitiveValueRedactor.redact(error.localizedDescription)
            )
        }
        do {
            nativeMCPOperations = try NativeMCPOperationEngine.live()
        } catch {
            nativeMCPOperations = nil
            operationIssues.append(
                SensitiveValueRedactor.redact(error.localizedDescription)
            )
        }
        do {
            backupRetention = try BackupRetentionService.live()
        } catch {
            backupRetention = nil
            operationIssues.append(
                SensitiveValueRedactor.redact(error.localizedDescription)
            )
        }
        do {
            packageSourceTrust = try PackageSourceTrustStore.live()
        } catch {
            packageSourceTrust = nil
            operationIssues.append(
                SensitiveValueRedactor.redact(error.localizedDescription)
            )
        }
        let operationIssue = operationIssues.isEmpty
            ? nil
            : operationIssues.joined(separator: " ")

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
            localSkillOperations: localSkillOperations,
            nativePluginOperations: nativePluginOperations,
            nativeMCPOperations: nativeMCPOperations,
            remoteSkillOperations: remoteSkillOperations,
            remotePluginOperations: remotePluginOperations,
            remoteMCPOperations: remoteMCPOperations,
            backupRetention: backupRetention,
            packageSourceTrust: packageSourceTrust,
            operationIssue: operationIssue,
            logger: SystemKitroomLogger()
        )
    }
}
