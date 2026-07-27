import CryptoKit
import Foundation

public enum NativeMCPOperationError: LocalizedError, Equatable, Sendable {
    case localHostRequired
    case unsupportedAgent
    case unsupportedScope
    case invalidName
    case invalidURL
    case invalidExecutable
    case invalidConfigurationPath
    case unsafeConfigurationFile
    case configurationTooLarge
    case noChangesRequired
    case invalidTarget
    case invalidPlan

    public var errorDescription: String? {
        switch self {
        case .localHostRequired:
            "Native MCP mutations are currently limited to the local host."
        case .unsupportedAgent:
            "The initial guarded MCP path supports Codex."
        case .unsupportedScope:
            "The initial guarded MCP path supports user scope."
        case .invalidName:
            "The MCP server name is unsafe or incomplete."
        case .invalidURL:
            "Use an HTTPS URL without credentials, query parameters, or a fragment."
        case .invalidExecutable:
            "The verified agent executable path is invalid."
        case .invalidConfigurationPath:
            "The configuration backup path is not an absolute file path."
        case .unsafeConfigurationFile:
            "The configuration target is not a regular file or is a symbolic link."
        case .configurationTooLarge:
            "The configuration file exceeds the bounded backup limit."
        case .noChangesRequired:
            "The requested MCP operation would not change the target."
        case .invalidTarget:
            "Only directly configured, user-scoped MCP servers can use this operation."
        case .invalidPlan:
            "The operation plan cannot be executed by the native MCP engine."
        }
    }
}

