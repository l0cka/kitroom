import CryptoKit
import Foundation

public enum NativePluginOperationError: LocalizedError, Equatable, Sendable {
    case localHostRequired
    case unsupportedAgent
    case unsupportedAction
    case unsupportedScope
    case invalidSource
    case invalidSelector
    case invalidExecutable
    case invalidConfigurationPath
    case unsafeConfigurationFile
    case configurationTooLarge
    case noChangesRequired
    case invalidPlan

    public var errorDescription: String? {
        switch self {
        case .localHostRequired:
            "Native plugin mutations are currently limited to the local host."
        case .unsupportedAgent:
            "This agent does not support the requested guarded plugin operation."
        case .unsupportedAction:
            "This plugin action is not supported by the guarded engine."
        case .unsupportedScope:
            "The initial guarded plugin path supports only user scope."
        case .invalidSource:
            "The package is not bound to the selected native marketplace source."
        case .invalidSelector:
            "The plugin and marketplace identifier is unsafe or incomplete."
        case .invalidExecutable:
            "The verified agent executable path is invalid."
        case .invalidConfigurationPath:
            "A configuration backup path is not an absolute file path."
        case .unsafeConfigurationFile:
            "A configuration file is not a regular file or is a symbolic link."
        case .configurationTooLarge:
            "A configuration file exceeds the bounded backup limit."
        case .noChangesRequired:
            "The requested plugin operation would not change the target."
        case .invalidPlan:
            "The operation plan cannot be executed by the native plugin engine."
        }
    }
}

