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
            "The guarded remote plugin engine supports Claude Code enable and disable operations."
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
        guard host.connection.isRemote,
              session.host.id == host.id else {
            throw RemotePluginOperationError.remoteHostRequired
        }
        guard hostIdentity.kind != .derived,
              !hostIdentity.value.isEmpty else {
            throw RemotePluginOperationError.stableHostIdentityRequired
        }
        guard !agentVersion.isEmpty else {
            throw RemotePluginOperationError.agentVersionRequired
        }
        guard package.agent == .claude,
              source.agent == .claude,
              installation.agent == .claude,
              package.sourceID == source.id,
              source.kind == .marketplace else {
            throw RemotePluginOperationError.invalidSource
        }
        guard installation.hostID == host.id,
              installation.scope == .user,
              installation.origin == .marketplace,
              installation.restriction == .agentManaged else {
            throw RemotePluginOperationError.unsupportedOperation
        }
        let before: EffectiveState
        let after: EffectiveState
        let kind: OperationKind
        switch (action, installation.state) {
        case (.enable, .disabled):
            before = .disabled
            after = .enabled
            kind = .enable
        case (.disable, .enabled):
            before = .enabled
            after = .disabled
            kind = .disable
        default:
            throw RemotePluginOperationError.unsupportedOperation
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
        let backupPath = remoteHomeDirectory
            + "/.kitroom/backups/"
            + planID.uuidString
            + "/"
            + URL(fileURLWithPath: configurationPath).lastPathComponent
        try validateRemotePath(backupPath)
        let spec = RemotePluginOperationSpec(
            envelopeVersion: Self.envelopeVersion,
            agent: .claude,
            action: action,
            selector: selector,
            scope: .user,
            executablePath: executablePath,
            configurationState: configurationState,
            remoteBackupPath: backupPath,
            expectedBeforeState: before,
            expectedAfterState: after,
            expectedVersion: installation.installedVersion
        )
        return OperationPlan(
            id: planID,
            kind: kind,
            risk: action == .enable ? .low : .medium,
            hostID: host.id,
            hostIdentity: hostIdentity.value,
            agent: .claude,
            agentVersion: agentVersion,
            extensionID: selector,
            scope: .user,
            sourceReference: source.reference ?? source.name,
            version: package.version ?? installation.installedVersion,
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
                    summary: "\(action.rawValue.capitalized) Claude Code plugin \(selector) on the SSH host",
                    target: "Claude Code user plugin state",
                    commandPreview: ([executablePath] + commandArguments(for: spec))
                        .map(Self.displayQuoted)
                        .joined(separator: " "),
                    rollback: "Run the inverse typed Claude Code operation, restore exact configuration, and verify fresh inventory."
                )
            ],
            warnings: [
                "This changes plugin state on the selected SSH host.",
                "Connection loss is treated as unknown until fresh inventory proves the resulting state."
            ],
            verificationSteps: [
                "Re-check the stable remote-host identity and Claude Code version.",
                "Confirm the configuration digest still matches this plan.",
                "Run fresh Claude Code inventory and confirm \(selector) is \(after.rawValue)."
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
                message: "The remote native command completed. Checking fresh Claude Code inventory."
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
                message: "Fresh remote Claude Code inventory matches the approved plugin state.",
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
        return record.transitioned(
            to: verificationFailure ? .verificationFailed : .failed,
            at: date,
            message: "\(reason) The remote plugin outcome could not be established.",
            backupPath: spec.remoteBackupPath,
            rollbackState: .failed,
            failure: reason
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
        if runInverse {
            let inverse = inverseSpec(spec)
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
        [
            "plugin",
            spec.action.rawValue,
            spec.selector,
            "--scope",
            "user"
        ]
    }

    private func inverseSpec(
        _ spec: RemotePluginOperationSpec
    ) -> RemotePluginOperationSpec {
        RemotePluginOperationSpec(
            envelopeVersion: spec.envelopeVersion,
            agent: spec.agent,
            action: spec.action == .enable ? .disable : .enable,
            selector: spec.selector,
            scope: spec.scope,
            executablePath: spec.executablePath,
            configurationState: spec.configurationState,
            remoteBackupPath: spec.remoteBackupPath,
            expectedBeforeState: spec.expectedAfterState,
            expectedAfterState: spec.expectedBeforeState,
            expectedVersion: spec.expectedVersion
        )
    }

    private func validate(_ spec: RemotePluginOperationSpec) throws {
        guard spec.envelopeVersion == Self.envelopeVersion,
              spec.agent == .claude,
              spec.scope == .user,
              spec.action == .enable || spec.action == .disable,
              Set([spec.expectedBeforeState, spec.expectedAfterState])
                == Set<EffectiveState>([.enabled, .disabled]) else {
            throw RemotePluginOperationError.invalidPlan
        }
        try validateSelector(spec.selector)
        try validateExecutable(spec.executablePath)
        try validateRemotePath(spec.configurationState.path)
        try validateRemotePath(spec.remoteBackupPath)
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
        guard value.hasPrefix("/"),
              URL(fileURLWithPath: value).standardizedFileURL.path
                == value else {
            throw RemotePluginOperationError.invalidExecutable
        }
    }

    private func validateRemotePath(_ value: String) throws {
        guard value.hasPrefix("/"),
              !value.contains("\0"),
              !value.contains("\n"),
              URL(fileURLWithPath: value).standardizedFileURL.path
                == value else {
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
    [ ! -e "$backup" ]
    umask 077
    mkdir -p -m 700 -- "$backup_dir"
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
    [ -d "$parent" ]
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
