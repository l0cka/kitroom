import Foundation

public enum RemoteMCPOperationError: LocalizedError, Equatable, Sendable {
    case remoteHostRequired
    case stableHostIdentityRequired
    case agentVersionRequired
    case invalidTarget
    case invalidName
    case invalidURL
    case invalidExecutable
    case invalidRemotePath
    case unsafeConfiguration
    case configurationTooLarge
    case configurationProbeFailed
    case invalidPlan

    public var errorDescription: String? {
        switch self {
        case .remoteHostRequired:
            "This MCP operation requires an SSH host."
        case .stableHostIdentityRequired:
            "A verified stable remote-host identity is required."
        case .agentVersionRequired:
            "A verified remote Codex version is required."
        case .invalidTarget:
            "Only a directly configured, user-scoped Codex MCP server can be changed."
        case .invalidName:
            "The MCP server name is unsafe or incomplete."
        case .invalidURL:
            "Only a credential-free HTTPS URL without query or fragment data is supported."
        case .invalidExecutable:
            "The verified remote Codex executable path is invalid."
        case .invalidRemotePath:
            "A remote configuration or backup path is not a normalized absolute path."
        case .unsafeConfiguration:
            "The remote Codex configuration is not a regular file or is a symbolic link."
        case .configurationTooLarge:
            "The remote Codex configuration exceeds the bounded backup limit."
        case .configurationProbeFailed:
            "The remote Codex configuration could not be inspected safely."
        case .invalidPlan:
            "The operation plan cannot be executed by the remote MCP engine."
        }
    }
}

