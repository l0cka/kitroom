import Foundation

public enum RemotePluginOperationError: LocalizedError, Equatable, Sendable {
    case remoteHostRequired
    case stableHostIdentityRequired
    case agentVersionRequired
    case unsupportedOperation
    case invalidSource
    case invalidSelector
    case invalidExecutable
    case invalidRemotePath
    case unsafeConfiguration
    case configurationTooLarge
    case configurationProbeFailed
    case invalidPlan

    public var errorDescription: String? {
        switch self {
        case .remoteHostRequired:
            "This plugin operation requires an SSH host."
        case .stableHostIdentityRequired:
            "A verified stable remote-host identity is required."
        case .agentVersionRequired:
            "A verified remote agent version is required."
        case .unsupportedOperation:
            "The selected agent does not expose this plugin operation."
        case .invalidSource:
            "The plugin is not bound to the selected native marketplace source."
        case .invalidSelector:
            "The plugin and marketplace selector is unsafe or incomplete."
        case .invalidExecutable:
            "The verified remote agent executable path is invalid."
        case .invalidRemotePath:
            "A remote configuration or backup path is not a normalized absolute path."
        case .unsafeConfiguration:
            "The remote configuration target is not a regular file or is a symbolic link."
        case .configurationTooLarge:
            "The remote configuration exceeds the bounded backup limit."
        case .configurationProbeFailed:
            "The remote configuration could not be inspected safely."
        case .invalidPlan:
            "The operation plan cannot be executed by the remote plugin engine."
        }
    }
}