public actor NativePluginOperationEngine {
    public static let maximumConfigurationBytes = 5 * 1_024 * 1_024

    private let backupRoot: URL

    public init(backupRoot: URL) {
        self.backupRoot = VerifiedDirectoryTree.normalizedURL(backupRoot)
    }

    public static func live(
        fileManager: FileManager = .default
    ) throws -> NativePluginOperationEngine {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return NativePluginOperationEngine(
            backupRoot: applicationSupport
                .appendingPathComponent("Kitroom", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true)
        )
    }

    public func planClaudeToggle(
        host: ManagedHost,
        hostIdentity: String,
        action: NativePluginAction,
        package: PackageRecord,
        source: CatalogSource,
        installation: InstallationRecord,
        executablePath: String,
        configurationPaths: [String],
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) throws -> OperationPlan {
        try planPluginAction(
            host: host,
            hostIdentity: hostIdentity,
            agent: .claude,
            action: action,
            package: package,
            source: source,
            installation: installation,
            executablePath: executablePath,
            configurationPaths: configurationPaths,
            basedOnSnapshotAt: basedOnSnapshotAt,
            createdAt: createdAt
        )
    }

    public func planPluginAction(
        host: ManagedHost,
        hostIdentity: String,
        agent: AgentKind,
        action: NativePluginAction,
        package: PackageRecord,
        source: CatalogSource,
        installation: InstallationRecord?,
        executablePath: String,
        configurationPaths: [String],
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) throws -> OperationPlan {
        guard host.connection == .local else {
            throw NativePluginOperationError.localHostRequired
        }
        guard package.agent == agent,
              source.agent == agent,
              installation?.agent == agent || installation == nil else {
            throw NativePluginOperationError.unsupportedAgent
        }
        guard source.kind == .marketplace,
              package.sourceID == source.id else {
            throw NativePluginOperationError.invalidSource
        }
        guard installation?.scope == .user || installation == nil else {
            throw NativePluginOperationError.unsupportedScope
        }
        if let installation {
            guard installation.hostID == host.id,
                  installation.origin == .marketplace,
                  installation.restriction == .agentManaged else {
                throw NativePluginOperationError.unsupportedAction
            }
        }
        try validate(action: action, for: agent)

        let expectedBeforeInstalled: Bool
        let expectedAfterInstalled: Bool
        let expectedBeforeState: EffectiveState?
        let expectedAfterState: EffectiveState?
        let expectedBeforeVersion: String?
        let expectedAfterVersion: String?
        let kind: OperationKind
        switch action {
        case .install:
            guard installation == nil else {
                throw NativePluginOperationError.noChangesRequired
            }
            expectedBeforeInstalled = false
            expectedAfterInstalled = true
            expectedBeforeState = nil
            expectedAfterState = .enabled
            expectedBeforeVersion = nil
            expectedAfterVersion = package.version
            kind = .install
        case .update:
            guard let installation else {
                throw NativePluginOperationError.unsupportedAction
            }
            guard let availableVersion = package.version else {
                throw NativePluginOperationError.unsupportedAction
            }
            guard installation.updateStatus == .updateAvailable
                    || (
                        installation.installedVersion != nil
                            && installation.installedVersion != availableVersion
                    ) else {
                throw NativePluginOperationError.noChangesRequired
            }
            expectedBeforeInstalled = true
            expectedAfterInstalled = true
            expectedBeforeState = installation.state
            expectedAfterState = installation.state
            expectedBeforeVersion = installation.installedVersion
            expectedAfterVersion = availableVersion
            kind = .update
        case .enable:
            guard let installation else {
                throw NativePluginOperationError.unsupportedAction
            }
            guard installation.state == .disabled else {
                if installation.state == .enabled {
                    throw NativePluginOperationError.noChangesRequired
                }
                throw NativePluginOperationError.unsupportedAction
            }
            expectedBeforeInstalled = true
            expectedAfterInstalled = true
            expectedBeforeState = .disabled
            expectedAfterState = .enabled
            expectedBeforeVersion = installation.installedVersion
            expectedAfterVersion = installation.installedVersion
            kind = .enable
        case .disable:
            guard let installation else {
                throw NativePluginOperationError.unsupportedAction
            }
            guard installation.state == .enabled else {
                if installation.state == .disabled {
                    throw NativePluginOperationError.noChangesRequired
                }
                throw NativePluginOperationError.unsupportedAction
            }
            expectedBeforeInstalled = true
            expectedAfterInstalled = true
            expectedBeforeState = .enabled
            expectedAfterState = .disabled
            expectedBeforeVersion = installation.installedVersion
            expectedAfterVersion = installation.installedVersion
            kind = .disable
        case .uninstall:
            guard let installation else {
                throw NativePluginOperationError.noChangesRequired
            }
            expectedBeforeInstalled = true
            expectedAfterInstalled = false
            expectedBeforeState = installation.state
            expectedAfterState = nil
            expectedBeforeVersion = installation.installedVersion
            expectedAfterVersion = nil
            kind = .uninstall
        }

        let selector = "\(package.name)@\(source.name)"
        try validateSelector(selector)
        try validateExecutable(executablePath)
        let configurationStates = try configurationPaths.map {
            try configurationState(path: $0)
        }
        let spec = NativePluginOperationSpec(
            agent: agent,
            action: action,
            selector: selector,
            scope: .user,
            executablePath: executablePath,
            configurationStates: configurationStates,
            expectedBeforeInstalled: expectedBeforeInstalled,
            expectedAfterInstalled: expectedAfterInstalled,
            expectedBeforeState: expectedBeforeState,
            expectedAfterState: expectedAfterState,
            expectedBeforeVersion: expectedBeforeVersion,
            expectedAfterVersion: expectedAfterVersion,
            requiresCataloguePreflight: action == .install
                || action == .update
        )
        let command = commandArguments(for: spec)
        let actionName = action.rawValue.capitalized
        var warnings = [
            "Plugin code and hooks can affect future agent sessions.",
            "Kitroom will use \(agent.displayName)'s native plugin command and will not edit its plugin cache."
        ]
        if action == .update {
            warnings.append(
                "The native CLI does not provide a version-pinned inverse update. Kitroom can restore configuration, but automatic code rollback may be incomplete."
            )
        }
        let risk: OperationRisk
        switch action {
        case .install, .enable:
            risk = .low
        case .disable, .uninstall:
            risk = .medium
        case .update:
            risk = .high
        }

        let configurationChanges = configurationStates.map { state in
            PlannedChange(
                summary: state.contentDigest == nil
                    ? "Record that configuration is absent before the operation"
                    : "Capture configuration before the operation",
                target: state.path,
                commandPreview: state.contentDigest == nil
                    ? "Verify absence"
                    : "Copy to Kitroom's private backup directory",
                rollback: state.contentDigest == nil
                    ? "Remove only the exact file if this operation creates it."
                    : "Atomically restore the captured file."
            )
        }

        return OperationPlan(
            kind: kind,
            risk: risk,
            hostID: host.id,
            hostIdentity: hostIdentity,
            agent: agent,
            extensionID: selector,
            scope: .user,
            sourceReference: source.reference ?? source.name,
            version: package.version,
            revision: source.revision,
            contentDigest: package.manifestDigest,
            basedOnSnapshotAt: basedOnSnapshotAt,
            changes: configurationChanges + [
                PlannedChange(
                    summary: "\(actionName) \(agent.displayName) plugin \(selector)",
                    target: "\(agent.displayName) user plugin state",
                    commandPreview: ([executablePath] + command)
                        .map(Self.displayQuoted)
                        .joined(separator: " "),
                    rollback: rollbackDescription(for: action, agent: agent)
                )
            ],
            warnings: warnings,
            verificationSteps: [
                "Run a fresh \(agent.displayName) inventory scan.",
                verificationDescription(
                    selector: selector,
                    installed: expectedAfterInstalled,
                    state: expectedAfterState,
                    version: expectedAfterVersion
                )
            ],
            execution: .nativePlugin(spec),
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
                    message: "The immutable native plugin plan was created."
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
                message: "Fresh inventory no longer matches the approved plugin state.",
                failure: "Plugin state changed after planning."
            )
        }
        guard session.host.id == plan.hostID,
              session.host.connection == .local,
              case let .nativePlugin(spec) = plan.execution else {
            return record.transitioned(
                to: .invalidated,
                at: now,
                message: "The plan does not match this local plugin session.",
                failure: NativePluginOperationError.invalidPlan.localizedDescription
            )
        }

        do {
            try validate(spec)
            guard try configurationStillMatches(spec.configurationStates) else {
                return record.transitioned(
                    to: .invalidated,
                    at: now,
                    message: "A protected configuration file changed after planning.",
                    failure: "Configuration digest changed."
                )
            }
            let backup = try captureConfiguration(
                spec.configurationStates,
                planID: plan.id
            )
            record = record.transitioned(
                to: .applying,
                at: now,
                message: "Approval and configuration digests matched. Running the exact native command.",
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
                message: "The native command completed. Checking fresh Claude Code inventory."
            )
            guard await verifyExpectedState() else {
                return await recover(
                    spec: spec,
                    backup: backup,
                    session: session,
                    record: verifying,
                    at: now,
                    reason: "Fresh inventory did not confirm the approved plugin state.",
                    verificationFailure: true,
                    runInverse: true,
                    verifyRolledBackState: verifyRolledBackState
                )
            }
            return verifying.transitioned(
                to: .completed,
                at: now,
                message: "Fresh Claude Code inventory matches the approved plugin state.",
                backupPath: backup.directory.path,
                rollbackState: .available
            )
        } catch {
            return record.transitioned(
                to: .failed,
                at: now,
                message: "The native plugin operation could not be applied.",
                failure: SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
    }

    private func recover(
        spec: NativePluginOperationSpec,
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
            do {
                let inverse = NativePluginOperationSpec(
                    agent: spec.agent,
                    action: inverseAction,
                    selector: spec.selector,
                    scope: spec.scope,
                    executablePath: spec.executablePath,
                    configurationStates: spec.configurationStates,
                    expectedBeforeInstalled: spec.expectedAfterInstalled,
                    expectedAfterInstalled: spec.expectedBeforeInstalled,
                    expectedBeforeState: spec.expectedAfterState,
                    expectedAfterState: spec.expectedBeforeState,
                    expectedBeforeVersion: spec.expectedAfterVersion,
                    expectedAfterVersion: spec.expectedBeforeVersion,
                    requiresCataloguePreflight: false
                )
                let result = try await session.execute(
                    commandRequest(for: inverse)
                )
                if !result.succeeded {
                    inverseFailure = commandFailureDescription(result)
                }
            } catch {
                inverseFailure = SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            }
        }

        do {
            try restoreConfiguration(backup.entries)
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
        let rollbackVerified = await verifyRolledBackState()
        if rollbackVerified {
            return record.transitioned(
                to: verificationFailure ? .verificationFailed : .rolledBack,
                at: date,
                message: "\(reason) Fresh inventory confirms the original plugin state was restored.",
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

    private func validate(_ spec: NativePluginOperationSpec) throws {
        try validate(action: spec.action, for: spec.agent)
        try validateSelector(spec.selector)
        try validateExecutable(spec.executablePath)
        guard spec.scope == .user else {
            throw NativePluginOperationError.unsupportedScope
        }
        switch spec.action {
        case .install:
            guard !spec.expectedBeforeInstalled,
                  spec.expectedAfterInstalled else {
                throw NativePluginOperationError.invalidPlan
            }
        case .uninstall:
            guard spec.expectedBeforeInstalled,
                  !spec.expectedAfterInstalled else {
                throw NativePluginOperationError.invalidPlan
            }
        case .update:
            guard spec.expectedBeforeInstalled,
                  spec.expectedAfterInstalled,
                  spec.expectedBeforeVersion != spec.expectedAfterVersion else {
                throw NativePluginOperationError.invalidPlan
            }
        case .enable, .disable:
            guard spec.expectedBeforeInstalled,
                  spec.expectedAfterInstalled,
                  let before = spec.expectedBeforeState,
                  let after = spec.expectedAfterState,
                  Set<EffectiveState>([before, after])
                    == Set<EffectiveState>([.enabled, .disabled]) else {
                throw NativePluginOperationError.invalidPlan
            }
        }
    }

    private func validate(
        action: NativePluginAction,
        for agent: AgentKind
    ) throws {
        switch (agent, action) {
        case (.claude, _):
            return
        case (.codex, .install), (.codex, .uninstall):
            return
        case (.codex, .update),
             (.codex, .enable),
             (.codex, .disable):
            throw NativePluginOperationError.unsupportedAction
        }
    }

    private func rollbackDescription(
        for action: NativePluginAction,
        agent: AgentKind
    ) -> String {
        switch action {
        case .update:
            "Restore captured configuration. \(agent.displayName) does not expose a version-pinned inverse update, so code rollback may require a new reviewed plan."
        default:
            "Run the inverse native \(agent.displayName) operation and restore captured configuration if needed."
        }
    }

    private func verificationDescription(
        selector: String,
        installed: Bool,
        state: EffectiveState?,
        version: String?
    ) -> String {
        guard installed else {
            return "Confirm \(selector) is absent."
        }
        var details = ["Confirm \(selector) is installed"]
        if let state {
            details.append("with state \(state.rawValue)")
        }
        if let version {
            details.append("at version \(version)")
        }
        return details.joined(separator: " ") + "."
    }

    private func validateSelector(_ selector: String) throws {
        let parts = selector.split(
            separator: "@",
            omittingEmptySubsequences: false
        )
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard parts.count == 2,
              parts.allSatisfy({
                  !$0.isEmpty
                      && $0.count <= 128
                      && !$0.hasPrefix("-")
                      && $0.unicodeScalars.allSatisfy(allowed.contains)
              }) else {
            throw NativePluginOperationError.invalidSelector
        }
    }

    private func validateExecutable(_ path: String) throws {
        guard path.hasPrefix("/"),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw NativePluginOperationError.invalidExecutable
        }
    }

    private func configurationState(
        path: String
    ) throws -> NativePluginConfigurationState {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.path == path else {
            throw NativePluginOperationError.invalidConfigurationPath
        }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
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
            throw NativePluginOperationError.unsafeConfigurationFile
        }
        guard (values.fileSize ?? 0) <= Self.maximumConfigurationBytes else {
            throw NativePluginOperationError.configurationTooLarge
        }
        return NativePluginConfigurationState(
            path: path,
            contentDigest: try digest(Data(contentsOf: url))
        )
    }

    private func configurationStillMatches(
        _ states: [NativePluginConfigurationState]
    ) throws -> Bool {
        try states.allSatisfy {
            try configurationState(path: $0.path) == $0
        }
    }

    private func captureConfiguration(
        _ states: [NativePluginConfigurationState],
        planID: UUID
    ) throws -> ConfigurationBackupBundle {
        let directory = try operationBackupDirectory(for: planID)
        var result: [ConfigurationBackup] = []
        for (index, state) in states.enumerated() {
            let source = URL(fileURLWithPath: state.path)
            guard state.contentDigest != nil else {
                result.append(
                    ConfigurationBackup(
                        original: source,
                        backup: nil,
                        wasPresent: false
                    )
                )
                continue
            }
            let backup = directory.appendingPathComponent(
                "\(index)-\(source.lastPathComponent)"
            )
            try FileManager.default.copyItem(at: source, to: backup)
            guard try digest(Data(contentsOf: backup))
                    == state.contentDigest else {
                throw NativePluginOperationError.invalidPlan
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: backup.path
            )
            result.append(
                ConfigurationBackup(
                    original: source,
                    backup: backup,
                    wasPresent: true
                )
            )
        }
        return ConfigurationBackupBundle(
            directory: directory,
            entries: result
        )
    }

    private func restoreConfiguration(
        _ backups: [ConfigurationBackup]
    ) throws {
        let fileManager = FileManager.default
        for backup in backups {
            guard backup.wasPresent else {
                guard fileManager.fileExists(
                    atPath: backup.original.path
                ) else {
                    continue
                }
                let values = try backup.original.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    throw NativePluginOperationError
                        .unsafeConfigurationFile
                }
                try fileManager.removeItem(at: backup.original)
                continue
            }
            guard let capturedFile = backup.backup else {
                throw NativePluginOperationError.invalidPlan
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
    }

    private func operationBackupDirectory(for planID: UUID) throws -> URL {
        try VerifiedDirectoryTree.createChildDirectory(
            named: planID.uuidString,
            beneath: backupRoot
        )
    }

    private func commandRequest(
        for spec: NativePluginOperationSpec
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
        for spec: NativePluginOperationSpec
    ) -> [String] {
        switch spec.agent {
        case .claude:
            [
                "plugin",
                spec.action.rawValue,
                spec.selector,
                "--scope",
                "user"
            ]
        case .codex:
            [
                "plugin",
                spec.action == .install ? "add" : "remove",
                spec.selector,
                "--json"
            ]
        }
    }

    private func commandFailureDescription(
        _ result: CommandResult
    ) -> String {
        let detail = result.standardError
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : ": \(detail)"
        return SensitiveValueRedactor.redact(
            "Native plugin command failed\(suffix)"
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

private struct ConfigurationBackup {
    let original: URL
    let backup: URL?
    let wasPresent: Bool
}

private struct ConfigurationBackupBundle {
    let directory: URL
    let entries: [ConfigurationBackup]
}