public actor RemoteMCPOperationEngine {
    public static let envelopeVersion = 1
    public static let maximumConfigurationBytes = 5 * 1_024 * 1_024

    public init() {}

    public func planAddCodexHTTPServer(
        host: ManagedHost,
        hostIdentity: HostIdentityEvidence,
        agentVersion: String,
        serverName: String,
        serverURL: String,
        executablePath: String,
        configurationPath: String,
        remoteHomeDirectory: String,
        existingCapability: ProvidedCapability?,
        session: any HostSession,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) async throws -> OperationPlan {
        try validatePlanningContext(
            host: host,
            hostIdentity: hostIdentity,
            agentVersion: agentVersion,
            executablePath: executablePath,
            session: session
        )
        try validateName(serverName)
        try validateHTTPSURL(serverURL)
        guard existingCapability == nil else {
            throw RemoteMCPOperationError.invalidTarget
        }
        let configurationState = try await inspectConfiguration(
            path: configurationPath,
            session: session
        )
        let planID = UUID()
        let spec = try makeSpec(
            planID: planID,
            action: .add,
            serverName: serverName,
            serverURL: serverURL,
            executablePath: executablePath,
            configurationState: configurationState,
            remoteHomeDirectory: remoteHomeDirectory
        )
        return makePlan(
            planID: planID,
            host: host,
            hostIdentity: hostIdentity,
            agentVersion: agentVersion,
            spec: spec,
            basedOnSnapshotAt: basedOnSnapshotAt,
            createdAt: createdAt
        )
    }

    public func planRemoveCodexServer(
        host: ManagedHost,
        hostIdentity: HostIdentityEvidence,
        agentVersion: String,
        capability: ProvidedCapability,
        installation: InstallationRecord,
        executablePath: String,
        configurationPath: String,
        remoteHomeDirectory: String,
        session: any HostSession,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) async throws -> OperationPlan {
        try validatePlanningContext(
            host: host,
            hostIdentity: hostIdentity,
            agentVersion: agentVersion,
            executablePath: executablePath,
            session: session
        )
        guard capability.agent == .codex,
              capability.kind == .mcpServer,
              capability.packageID == nil,
              installation.hostID == host.id,
              installation.agent == .codex,
              installation.capabilityID == capability.id,
              installation.scope == .user,
              installation.origin == .standalone,
              installation.restriction == .agentManaged else {
            throw RemoteMCPOperationError.invalidTarget
        }
        try validateName(capability.name)
        let configurationState = try await inspectConfiguration(
            path: configurationPath,
            session: session
        )
        guard configurationState.contentDigest != nil else {
            throw RemoteMCPOperationError.invalidTarget
        }
        let planID = UUID()
        let spec = try makeSpec(
            planID: planID,
            action: .remove,
            serverName: capability.name,
            serverURL: nil,
            executablePath: executablePath,
            configurationState: configurationState,
            remoteHomeDirectory: remoteHomeDirectory
        )
        return makePlan(
            planID: planID,
            host: host,
            hostIdentity: hostIdentity,
            agentVersion: agentVersion,
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
                    message: "The immutable remote MCP plan was created."
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
                message: "Fresh remote inventory no longer matches the approved MCP state.",
                failure: "Remote MCP state changed after planning."
            )
        }
        guard preflight.verifiedHostIdentity == plan.hostIdentity,
              preflight.verifiedAgentVersion == plan.agentVersion else {
            return record.transitioned(
                to: .invalidated,
                at: now,
                message: "The concrete remote session was not attested to the approved host identity and Codex version.",
                failure: "Remote target attestation changed or is missing."
            )
        }
        guard session.host.id == plan.hostID,
              session.host.connection.isRemote,
              case let .remoteMCP(spec) = plan.execution else {
            return record.transitioned(
                to: .invalidated,
                at: now,
                message: "The plan does not match this remote MCP session.",
                failure: RemoteMCPOperationError.invalidPlan
                    .localizedDescription
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
                    message: "Remote Codex configuration changed after planning.",
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
                      "KITROOM_REMOTE_MCP_V1|CAPTURED"
                  ) else {
                return record.transitioned(
                    to: .failed,
                    at: now,
                    message: "The remote Codex configuration backup did not complete.",
                    rollbackState: .notRequired,
                    failure: commandFailure(capture)
                )
            }
            record = record.transitioned(
                to: .applying,
                at: now,
                message: "Remote Codex configuration was captured with its approved digest. Running the exact native command.",
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
                    runInverse: await verifyExpectedState(),
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
                    runInverse: await verifyExpectedState(),
                    verifyRolledBackState: verifyRolledBackState
                )
            }
            let verifying = record.transitioned(
                to: .verifying,
                at: now,
                message: "The remote native command completed. Checking fresh Codex inventory."
            )
            guard await verifyExpectedState() else {
                return await recover(
                    spec: spec,
                    session: session,
                    record: verifying,
                    at: now,
                    reason: "Fresh remote inventory did not confirm the approved MCP state.",
                    verificationFailure: true,
                    runInverse: true,
                    verifyRolledBackState: verifyRolledBackState
                )
            }
            return verifying.transitioned(
                to: .completed,
                at: now,
                message: "Fresh remote Codex inventory matches the approved MCP state.",
                backupPath: spec.remoteBackupPath,
                rollbackState: .available
            )
        } catch {
            return record.transitioned(
                to: .failed,
                at: now,
                message: "The remote MCP operation could not be applied.",
                failure: SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
    }

    private func recover(
        spec: RemoteMCPOperationSpec,
        session: any HostSession,
        record: OperationRecord,
        at date: Date,
        reason: String,
        verificationFailure: Bool,
        runInverse: Bool,
        verifyRolledBackState: @escaping @Sendable () async -> Bool
    ) async -> OperationRecord {
        var failures: [String] = []
        if runInverse, spec.action == .add {
            let inverse = RemoteMCPOperationSpec(
                envelopeVersion: spec.envelopeVersion,
                agent: spec.agent,
                action: .remove,
                serverName: spec.serverName,
                scope: spec.scope,
                executablePath: spec.executablePath,
                configurationState: spec.configurationState,
                remoteBackupPath: spec.remoteBackupPath,
                expectedBeforeConfigured: true,
                expectedAfterConfigured: false
            )
            do {
                let result = try await session.execute(
                    commandRequest(for: inverse)
                )
                if !result.succeeded {
                    failures.append(commandFailure(result))
                }
            } catch {
                failures.append(
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
                    "KITROOM_REMOTE_MCP_V1|RESTORED"
                ) {
                failures.append(commandFailure(restore))
            }
        } catch {
            failures.append(
                SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
        guard failures.isEmpty,
              await verifyRolledBackState() else {
            let detail = failures.isEmpty
                ? "Fresh inventory did not confirm rollback."
                : failures.joined(separator: " ")
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
            message: "\(reason) Configuration was restored and fresh inventory confirms the original MCP state.",
            backupPath: spec.remoteBackupPath,
            rollbackState: .succeeded,
            failure: reason
        )
    }

    private func makeSpec(
        planID: UUID,
        action: NativeMCPAction,
        serverName: String,
        serverURL: String?,
        executablePath: String,
        configurationState: NativePluginConfigurationState,
        remoteHomeDirectory: String
    ) throws -> RemoteMCPOperationSpec {
        try validateRemotePath(remoteHomeDirectory)
        guard let configurationName = RemotePOSIXPath.lastComponent(
            configurationState.path
        ), let backupPath = RemotePOSIXPath.appending(
            relativePath:
                ".kitroom/backups/\(planID.uuidString)/\(configurationName)",
            to: remoteHomeDirectory
        ) else {
            throw RemoteMCPOperationError.invalidRemotePath
        }
        return RemoteMCPOperationSpec(
            envelopeVersion: Self.envelopeVersion,
            agent: .codex,
            action: action,
            serverName: serverName,
            serverURL: serverURL,
            scope: .user,
            executablePath: executablePath,
            configurationState: configurationState,
            remoteBackupPath: backupPath,
            expectedBeforeConfigured: action == .remove,
            expectedAfterConfigured: action == .add
        )
    }

    private func makePlan(
        planID: UUID,
        host: ManagedHost,
        hostIdentity: HostIdentityEvidence,
        agentVersion: String,
        spec: RemoteMCPOperationSpec,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) -> OperationPlan {
        let isAdd = spec.action == .add
        let command = ([spec.executablePath] + commandArguments(for: spec))
            .map(Self.displayQuoted)
            .joined(separator: " ")
        return OperationPlan(
            id: planID,
            kind: isAdd ? .install : .uninstall,
            risk: .medium,
            hostID: host.id,
            hostIdentity: hostIdentity.value,
            agent: .codex,
            agentVersion: agentVersion,
            extensionID: "mcp:\(spec.serverName)",
            scope: .user,
            sourceReference: spec.serverURL,
            contentDigest: spec.configurationState.contentDigest,
            basedOnSnapshotAt: basedOnSnapshotAt,
            changes: [
                PlannedChange(
                    summary: spec.configurationState.contentDigest == nil
                        ? "Confirm remote Codex configuration is absent"
                        : "Capture remote Codex configuration",
                    target: spec.configurationState.path,
                    commandPreview: "Kitroom remote envelope v\(Self.envelopeVersion) verifies the bound digest and writes the exact backup \(spec.remoteBackupPath).",
                    rollback: spec.configurationState.contentDigest == nil
                        ? "Remove only the exact configuration file if the native command creates it."
                        : "Atomically restore the digest-verified remote backup."
                ),
                PlannedChange(
                    summary: "\(isAdd ? "Add" : "Remove") Codex MCP server \(spec.serverName) on the SSH host",
                    target: "Codex user MCP configuration",
                    commandPreview: command,
                    rollback: isAdd
                        ? "Run the exact native remove command and restore captured configuration."
                        : "Restore captured configuration and verify the server is reported again."
                )
            ],
            warnings: [
                isAdd
                    ? "An MCP server can receive prompts and tool input when Codex uses it."
                    : "Removing this server makes its tools unavailable to future Codex sessions.",
                "Connection loss is treated as unknown until fresh inventory proves the resulting state."
            ],
            verificationSteps: [
                "Re-check the stable remote-host identity and Codex version.",
                "Confirm the configuration digest still matches this plan.",
                "Run fresh Codex inventory and confirm \(spec.serverName) is \(isAdd ? "configured" : "absent")."
            ],
            execution: .remoteMCP(spec),
            createdAt: createdAt
        )
    }

    private func validatePlanningContext(
        host: ManagedHost,
        hostIdentity: HostIdentityEvidence,
        agentVersion: String,
        executablePath: String,
        session: any HostSession
    ) throws {
        guard host.connection.isRemote,
              session.host.id == host.id,
              session.host.connection.isRemote else {
            throw RemoteMCPOperationError.remoteHostRequired
        }
        guard hostIdentity.kind != .derived,
              !hostIdentity.value.isEmpty else {
            throw RemoteMCPOperationError.stableHostIdentityRequired
        }
        guard !agentVersion.isEmpty else {
            throw RemoteMCPOperationError.agentVersionRequired
        }
        try validateExecutable(executablePath)
    }

    private func validate(_ spec: RemoteMCPOperationSpec) throws {
        guard spec.envelopeVersion == Self.envelopeVersion,
              spec.agent == .codex,
              spec.scope == .user else {
            throw RemoteMCPOperationError.invalidPlan
        }
        try validateName(spec.serverName)
        try validateExecutable(spec.executablePath)
        try validateRemotePath(spec.configurationState.path)
        try validateRemotePath(spec.remoteBackupPath)
        switch spec.action {
        case .add:
            guard let url = spec.serverURL,
                  !spec.expectedBeforeConfigured,
                  spec.expectedAfterConfigured else {
                throw RemoteMCPOperationError.invalidPlan
            }
            try validateHTTPSURL(url)
        case .remove:
            guard spec.serverURL == nil,
                  spec.expectedBeforeConfigured,
                  !spec.expectedAfterConfigured else {
                throw RemoteMCPOperationError.invalidPlan
            }
        }
    }

    private func inspectConfiguration(
        path: String,
        session: any HostSession
    ) async throws -> NativePluginConfigurationState {
        try validateRemotePath(path)
        let result = try await session.execute(
            CommandRequest(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    Self.inspectEnvelope,
                    "kitroom-remote-mcp-v1",
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
                throw RemoteMCPOperationError.configurationTooLarge
            }
            if result.exitCode == 41 || result.exitCode == 42 {
                throw RemoteMCPOperationError.unsafeConfiguration
            }
            throw RemoteMCPOperationError.configurationProbeFailed
        }
        let output = result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if output == "KITROOM_REMOTE_MCP_V1|ABSENT" {
            return NativePluginConfigurationState(
                path: path,
                contentDigest: nil
            )
        }
        let prefix = "KITROOM_REMOTE_MCP_V1|PRESENT|"
        guard output.hasPrefix(prefix) else {
            throw RemoteMCPOperationError.configurationProbeFailed
        }
        let digest = String(output.dropFirst(prefix.count))
        guard digest.count == 64,
              digest.unicodeScalars.allSatisfy({
                  CharacterSet(
                      charactersIn: "0123456789abcdef"
                  ).contains($0)
              }) else {
            throw RemoteMCPOperationError.configurationProbeFailed
        }
        return NativePluginConfigurationState(
            path: path,
            contentDigest: digest
        )
    }

    private func captureRequest(
        spec: RemoteMCPOperationSpec
    ) -> CommandRequest {
        CommandRequest(
            executable: "/bin/sh",
            arguments: [
                "-c",
                Self.captureEnvelope,
                "kitroom-remote-mcp-v1",
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
        spec: RemoteMCPOperationSpec
    ) -> CommandRequest {
        CommandRequest(
            executable: "/bin/sh",
            arguments: [
                "-c",
                Self.restoreEnvelope,
                "kitroom-remote-mcp-v1",
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
        for spec: RemoteMCPOperationSpec
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
        for spec: RemoteMCPOperationSpec
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

    private func validateName(_ name: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard !name.isEmpty,
              name.count <= 128,
              !name.hasPrefix("-"),
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RemoteMCPOperationError.invalidName
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
            throw RemoteMCPOperationError.invalidURL
        }
    }

    private func validateExecutable(_ path: String) throws {
        guard RemotePOSIXPath.lastComponent(path) != nil else {
            throw RemoteMCPOperationError.invalidExecutable
        }
    }

    private func validateRemotePath(_ value: String) throws {
        guard RemotePOSIXPath.isNormalizedAbsolute(value) else {
            throw RemoteMCPOperationError.invalidRemotePath
        }
    }

    private func commandFailure(_ result: CommandResult) -> String {
        let detail = result.standardError
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SensitiveValueRedactor.redact(
            detail.isEmpty
                ? "The remote MCP command did not complete."
                : "The remote MCP command failed: \(detail)"
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
      printf 'KITROOM_REMOTE_MCP_V1|PRESENT|%s\n' "$digest"
    elif [ -e "$path" ]; then
      exit 42
    else
      printf 'KITROOM_REMOTE_MCP_V1|ABSENT\n'
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
    printf 'KITROOM_REMOTE_MCP_V1|CAPTURED\n'
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
    printf 'KITROOM_REMOTE_MCP_V1|RESTORED\n'
    """#
}