public actor RemotePluginOperationEngine {
    public static let envelopeVersion = 1
    public static let maximumConfigurationBytes = 5 * 1_024 * 1_024

    public init() {}

    public func planClaudeToggle(
        host: ManagedHost,
        hostIdentity: HostIdentityEvidence,
        agentVersion: String,
        action: NativePluginAction,
        package: PackageRecord,
        source: CatalogSource,
        installation: InstallationRecord,
        executablePath: String,
        configurationPath: String,
        remoteHomeDirectory: String,
        session: any HostSession,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) async throws -> OperationPlan {
        try await planPluginAction(
            host: host,
            hostIdentity: hostIdentity,
            agentVersion: agentVersion,
            agent: .claude,
            action: action,
            package: package,
            source: source,
            installation: installation,
            executablePath: executablePath,
            configurationPath: configurationPath,
            remoteHomeDirectory: remoteHomeDirectory,
            session: session,
            basedOnSnapshotAt: basedOnSnapshotAt,
            createdAt: createdAt
        )
    }

    public func planPluginAction(
        host: ManagedHost,
        hostIdentity: HostIdentityEvidence,
        agentVersion: String,
        agent: AgentKind,
        action: NativePluginAction,
        package: PackageRecord,
        source: CatalogSource,
        installation: InstallationRecord?,
        executablePath: String,
        configurationPath: String,
        remoteHomeDirectory: String,
        session: any HostSession,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) async throws -> OperationPlan {
        guard host.connection.isRemote,
              session.host.id == host.id,
              session.host.connection.isRemote else {
            throw RemotePluginOperationError.remoteHostRequired
        }
        guard hostIdentity.kind != .derived,
              !hostIdentity.value.isEmpty else {
            throw RemotePluginOperationError.stableHostIdentityRequired
        }
        guard !agentVersion.isEmpty else {
            throw RemotePluginOperationError.agentVersionRequired
        }
        guard package.agent == agent,
              source.agent == agent,
              installation?.agent == agent || installation == nil,
              package.sourceID == source.id,
              source.kind == .marketplace else {
            throw RemotePluginOperationError.invalidSource
        }
        if let installation {
            guard installation.hostID == host.id,
                  installation.scope == .user,
                  installation.origin == .marketplace,
                  installation.restriction == .agentManaged else {
                throw RemotePluginOperationError.unsupportedOperation
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
                throw RemotePluginOperationError.unsupportedOperation
            }
            expectedBeforeInstalled = false
            expectedAfterInstalled = true
            expectedBeforeState = nil
            expectedAfterState = .enabled
            expectedBeforeVersion = nil
            expectedAfterVersion = package.version
            kind = .install
        case .update:
            guard let installation,
                  let availableVersion = package.version,
                  installation.updateStatus == .updateAvailable
                    || (
                        installation.installedVersion != nil
                            && installation.installedVersion
                                != availableVersion
                    ) else {
                throw RemotePluginOperationError.unsupportedOperation
            }
            expectedBeforeInstalled = true
            expectedAfterInstalled = true
            expectedBeforeState = installation.state
            expectedAfterState = installation.state
            expectedBeforeVersion = installation.installedVersion
            expectedAfterVersion = availableVersion
            kind = .update
        case .enable:
            guard let installation,
                  installation.state == .disabled else {
                throw RemotePluginOperationError.unsupportedOperation
            }
            expectedBeforeInstalled = true
            expectedAfterInstalled = true
            expectedBeforeState = .disabled
            expectedAfterState = .enabled
            expectedBeforeVersion = installation.installedVersion
            expectedAfterVersion = installation.installedVersion
            kind = .enable
        case .disable:
            guard let installation,
                  installation.state == .enabled else {
                throw RemotePluginOperationError.unsupportedOperation
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
                throw RemotePluginOperationError.unsupportedOperation
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
        try validateRemotePath(configurationPath)
        try validateRemotePath(remoteHomeDirectory)

        let configurationState = try await inspectConfiguration(
            path: configurationPath,
            session: session
        )
        let planID = UUID()
        guard let configurationName = RemotePOSIXPath.lastComponent(
            configurationPath
        ), let backupPath = RemotePOSIXPath.appending(
            relativePath:
                ".kitroom/backups/\(planID.uuidString)/\(configurationName)",
            to: remoteHomeDirectory
        ) else {
            throw RemotePluginOperationError.invalidRemotePath
        }
        let spec = RemotePluginOperationSpec(
            envelopeVersion: Self.envelopeVersion,
            agent: agent,
            action: action,
            selector: selector,
            scope: .user,
            executablePath: executablePath,
            configurationState: configurationState,
            remoteBackupPath: backupPath,
            expectedBeforeInstalled: expectedBeforeInstalled,
            expectedAfterInstalled: expectedAfterInstalled,
            expectedBeforeState: expectedBeforeState,
            expectedAfterState: expectedAfterState,
            expectedBeforeVersion: expectedBeforeVersion,
            expectedAfterVersion: expectedAfterVersion,
            requiresCataloguePreflight: action == .install
                || action == .update
        )
        let risk: OperationRisk = switch action {
        case .install, .enable:
            .low
        case .disable, .uninstall:
            .medium
        case .update:
            .high
        }
        var warnings = [
            "Plugin code and hooks can affect future agent sessions.",
            "This changes plugin state on the selected SSH host.",
            "Connection loss is treated as unknown until fresh inventory proves the resulting state."
        ]
        if action == .update {
            warnings.append(
                "The native CLI does not provide a version-pinned inverse update. Kitroom can restore configuration, but automatic code rollback may be incomplete."
            )
        }
        return OperationPlan(
            id: planID,
            kind: kind,
            risk: risk,
            hostID: host.id,
            hostIdentity: hostIdentity.value,
            agent: agent,
            agentVersion: agentVersion,
            extensionID: selector,
            scope: .user,
            sourceReference: source.reference ?? source.name,
            version: package.version ?? installation?.installedVersion,
            revision: source.revision,
            contentDigest: package.manifestDigest,
            basedOnSnapshotAt: basedOnSnapshotAt,
            changes: [
                PlannedChange(
                    summary: configurationState.contentDigest == nil
                        ? "Confirm remote configuration is absent before the operation"
                        : "Capture remote configuration before the operation",
                    target: configurationPath,
                    commandPreview: "Kitroom remote envelope v\(Self.envelopeVersion) verifies the bound digest and writes the exact backup \(backupPath).",
                    rollback: configurationState.contentDigest == nil
                        ? "Remove only the exact configuration file if the native command creates it."
                        : "Atomically restore the digest-verified remote backup."
                ),
                PlannedChange(
                    summary: "\(action.rawValue.capitalized) \(agent.displayName) plugin \(selector) on the SSH host",
                    target: "\(agent.displayName) user plugin state",
                    commandPreview: ([executablePath] + commandArguments(for: spec))
                        .map(Self.displayQuoted)
                        .joined(separator: " "),
                    rollback: rollbackDescription(
                        for: action,
                        agent: agent
                    )
                )
            ],
            warnings: warnings,
            verificationSteps: [
                "Re-check the stable remote-host identity and \(agent.displayName) version.",
                "Confirm the configuration digest still matches this plan.",
                verificationDescription(
                    selector: selector,
                    installed: expectedAfterInstalled,
                    state: expectedAfterState,
                    version: expectedAfterVersion
                )
            ],
            execution: .remotePlugin(spec),
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
                    message: "The immutable remote plugin plan was created."
                ),
                OperationEvent(
                    state: .awaitingApproval,
                    occurredAt: now,
                    message: "The remote plan is awaiting digest-bound approval."
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
                message: "Fresh remote inventory no longer matches the approved plugin state.",
                failure: "Remote plugin state changed after planning."
            )
        }
        guard preflight.verifiedHostIdentity == plan.hostIdentity,
              preflight.verifiedAgentVersion == plan.agentVersion else {
            return record.transitioned(
                to: .invalidated,
                at: now,
                message: "The concrete remote session was not attested to the approved host identity and agent version.",
                failure: "Remote target attestation changed or is missing."
            )
        }
        guard session.host.id == plan.hostID,
              session.host.connection.isRemote,
              case let .remotePlugin(spec) = plan.execution else {
            return record.transitioned(
                to: .invalidated,
                at: now,
                message: "The plan does not match this remote plugin session.",
                failure: RemotePluginOperationError.invalidPlan.localizedDescription
            )
        }

        do {
            try validate(spec)
            let current = try await inspectConfiguration(
                path: spec.configurationState.path,
                session: session
            )
            guard current == spec.configurationState else {
                return record.transitioned(
                    to: .invalidated,
                    at: now,
                    message: "Remote configuration changed after planning.",
                    failure: "Configuration digest changed."
                )
            }
            let capture = try await session.execute(
                captureRequest(spec: spec)
            )
            guard capture.succeeded,
                  !capture.standardOutputWasTruncated,
                  !capture.standardErrorWasTruncated,
                  capture.standardOutput.contains(
                      "KITROOM_REMOTE_PLUGIN_V1|CAPTURED"
                  ) else {
                return record.transitioned(
                    to: .failed,
                    at: now,
                    message: "The remote configuration backup did not complete.",
                    rollbackState: .notRequired,
                    failure: commandFailure(capture)
                )
            }
            record = record.transitioned(
                to: .applying,
                at: now,
                message: "Remote configuration was captured with its approved digest. Running the exact native command.",
                backupPath: spec.remoteBackupPath,
                rollbackState: .available
            )
            let result: CommandResult
            do {
                result = try await session.execute(
                    commandRequest(for: spec)
                )
            } catch {
                return await recover(
                    spec: spec,
                    session: session,
                    record: record,
                    at: now,
                    reason: SensitiveValueRedactor.redact(
                        error.localizedDescription
                    ),
                    verificationFailure: false,
                    verifyExpectedState: verifyExpectedState,
                    verifyRolledBackState: verifyRolledBackState
                )
            }
            guard result.succeeded,
                  !result.standardOutputWasTruncated,
                  !result.standardErrorWasTruncated else {
                return await recover(
                    spec: spec,
                    session: session,
                    record: record,
                    at: now,
                    reason: commandFailure(result),
                    verificationFailure: false,
                    verifyExpectedState: verifyExpectedState,
                    verifyRolledBackState: verifyRolledBackState
                )
            }
            let verifying = record.transitioned(
                to: .verifying,
                at: now,
                message: "The remote native command completed. Checking fresh \(spec.agent.displayName) inventory."
            )
            guard await verifyExpectedState() else {
                return await recover(
                    spec: spec,
                    session: session,
                    record: verifying,
                    at: now,
                    reason: "Fresh remote inventory did not confirm the approved plugin state.",
                    verificationFailure: true,
                    verifyExpectedState: verifyExpectedState,
                    verifyRolledBackState: verifyRolledBackState
                )
            }
            return verifying.transitioned(
                to: .completed,
                at: now,
                message: "Fresh remote \(spec.agent.displayName) inventory matches the approved plugin state.",
                backupPath: spec.remoteBackupPath,
                rollbackState: .available
            )
        } catch {
            return record.transitioned(
                to: .failed,
                at: now,
                message: "The remote plugin operation could not be applied.",
                failure: SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
    }

    private func recover(
        spec: RemotePluginOperationSpec,
        session: any HostSession,
        record: OperationRecord,
        at date: Date,
        reason: String,
        verificationFailure: Bool,
        verifyExpectedState: @escaping @Sendable () async -> Bool,
        verifyRolledBackState: @escaping @Sendable () async -> Bool
    ) async -> OperationRecord {
        if await verifyExpectedState() {
            return await rollback(
                spec: spec,
                session: session,
                record: record,
                at: date,
                reason: reason,
                verificationFailure: verificationFailure,
                runInverse: true,
                verifyRolledBackState: verifyRolledBackState
            )
        }
        if await verifyRolledBackState() {
            return await rollback(
                spec: spec,
                session: session,
                record: record,
                at: date,
                reason: reason,
                verificationFailure: verificationFailure,
                runInverse: false,
                verifyRolledBackState: verifyRolledBackState
            )
        }
        return await rollback(
            spec: spec,
            session: session,
            record: record,
            at: date,
            reason: "\(reason) The native plugin state could not be established.",
            verificationFailure: verificationFailure,
            runInverse: false,
            verifyRolledBackState: verifyRolledBackState
        )
    }

    private func rollback(
        spec: RemotePluginOperationSpec,
        session: any HostSession,
        record: OperationRecord,
        at date: Date,
        reason: String,
        verificationFailure: Bool,
        runInverse: Bool,
        verifyRolledBackState: @escaping @Sendable () async -> Bool
    ) async -> OperationRecord {
        var rollbackFailures: [String] = []
        if runInverse, let inverse = inverseSpec(spec) {
            do {
                let result = try await session.execute(
                    commandRequest(for: inverse)
                )
                if !result.succeeded {
                    rollbackFailures.append(commandFailure(result))
                }
            } catch {
                rollbackFailures.append(
                    SensitiveValueRedactor.redact(
                        error.localizedDescription
                    )
                )
            }
        }
        do {
            let restore = try await session.execute(
                restoreRequest(spec: spec)
            )
            if !restore.succeeded
                || !restore.standardOutput.contains(
                    "KITROOM_REMOTE_PLUGIN_V1|RESTORED"
                ) {
                rollbackFailures.append(commandFailure(restore))
            }
        } catch {
            rollbackFailures.append(
                SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
        guard rollbackFailures.isEmpty,
              await verifyRolledBackState() else {
            let detail = rollbackFailures.isEmpty
                ? "Fresh inventory did not confirm rollback."
                : rollbackFailures.joined(separator: " ")
            return record.transitioned(
                to: verificationFailure ? .verificationFailed : .failed,
                at: date,
                message: "\(reason) Remote rollback could not be verified.",
                backupPath: spec.remoteBackupPath,
                rollbackState: .failed,
                failure: "\(reason) \(detail)"
            )
        }
        return record.transitioned(
            to: verificationFailure ? .verificationFailed : .rolledBack,
            at: date,
            message: "\(reason) Configuration was restored and fresh inventory confirms the original plugin state.",
            backupPath: spec.remoteBackupPath,
            rollbackState: .succeeded,
            failure: reason
        )
    }

    private func inspectConfiguration(
        path: String,
        session: any HostSession
    ) async throws -> NativePluginConfigurationState {
        let result = try await session.execute(
            CommandRequest(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    Self.inspectEnvelope,
                    "kitroom-remote-plugin-v1",
                    path,
                    String(Self.maximumConfigurationBytes)
                ],
                environment: [
                    "LC_ALL": "C",
                    "PATH": "/usr/bin:/bin"
                ],
                timeout: .seconds(15),
                maximumOutputBytes: 16_384
            )
        )
        guard result.succeeded,
              !result.standardOutputWasTruncated,
              !result.standardErrorWasTruncated else {
            if result.exitCode == 43 {
                throw RemotePluginOperationError.configurationTooLarge
            }
            if result.exitCode == 41 || result.exitCode == 42 {
                throw RemotePluginOperationError.unsafeConfiguration
            }
            throw RemotePluginOperationError.configurationProbeFailed
        }
        let output = result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if output == "KITROOM_REMOTE_PLUGIN_V1|ABSENT" {
            return NativePluginConfigurationState(
                path: path,
                contentDigest: nil
            )
        }
        let prefix = "KITROOM_REMOTE_PLUGIN_V1|PRESENT|"
        guard output.hasPrefix(prefix) else {
            throw RemotePluginOperationError.configurationProbeFailed
        }
        let digest = String(output.dropFirst(prefix.count))
        guard digest.count == 64,
              digest.unicodeScalars.allSatisfy({
                  CharacterSet(
                      charactersIn: "0123456789abcdef"
                  ).contains($0)
              }) else {
            throw RemotePluginOperationError.configurationProbeFailed
        }
        return NativePluginConfigurationState(
            path: path,
            contentDigest: digest
        )
    }

    private func captureRequest(
        spec: RemotePluginOperationSpec
    ) -> CommandRequest {
        CommandRequest(
            executable: "/bin/sh",
            arguments: [
                "-c",
                Self.captureEnvelope,
                "kitroom-remote-plugin-v1",
                spec.configurationState.path,
                spec.remoteBackupPath,
                spec.configurationState.contentDigest ?? "absent",
                String(Self.maximumConfigurationBytes)
            ],
            environment: [
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin"
            ],
            timeout: .seconds(30),
            maximumOutputBytes: 131_072
        )
    }

    private func restoreRequest(
        spec: RemotePluginOperationSpec
    ) -> CommandRequest {
        CommandRequest(
            executable: "/bin/sh",
            arguments: [
                "-c",
                Self.restoreEnvelope,
                "kitroom-remote-plugin-v1",
                spec.configurationState.path,
                spec.remoteBackupPath,
                spec.configurationState.contentDigest ?? "absent"
            ],
            environment: [
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin"
            ],
            timeout: .seconds(30),
            maximumOutputBytes: 131_072
        )
    }

    private func commandRequest(
        for spec: RemotePluginOperationSpec
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
        for spec: RemotePluginOperationSpec
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

    private func inverseSpec(
        _ spec: RemotePluginOperationSpec
    ) -> RemotePluginOperationSpec? {
        guard let inverseAction = spec.action.inverse else {
            return nil
        }
        return RemotePluginOperationSpec(
            envelopeVersion: spec.envelopeVersion,
            agent: spec.agent,
            action: inverseAction,
            selector: spec.selector,
            scope: spec.scope,
            executablePath: spec.executablePath,
            configurationState: spec.configurationState,
            remoteBackupPath: spec.remoteBackupPath,
            expectedBeforeInstalled: spec.expectedAfterInstalled,
            expectedAfterInstalled: spec.expectedBeforeInstalled,
            expectedBeforeState: spec.expectedAfterState,
            expectedAfterState: spec.expectedBeforeState,
            expectedBeforeVersion: spec.expectedAfterVersion,
            expectedAfterVersion: spec.expectedBeforeVersion,
            requiresCataloguePreflight: false
        )
    }

    private func validate(_ spec: RemotePluginOperationSpec) throws {
        guard spec.envelopeVersion == Self.envelopeVersion,
              spec.scope == .user else {
            throw RemotePluginOperationError.invalidPlan
        }
        try validate(action: spec.action, for: spec.agent)
        switch spec.action {
        case .install:
            guard !spec.expectedBeforeInstalled,
                  spec.expectedAfterInstalled else {
                throw RemotePluginOperationError.invalidPlan
            }
        case .uninstall:
            guard spec.expectedBeforeInstalled,
                  !spec.expectedAfterInstalled else {
                throw RemotePluginOperationError.invalidPlan
            }
        case .update:
            guard spec.expectedBeforeInstalled,
                  spec.expectedAfterInstalled,
                  spec.expectedBeforeVersion
                    != spec.expectedAfterVersion else {
                throw RemotePluginOperationError.invalidPlan
            }
        case .enable, .disable:
            guard spec.expectedBeforeInstalled,
                  spec.expectedAfterInstalled,
                  let before = spec.expectedBeforeState,
                  let after = spec.expectedAfterState,
                  Set<EffectiveState>([before, after])
                    == Set<EffectiveState>([.enabled, .disabled]) else {
                throw RemotePluginOperationError.invalidPlan
            }
        }
        try validateSelector(spec.selector)
        try validateExecutable(spec.executablePath)
        try validateRemotePath(spec.configurationState.path)
        try validateRemotePath(spec.remoteBackupPath)
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
            throw RemotePluginOperationError.unsupportedOperation
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
            "Run the inverse native \(agent.displayName) operation, restore captured configuration, and verify fresh inventory."
        }
    }

    private func verificationDescription(
        selector: String,
        installed: Bool,
        state: EffectiveState?,
        version: String?
    ) -> String {
        guard installed else {
            return "Run fresh inventory and confirm \(selector) is absent."
        }
        var details = [
            "Run fresh inventory and confirm \(selector) is installed"
        ]
        if let state {
            details.append("with state \(state.rawValue)")
        }
        if let version {
            details.append("at version \(version)")
        }
        return details.joined(separator: " ") + "."
    }

    private func validateSelector(_ value: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        let parts = value.split(
            separator: "@",
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              parts.allSatisfy({
                  !$0.isEmpty
                      && $0.count <= 128
                      && !$0.hasPrefix("-")
                      && $0.unicodeScalars.allSatisfy(allowed.contains)
              }) else {
            throw RemotePluginOperationError.invalidSelector
        }
    }

    private func validateExecutable(_ value: String) throws {
        guard RemotePOSIXPath.lastComponent(value) != nil else {
            throw RemotePluginOperationError.invalidExecutable
        }
    }

    private func validateRemotePath(_ value: String) throws {
        guard RemotePOSIXPath.isNormalizedAbsolute(value) else {
            throw RemotePluginOperationError.invalidRemotePath
        }
    }

    private func commandFailure(_ result: CommandResult) -> String {
        let detail = result.standardError
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SensitiveValueRedactor.redact(
            detail.isEmpty
                ? "The remote plugin command did not complete."
                : "The remote plugin command failed: \(detail)"
        )
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

    private static let inspectEnvelope = #"""
    set -eu
    path=$1
    maximum=$2
    [ ! -L "$path" ] || exit 41
    if [ -f "$path" ]; then
      size=$(wc -c < "$path" | tr -d ' ')
      [ "$size" -le "$maximum" ] || exit 43
      if command -v sha256sum >/dev/null 2>&1; then
        digest=$(sha256sum "$path" | cut -d ' ' -f 1)
      elif command -v shasum >/dev/null 2>&1; then
        digest=$(shasum -a 256 "$path" | cut -d ' ' -f 1)
      else
        exit 44
      fi
      printf 'KITROOM_REMOTE_PLUGIN_V1|PRESENT|%s\n' "$digest"
    elif [ -e "$path" ]; then
      exit 42
    else
      printf 'KITROOM_REMOTE_PLUGIN_V1|ABSENT\n'
    fi
    """#

    private static let captureEnvelope = #"""
    set -eu
    path=$1
    backup=$2
    expected=$3
    maximum=$4
    backup_dir=${backup%/*}
    reject_symlink_chain() {
      check=$1
      while [ "$check" != / ]; do
        [ ! -L "$check" ] || return 1
        next=${check%/*}
        if [ -z "$next" ] || [ "$next" = "$check" ]; then
          next=/
        fi
        check=$next
      done
    }
    [ ! -e "$backup" ]
    reject_symlink_chain "$backup_dir"
    umask 077
    mkdir -p -m 700 -- "$backup_dir"
    chmod 700 "$backup_dir"
    if [ "$expected" = absent ]; then
      [ ! -e "$path" ]
    else
      [ -f "$path" ]
      [ ! -L "$path" ]
      size=$(wc -c < "$path" | tr -d ' ')
      [ "$size" -le "$maximum" ] || exit 43
      if command -v sha256sum >/dev/null 2>&1; then
        digest=$(sha256sum "$path" | cut -d ' ' -f 1)
      elif command -v shasum >/dev/null 2>&1; then
        digest=$(shasum -a 256 "$path" | cut -d ' ' -f 1)
      else
        exit 44
      fi
      [ "$digest" = "$expected" ]
      cp -p -- "$path" "$backup"
      chmod 600 "$backup"
    fi
    printf 'KITROOM_REMOTE_PLUGIN_V1|CAPTURED\n'
    """#

    private static let restoreEnvelope = #"""
    set -eu
    path=$1
    backup=$2
    expected=$3
    parent=${path%/*}
    base=${path##*/}
    stage=$parent/.$base.kitroom-restore-$$
    backup_dir=${backup%/*}
    reject_symlink_chain() {
      check=$1
      while [ "$check" != / ]; do
        [ ! -L "$check" ] || return 1
        next=${check%/*}
        if [ -z "$next" ] || [ "$next" = "$check" ]; then
          next=/
        fi
        check=$next
      done
    }
    [ -d "$parent" ]
    reject_symlink_chain "$backup_dir"
    if [ "$expected" = absent ]; then
      if [ -e "$path" ]; then
        [ -f "$path" ]
        [ ! -L "$path" ]
        rm -- "$path"
      fi
    else
      [ -f "$backup" ]
      [ ! -L "$backup" ]
      if command -v sha256sum >/dev/null 2>&1; then
        digest=$(sha256sum "$backup" | cut -d ' ' -f 1)
      elif command -v shasum >/dev/null 2>&1; then
        digest=$(shasum -a 256 "$backup" | cut -d ' ' -f 1)
      else
        exit 44
      fi
      [ "$digest" = "$expected" ]
      [ ! -e "$stage" ]
      cp -p -- "$backup" "$stage"
      mv -f -- "$stage" "$path"
    fi
    printf 'KITROOM_REMOTE_PLUGIN_V1|RESTORED\n'
    """#
}