public actor NativeMCPOperationEngine {
    public static let maximumConfigurationBytes = 5 * 1_024 * 1_024

    private let backupRoot: URL

    public init(backupRoot: URL) {
        self.backupRoot = backupRoot.standardizedFileURL
    }

    public static func live(
        fileManager: FileManager = .default
    ) throws -> NativeMCPOperationEngine {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return NativeMCPOperationEngine(
            backupRoot: applicationSupport
                .appendingPathComponent("Kitroom", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true)
        )
    }

    public func planAddCodexHTTPServer(
        host: ManagedHost,
        hostIdentity: String,
        serverName: String,
        serverURL: String,
        executablePath: String,
        configurationPath: String,
        existingCapability: ProvidedCapability?,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) throws -> OperationPlan {
        try validateLocalCodex(
            host: host,
            executablePath: executablePath
        )
        try validateName(serverName)
        try validateHTTPSURL(serverURL)
        guard existingCapability == nil else {
            throw NativeMCPOperationError.noChangesRequired
        }
        let configurationState = try configurationState(
            path: configurationPath
        )
        let spec = NativeMCPOperationSpec(
            agent: .codex,
            action: .add,
            serverName: serverName,
            serverURL: serverURL,
            scope: .user,
            executablePath: executablePath,
            configurationState: configurationState,
            expectedBeforeConfigured: false,
            expectedAfterConfigured: true
        )
        return makePlan(
            host: host,
            hostIdentity: hostIdentity,
            spec: spec,
            basedOnSnapshotAt: basedOnSnapshotAt,
            createdAt: createdAt
        )
    }

    public func planRemoveCodexServer(
        host: ManagedHost,
        hostIdentity: String,
        capability: ProvidedCapability,
        installation: InstallationRecord,
        executablePath: String,
        configurationPath: String,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) throws -> OperationPlan {
        try validateLocalCodex(
            host: host,
            executablePath: executablePath
        )
        guard capability.agent == .codex,
              capability.kind == .mcpServer,
              capability.packageID == nil,
              installation.agent == .codex,
              installation.capabilityID == capability.id,
              installation.scope == .user,
              installation.origin == .standalone,
              installation.restriction == .agentManaged else {
            throw NativeMCPOperationError.invalidTarget
        }
        try validateName(capability.name)
        let configurationState = try configurationState(
            path: configurationPath
        )
        guard configurationState.contentDigest != nil else {
            throw NativeMCPOperationError.invalidTarget
        }
        let spec = NativeMCPOperationSpec(
            agent: .codex,
            action: .remove,
            serverName: capability.name,
            scope: .user,
            executablePath: executablePath,
            configurationState: configurationState,
            expectedBeforeConfigured: true,
            expectedAfterConfigured: false
        )
        return makePlan(
            host: host,
            hostIdentity: hostIdentity,
            spec: spec,
            basedOnSnapshotAt: basedOnSnapshotAt,
            createdAt: createdAt
        )
    }

    public func apply(
        plan: OperationPlan,
        approval: OperationApproval,
        preflight: OperationPreflight,
        session: any HostSession,
        now: Date,
        verifyExpectedState: @escaping @Sendable () async -> Bool,
        verifyRolledBackState: @escaping @Sendable () async -> Bool
    ) async -> OperationRecord {
        var record = OperationRecord(
            plan: plan,
            state: .awaitingApproval,
            updatedAt: now,
            events: [
                OperationEvent(
                    state: .planned,
                    occurredAt: plan.createdAt,
                    message: "The immutable MCP plan was created."
                ),
                OperationEvent(
                    state: .awaitingApproval,
                    occurredAt: now,
                    message: "The plan is awaiting a valid digest-bound approval."
                )
            ]
        )
        guard approval.isValid(for: plan, at: now) else {
            return record.transitioned(
                to: .invalidated,
                at: now,
                message: "Approval is missing, expired, or bound to different plan content.",
                failure: "Approval validation failed."
            )
        }
        guard preflight.inspectedAt >= plan.basedOnSnapshotAt,
              preflight.targetStateMatchesPlan else {
            return record.transitioned(
                to: .invalidated,
                at: now,
                message: "Fresh inventory no longer matches the approved MCP state.",
                failure: "MCP state changed after planning."
            )
        }
        guard session.host.id == plan.hostID,
              session.host.connection == .local,
              case let .nativeMCP(spec) = plan.execution else {
            return record.transitioned(
                to: .invalidated,
                at: now,
                message: "The plan does not match this local MCP session.",
                failure: NativeMCPOperationError.invalidPlan.localizedDescription
            )
        }

        do {
            try validate(spec)
            guard try configurationState(
                path: spec.configurationState.path
            ) == spec.configurationState else {
                return record.transitioned(
                    to: .invalidated,
                    at: now,
                    message: "The protected configuration file changed after planning.",
                    failure: "Configuration digest changed."
                )
            }
            let backup = try captureConfiguration(
                spec.configurationState,
                planID: plan.id
            )
            record = record.transitioned(
                to: .applying,
                at: now,
                message: "Approval and configuration digest matched. Running the exact native MCP command.",
                backupPath: backup.directory.path,
                rollbackState: .available
            )
            let result = try await session.execute(
                commandRequest(for: spec)
            )
            guard result.succeeded,
                  !result.standardOutputWasTruncated,
                  !result.standardErrorWasTruncated else {
                return await recover(
                    spec: spec,
                    backup: backup,
                    session: session,
                    record: record,
                    at: now,
                    reason: commandFailureDescription(result),
                    verificationFailure: false,
                    runInverse: await verifyExpectedState(),
                    verifyRolledBackState: verifyRolledBackState
                )
            }
            let verifying = record.transitioned(
                to: .verifying,
                at: now,
                message: "The native command completed. Checking fresh Codex inventory."
            )
            guard await verifyExpectedState() else {
                return await recover(
                    spec: spec,
                    backup: backup,
                    session: session,
                    record: verifying,
                    at: now,
                    reason: "Fresh inventory did not confirm the approved MCP state.",
                    verificationFailure: true,
                    runInverse: true,
                    verifyRolledBackState: verifyRolledBackState
                )
            }
            return verifying.transitioned(
                to: .completed,
                at: now,
                message: "Fresh Codex inventory matches the approved MCP state.",
                backupPath: backup.directory.path,
                rollbackState: .available
            )
        } catch {
            return record.transitioned(
                to: .failed,
                at: now,
                message: "The native MCP operation could not be applied.",
                failure: SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
    }

    private func makePlan(
        host: ManagedHost,
        hostIdentity: String,
        spec: NativeMCPOperationSpec,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) -> OperationPlan {
        let isAdd = spec.action == .add
        let command = ([spec.executablePath] + commandArguments(for: spec))
            .map(Self.displayQuoted)
            .joined(separator: " ")
        let configurationChange = PlannedChange(
            summary: spec.configurationState.contentDigest == nil
                ? "Record that Codex configuration is absent"
                : "Capture Codex configuration before the operation",
            target: spec.configurationState.path,
            commandPreview: spec.configurationState.contentDigest == nil
                ? "Verify absence"
                : "Copy to Kitroom's private backup directory",
            rollback: spec.configurationState.contentDigest == nil
                ? "Remove only the exact file if this operation creates it."
                : "Atomically restore the captured file."
        )
        let nativeChange = PlannedChange(
            summary: "\(isAdd ? "Add" : "Remove") Codex MCP server \(spec.serverName)",
            target: "Codex user MCP configuration",
            commandPreview: command,
            rollback: isAdd
                ? "Run the exact native remove command and restore captured configuration."
                : "Atomically restore captured configuration, then verify the server is reported again."
        )
        return OperationPlan(
            kind: isAdd ? .install : .uninstall,
            risk: .medium,
            hostID: host.id,
            hostIdentity: hostIdentity,
            agent: .codex,
            extensionID: "mcp:\(spec.serverName)",
            scope: .user,
            sourceReference: spec.serverURL,
            contentDigest: spec.configurationState.contentDigest,
            basedOnSnapshotAt: basedOnSnapshotAt,
            changes: [configurationChange, nativeChange],
            warnings: [
                isAdd
                    ? "An MCP server can receive prompts and tool input when Codex uses it."
                    : "Removing this server makes its tools unavailable to future Codex sessions.",
                "Kitroom will use Codex's native MCP command and will not write configuration directly."
            ],
            verificationSteps: [
                "Run a fresh Codex inventory scan.",
                "Confirm \(spec.serverName) is \(isAdd ? "configured" : "absent")."
            ],
            execution: .nativeMCP(spec),
            createdAt: createdAt
        )
    }

    private func recover(
        spec: NativeMCPOperationSpec,
        backup: ConfigurationBackupBundle,
        session: any HostSession,
        record: OperationRecord,
        at date: Date,
        reason: String,
        verificationFailure: Bool,
        runInverse: Bool,
        verifyRolledBackState: @escaping @Sendable () async -> Bool
    ) async -> OperationRecord {
        var inverseFailure: String?
        if runInverse, let inverseAction = spec.action.inverse {
            let inverse = NativeMCPOperationSpec(
                agent: spec.agent,
                action: inverseAction,
                serverName: spec.serverName,
                scope: spec.scope,
                executablePath: spec.executablePath,
                configurationState: spec.configurationState,
                expectedBeforeConfigured: spec.expectedAfterConfigured,
                expectedAfterConfigured: spec.expectedBeforeConfigured
            )
            do {
                let inverseResult = try await session.execute(
                    commandRequest(for: inverse)
                )
                if !inverseResult.succeeded {
                    inverseFailure = commandFailureDescription(inverseResult)
                }
            } catch {
                inverseFailure = SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            }
        }
        do {
            try restoreConfiguration(backup)
        } catch {
            return record.transitioned(
                to: verificationFailure ? .verificationFailed : .failed,
                at: date,
                message: "\(reason) Configuration restore failed.",
                rollbackState: .failed,
                failure: SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
        if await verifyRolledBackState() {
            return record.transitioned(
                to: verificationFailure ? .verificationFailed : .rolledBack,
                at: date,
                message: "\(reason) Fresh inventory confirms the original MCP state was restored.",
                rollbackState: .succeeded,
                failure: reason
            )
        }
        let extra = inverseFailure.map { " Inverse command: \($0)" } ?? ""
        return record.transitioned(
            to: verificationFailure ? .verificationFailed : .failed,
            at: date,
            message: "\(reason) Rollback could not be verified.\(extra)",
            rollbackState: .failed,
            failure: "\(reason)\(extra)"
        )
    }

    private func validate(_ spec: NativeMCPOperationSpec) throws {
        guard spec.agent == .codex else {
            throw NativeMCPOperationError.unsupportedAgent
        }
        guard spec.scope == .user else {
            throw NativeMCPOperationError.unsupportedScope
        }
        try validateName(spec.serverName)
        try validateExecutable(spec.executablePath)
        if spec.action == .add {
            guard let serverURL = spec.serverURL,
                  !spec.expectedBeforeConfigured,
                  spec.expectedAfterConfigured else {
                throw NativeMCPOperationError.invalidPlan
            }
            try validateHTTPSURL(serverURL)
        } else {
            guard spec.serverURL == nil,
                  spec.expectedBeforeConfigured,
                  !spec.expectedAfterConfigured else {
                throw NativeMCPOperationError.invalidPlan
            }
        }
    }

    private func validateLocalCodex(
        host: ManagedHost,
        executablePath: String
    ) throws {
        guard host.connection == .local else {
            throw NativeMCPOperationError.localHostRequired
        }
        try validateExecutable(executablePath)
    }

    private func validateName(_ name: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard !name.isEmpty,
              name.count <= 128,
              !name.hasPrefix("-"),
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw NativeMCPOperationError.invalidName
        }
    }

    private func validateHTTPSURL(_ value: String) throws {
        guard value.count <= 2_048,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.url?.absoluteString == value else {
            throw NativeMCPOperationError.invalidURL
        }
    }

    private func validateExecutable(_ path: String) throws {
        guard path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw NativeMCPOperationError.invalidExecutable
        }
    }

    private func configurationState(
        path: String
    ) throws -> NativePluginConfigurationState {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.path == path else {
            throw NativeMCPOperationError.invalidConfigurationPath
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return NativePluginConfigurationState(
                path: path,
                contentDigest: nil
            )
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw NativeMCPOperationError.unsafeConfigurationFile
        }
        guard (values.fileSize ?? 0) <= Self.maximumConfigurationBytes else {
            throw NativeMCPOperationError.configurationTooLarge
        }
        return NativePluginConfigurationState(
            path: path,
            contentDigest: digest(try Data(contentsOf: url))
        )
    }

    private func captureConfiguration(
        _ state: NativePluginConfigurationState,
        planID: UUID
    ) throws -> ConfigurationBackupBundle {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: backupRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: backupRoot.path
        )
        let directory = backupRoot.appendingPathComponent(
            planID.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        guard state.contentDigest != nil else {
            return ConfigurationBackupBundle(
                directory: directory,
                original: URL(fileURLWithPath: state.path),
                backup: nil,
                wasPresent: false
            )
        }
        let source = URL(fileURLWithPath: state.path)
        let backup = directory.appendingPathComponent(
            source.lastPathComponent
        )
        try fileManager.copyItem(at: source, to: backup)
        guard digest(try Data(contentsOf: backup))
                == state.contentDigest else {
            throw NativeMCPOperationError.invalidPlan
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backup.path
        )
        return ConfigurationBackupBundle(
            directory: directory,
            original: source,
            backup: backup,
            wasPresent: true
        )
    }

    private func restoreConfiguration(
        _ backup: ConfigurationBackupBundle
    ) throws {
        let fileManager = FileManager.default
        guard backup.wasPresent else {
            guard fileManager.fileExists(
                atPath: backup.original.path
            ) else {
                return
            }
            let values = try backup.original.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw NativeMCPOperationError.unsafeConfigurationFile
            }
            try fileManager.removeItem(at: backup.original)
            return
        }
        guard let capturedFile = backup.backup else {
            throw NativeMCPOperationError.invalidPlan
        }
        let temporary = backup.original.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(backup.original.lastPathComponent).kitroom-restore-\(UUID().uuidString)"
            )
        try fileManager.copyItem(at: capturedFile, to: temporary)
        if fileManager.fileExists(atPath: backup.original.path) {
            _ = try fileManager.replaceItemAt(
                backup.original,
                withItemAt: temporary
            )
        } else {
            try fileManager.moveItem(
                at: temporary,
                to: backup.original
            )
        }
    }

    private func commandRequest(
        for spec: NativeMCPOperationSpec
    ) -> CommandRequest {
        CommandRequest(
            executable: spec.executablePath,
            arguments: commandArguments(for: spec),
            environment: ["LC_ALL": "C"],
            timeout: .seconds(60),
            maximumOutputBytes: 1_048_576
        )
    }

    private func commandArguments(
        for spec: NativeMCPOperationSpec
    ) -> [String] {
        switch spec.action {
        case .add:
            [
                "mcp",
                "add",
                spec.serverName,
                "--url",
                spec.serverURL ?? ""
            ]
        case .remove:
            ["mcp", "remove", spec.serverName]
        }
    }

    private func commandFailureDescription(
        _ result: CommandResult
    ) -> String {
        let detail = result.standardError
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        return SensitiveValueRedactor.redact(
            "Native MCP command failed\(suffix)"
        )
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func displayQuoted(_ value: String) -> String {
        guard value.rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "'\"\\$")
            )
        ) != nil else {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private struct ConfigurationBackupBundle {
    let directory: URL
    let original: URL
    let backup: URL?
    let wasPresent: Bool
}
