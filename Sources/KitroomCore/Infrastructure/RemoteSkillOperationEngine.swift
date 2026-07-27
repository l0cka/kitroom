import CryptoKit
import Darwin
import Foundation

public enum RemoteSkillOperationError: LocalizedError, Equatable, Sendable {
    case remoteHostRequired
    case stableHostIdentityRequired
    case agentVersionRequired
    case invalidSkillName
    case invalidRemotePath
    case sourceUnavailable
    case sourceIsNotDirectory
    case missingSkillManifest
    case unsafeSymbolicLink
    case unsupportedFile
    case unsafeArchivePath
    case skillTooLarge
    case sourceChangedDuringRead
    case destinationUnavailable
    case destinationExists
    case remoteInspectionFailed
    case invalidPlan

    public var errorDescription: String? {
        switch self {
        case .remoteHostRequired:
            "This operation requires an SSH host."
        case .stableHostIdentityRequired:
            "A verified stable remote-host identity is required."
        case .agentVersionRequired:
            "A verified remote agent version is required."
        case .invalidSkillName:
            "The skill folder name is not safe to use as an exact target."
        case .invalidRemotePath:
            "A remote target or backup path is not a normalized absolute path."
        case .sourceUnavailable:
            "The selected local skill source is unavailable."
        case .sourceIsNotDirectory:
            "The selected skill source is not a directory."
        case .missingSkillManifest:
            "The selected directory does not contain a regular SKILL.md file."
        case .unsafeSymbolicLink:
            "The skill contains a symbolic link and cannot be transferred safely."
        case .unsupportedFile:
            "The skill contains a file type that Kitroom cannot transfer safely."
        case .unsafeArchivePath:
            "A skill path cannot be represented safely in the remote transfer envelope."
        case .skillTooLarge:
            "The skill exceeds the bounded transfer limit."
        case .sourceChangedDuringRead:
            "The selected skill changed while Kitroom was reading it."
        case .destinationUnavailable:
            "The exact remote skill destination is unavailable."
        case .destinationExists:
            "A remote skill already exists at the exact destination."
        case .remoteInspectionFailed:
            "The existing remote skill could not be inspected safely."
        case .invalidPlan:
            "The operation plan cannot be executed by the remote skill engine."
        }
    }
}

public actor RemoteSkillOperationEngine {
    public static let envelopeVersion = 1
    public static let maximumFileCount = 1_000
    public static let maximumTotalBytes: Int64 = 50 * 1_024 * 1_024
    public static let maximumArchiveBytes: Int64 =
        maximumTotalBytes
        + Int64((maximumFileCount + 2) * 1_024)
        + 1_048_576

    public init() {}

    public func planInstall(
        host: ManagedHost,
        hostIdentity: HostIdentityEvidence,
        agent: AgentKind,
        agentVersion: String,
        localSourceDirectory: URL,
        remoteDestinationRoot: String,
        remoteHomeDirectory: String,
        createsDestinationRoot: Bool,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) throws -> OperationPlan {
        guard host.connection.isRemote else {
            throw RemoteSkillOperationError.remoteHostRequired
        }
        guard hostIdentity.kind != .derived,
              !hostIdentity.value.isEmpty else {
            throw RemoteSkillOperationError.stableHostIdentityRequired
        }
        guard !agentVersion.isEmpty else {
            throw RemoteSkillOperationError.agentVersionRequired
        }
        let source = localSourceDirectory.standardizedFileURL
        let skillName = source.lastPathComponent
        try validateName(skillName)
        try validateRemotePath(remoteDestinationRoot)
        try validateRemotePath(remoteHomeDirectory)
        let archive = try RemoteSkillArchive.build(
            from: source,
            maximumFileCount: Self.maximumFileCount,
            maximumTotalBytes: Self.maximumTotalBytes
        )
        let planID = UUID()
        guard let destination = RemotePOSIXPath.appending(
            component: skillName,
            to: remoteDestinationRoot
        ), let backup = RemotePOSIXPath.appending(
            relativePath:
                ".kitroom/backups/\(planID.uuidString)/failed-install-content",
            to: remoteHomeDirectory
        ), let staging = RemotePOSIXPath.appending(
            component:
                ".\(skillName).kitroom-stage-\(planID.uuidString)",
            to: remoteDestinationRoot
        ) else {
            throw RemoteSkillOperationError.invalidRemotePath
        }
        let spec = RemoteSkillOperationSpec(
            envelopeVersion: Self.envelopeVersion,
            action: .install,
            skillName: skillName,
            localSourcePath: source.path,
            remoteDestinationPath: destination,
            remoteBackupPath: backup,
            createsDestinationRoot: createsDestinationRoot,
            sourceDigest: archive.contentDigest,
            archiveByteCount: archive.data.count
        )
        return OperationPlan(
            id: planID,
            kind: .install,
            risk: .high,
            hostID: host.id,
            hostIdentity: hostIdentity.value,
            agent: agent,
            agentVersion: agentVersion,
            extensionID: skillName,
            scope: .user,
            sourceReference: source.path,
            contentDigest: archive.contentDigest,
            expectedAfterDigest: archive.contentDigest,
            basedOnSnapshotAt: basedOnSnapshotAt,
            changes: [
                PlannedChange(
                    summary: "Stage and verify the remote skill archive",
                    target: staging,
                    commandPreview: "Stream \(archive.data.count) bytes through Kitroom remote envelope v\(Self.envelopeVersion) and verify every file against the embedded SHA-256 manifest.",
                    rollback: "The staging path stays outside the agent load path if extraction cannot complete."
                ),
                PlannedChange(
                    summary: "Install standalone skill \(skillName) on the SSH host",
                    target: destination,
                    commandPreview: "Transfer a bounded ustar archive over OpenSSH stdin to Kitroom remote envelope v\(Self.envelopeVersion), verify every file digest, then atomically rename the staging directory.",
                    rollback: "Move only the exact installed directory to \(backup)."
                )
            ],
            warnings: [
                "This changes a remote agent load path.",
                "Connection loss after apply is treated as unknown until a fresh remote inventory proves the resulting state."
            ],
            verificationSteps: [
                "Re-check the stable remote-host identity and \(agent.displayName) version.",
                "Run a fresh remote \(agent.displayName) inventory scan.",
                "Confirm the exact destination is reported."
            ],
            execution: .remoteSkill(spec),
            createdAt: createdAt
        )
    }

    public func planUpdate(
        host: ManagedHost,
        hostIdentity: HostIdentityEvidence,
        agent: AgentKind,
        agentVersion: String,
        localSourceDirectory: URL,
        remoteDestinationRoot: String,
        remoteHomeDirectory: String,
        session: any HostSession,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) async throws -> OperationPlan {
        try validatePlanningContext(
            host: host,
            hostIdentity: hostIdentity,
            agentVersion: agentVersion,
            session: session
        )
        let source = localSourceDirectory.standardizedFileURL
        let skillName = source.lastPathComponent
        try validateName(skillName)
        try validateRemotePath(remoteDestinationRoot)
        try validateRemotePath(remoteHomeDirectory)
        guard let destination = RemotePOSIXPath.appending(
            component: skillName,
            to: remoteDestinationRoot
        ) else {
            throw RemoteSkillOperationError.invalidRemotePath
        }
        let currentDigest = try await inspectRemoteSkillDigest(
            at: destination,
            session: session
        )
        let archive = try RemoteSkillArchive.build(
            from: source,
            maximumFileCount: Self.maximumFileCount,
            maximumTotalBytes: Self.maximumTotalBytes
        )
        let planID = UUID()
        guard let backup = RemotePOSIXPath.appending(
            relativePath:
                ".kitroom/backups/\(planID.uuidString)/previous-content",
            to: remoteHomeDirectory
        ) else {
            throw RemoteSkillOperationError.invalidRemotePath
        }
        let spec = RemoteSkillOperationSpec(
            envelopeVersion: Self.envelopeVersion,
            action: .update,
            skillName: skillName,
            localSourcePath: source.path,
            remoteDestinationPath: destination,
            remoteBackupPath: backup,
            createsDestinationRoot: false,
            sourceDigest: archive.contentDigest,
            archiveByteCount: archive.data.count,
            expectedDestinationDigest: currentDigest
        )
        return OperationPlan(
            id: planID,
            kind: .update,
            risk: .high,
            hostID: host.id,
            hostIdentity: hostIdentity.value,
            agent: agent,
            agentVersion: agentVersion,
            extensionID: skillName,
            scope: .user,
            sourceReference: source.path,
            contentDigest: archive.contentDigest,
            expectedBeforeDigest: currentDigest,
            expectedAfterDigest: archive.contentDigest,
            basedOnSnapshotAt: basedOnSnapshotAt,
            changes: [
                PlannedChange(
                    summary: "Stage and verify the replacement remote skill",
                    target: destination,
                    commandPreview: "Stream \(archive.data.count) digest-bound bytes through Kitroom remote envelope v\(Self.envelopeVersion).",
                    rollback: "Keep the existing skill in the exact backup \(backup)."
                ),
                PlannedChange(
                    summary: "Replace remote standalone skill \(skillName)",
                    target: destination,
                    commandPreview: "Verify the existing tree digest, move it to the private backup, then rename the verified stage into the load path.",
                    rollback: "Move failed replacement content aside and restore the exact previous directory."
                )
            ],
            warnings: [
                "This replaces code in a remote agent load path.",
                "The previous content is retained until explicitly cleaned up outside this beta."
            ],
            verificationSteps: [
                "Re-check remote identity, agent version, and the existing tree digest.",
                "Verify every staged file against the embedded SHA-256 manifest.",
                "Run fresh agent inventory and confirm the exact destination remains installed."
            ],
            execution: .remoteSkill(spec),
            createdAt: createdAt
        )
    }

    public func planUninstall(
        host: ManagedHost,
        hostIdentity: HostIdentityEvidence,
        agent: AgentKind,
        agentVersion: String,
        skillName: String,
        remoteDestinationPath: String,
        remoteHomeDirectory: String,
        session: any HostSession,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) async throws -> OperationPlan {
        try validatePlanningContext(
            host: host,
            hostIdentity: hostIdentity,
            agentVersion: agentVersion,
            session: session
        )
        try validateName(skillName)
        try validateRemotePath(remoteDestinationPath)
        try validateRemotePath(remoteHomeDirectory)
        guard RemotePOSIXPath.lastComponent(remoteDestinationPath)
                == skillName else {
            throw RemoteSkillOperationError.invalidRemotePath
        }
        let currentDigest = try await inspectRemoteSkillDigest(
            at: remoteDestinationPath,
            session: session
        )
        let planID = UUID()
        guard let backup = RemotePOSIXPath.appending(
            relativePath:
                ".kitroom/backups/\(planID.uuidString)/removed-content",
            to: remoteHomeDirectory
        ) else {
            throw RemoteSkillOperationError.invalidRemotePath
        }
        let spec = RemoteSkillOperationSpec(
            envelopeVersion: Self.envelopeVersion,
            action: .uninstall,
            skillName: skillName,
            localSourcePath: "",
            remoteDestinationPath: remoteDestinationPath,
            remoteBackupPath: backup,
            createsDestinationRoot: false,
            sourceDigest: "",
            archiveByteCount: 0,
            expectedDestinationDigest: currentDigest
        )
        return OperationPlan(
            id: planID,
            kind: .uninstall,
            risk: .medium,
            hostID: host.id,
            hostIdentity: hostIdentity.value,
            agent: agent,
            agentVersion: agentVersion,
            extensionID: skillName,
            scope: .user,
            sourceReference: remoteDestinationPath,
            contentDigest: currentDigest,
            expectedBeforeDigest: currentDigest,
            basedOnSnapshotAt: basedOnSnapshotAt,
            changes: [
                PlannedChange(
                    summary: "Uninstall remote standalone skill \(skillName)",
                    target: remoteDestinationPath,
                    commandPreview: "Verify the existing tree digest, then atomically move only this directory to \(backup).",
                    rollback: "Move the exact retained directory back into the agent load path."
                )
            ],
            warnings: [
                "This removes code from a remote agent load path.",
                "The retained remote backup is not eligible for local backup deletion."
            ],
            verificationSteps: [
                "Re-check remote identity, agent version, and existing tree digest.",
                "Run fresh agent inventory and confirm the exact destination is absent."
            ],
            execution: .remoteSkill(spec),
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
                    message: "The immutable remote skill plan was created."
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
                message: "Fresh remote state no longer matches the approved baseline.",
                failure: "Remote state changed after planning."
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
              case let .remoteSkill(spec) = plan.execution,
              spec.envelopeVersion == Self.envelopeVersion else {
            return record.transitioned(
                to: .invalidated,
                at: now,
                message: "The plan does not match this remote skill session.",
                failure: RemoteSkillOperationError.invalidPlan.localizedDescription
            )
        }

        do {
            try validate(spec)
            if let expectedDestinationDigest =
                spec.expectedDestinationDigest {
                let currentDestinationDigest: String
                do {
                    currentDestinationDigest =
                        try await inspectRemoteSkillDigest(
                            at: spec.remoteDestinationPath,
                            session: session
                        )
                } catch {
                    return record.transitioned(
                        to: .invalidated,
                        at: now,
                        message: "The exact remote destination could not be re-established before apply.",
                        failure: "Remote destination inspection failed."
                    )
                }
                guard currentDestinationDigest
                    == expectedDestinationDigest else {
                    return record.transitioned(
                        to: .invalidated,
                        at: now,
                        message: "The exact remote destination changed after planning.",
                        failure: "Remote destination digest changed."
                    )
                }
            }
            let archiveData: Data?
            if spec.action == .uninstall {
                archiveData = nil
            } else {
                let archive = try RemoteSkillArchive.build(
                    from: URL(fileURLWithPath: spec.localSourcePath),
                    maximumFileCount: Self.maximumFileCount,
                    maximumTotalBytes: Self.maximumTotalBytes
                )
                guard archive.contentDigest == spec.sourceDigest,
                      archive.data.count == spec.archiveByteCount else {
                    return record.transitioned(
                        to: .invalidated,
                        at: now,
                        message: "The selected local source or archive shape changed after planning.",
                        failure: "Source digest or archive size changed."
                    )
                }
                archiveData = archive.data
            }
            record = record.transitioned(
                to: .applying,
                at: now,
                message: applyingMessage(for: spec.action)
            )
            let result: CommandResult
            do {
                result = try await session.execute(
                    applyRequest(
                        spec: spec,
                        archive: archiveData,
                        planID: plan.id
                    )
                )
            } catch {
                return await recoverAfterUncertainApply(
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
                  !result.standardErrorWasTruncated,
                  result.standardOutput.contains(
                      "KITROOM_REMOTE_V1|APPLIED"
                  ) else {
                return await recoverAfterUncertainApply(
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
                message: "The remote envelope reported apply. Checking fresh agent inventory."
            )
            guard await verifyExpectedState() else {
                return await rollback(
                    spec: spec,
                    session: session,
                    record: verifying,
                    at: now,
                    reason: "Fresh remote inventory did not confirm the approved \(spec.action.rawValue).",
                    verificationFailure: true,
                    verifyRolledBackState: verifyRolledBackState
                )
            }
            let retainedBackup = spec.action == .install
                ? nil
                : spec.remoteBackupPath
            return verifying.transitioned(
                to: .completed,
                at: now,
                message: "Fresh remote inventory matches the approved skill \(spec.action.rawValue).",
                backupPath: retainedBackup,
                rollbackState: retainedBackup == nil ? nil : .available,
                verificationDigest: spec.action == .uninstall
                    ? spec.expectedDestinationDigest
                    : spec.sourceDigest
            )
        } catch {
            return record.transitioned(
                to: .failed,
                at: now,
                message: "The remote skill operation could not be prepared.",
                failure: SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
    }

    private func recoverAfterUncertainApply(
        spec: RemoteSkillOperationSpec,
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
                reason: "\(reason) Fresh inventory indicates the change may have applied.",
                verificationFailure: verificationFailure,
                verifyRolledBackState: verifyRolledBackState
            )
        }
        if await verifyRolledBackState() {
            return record.transitioned(
                to: .failed,
                at: date,
                message: "\(reason) Fresh inventory confirms the approved pre-change state.",
                rollbackState: .notRequired,
                failure: reason
            )
        }
        return record.transitioned(
            to: .failed,
            at: date,
            message: "\(reason) The remote outcome could not be established.",
            rollbackState: .failed,
            failure: reason
        )
    }

    private func rollback(
        spec: RemoteSkillOperationSpec,
        session: any HostSession,
        record: OperationRecord,
        at date: Date,
        reason: String,
        verificationFailure: Bool,
        verifyRolledBackState: @escaping @Sendable () async -> Bool
    ) async -> OperationRecord {
        var rollbackCommandFailure: String?
        do {
            let result = try await session.execute(
                rollbackRequest(spec: spec)
            )
            if !result.succeeded
                || !result.standardOutput.contains(
                    "KITROOM_REMOTE_V1|ROLLED_BACK"
                ) {
                rollbackCommandFailure = commandFailure(result)
            }
        } catch {
            rollbackCommandFailure = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
        }
        if await verifyRolledBackState() {
            return record.transitioned(
                to: verificationFailure ? .verificationFailed : .rolledBack,
                at: date,
                message: "\(reason) Fresh remote inventory confirms the pre-change state.",
                backupPath: spec.remoteBackupPath,
                rollbackState: .succeeded,
                failure: reason
            )
        }
        let detail = rollbackCommandFailure.map {
            " Rollback command: \($0)"
        } ?? ""
        return record.transitioned(
            to: verificationFailure ? .verificationFailed : .failed,
            at: date,
            message: "\(reason) Remote rollback could not be verified.\(detail)",
            backupPath: spec.remoteBackupPath,
            rollbackState: .failed,
            failure: "\(reason)\(detail)"
        )
    }

    private func validate(_ spec: RemoteSkillOperationSpec) throws {
        guard spec.envelopeVersion == Self.envelopeVersion else {
            throw RemoteSkillOperationError.invalidPlan
        }
        try validateName(spec.skillName)
        try validateRemotePath(spec.remoteDestinationPath)
        try validateRemotePath(spec.remoteBackupPath)
        guard spec.remoteDestinationPath.hasSuffix(
            "/" + spec.skillName
        ) else {
            throw RemoteSkillOperationError.invalidPlan
        }
        switch spec.action {
        case .install:
            guard !spec.localSourcePath.isEmpty,
                  !spec.sourceDigest.isEmpty,
                  spec.archiveByteCount > 0,
                  spec.archiveByteCount <= Int(Self.maximumArchiveBytes),
                  spec.expectedDestinationDigest == nil else {
                throw RemoteSkillOperationError.invalidPlan
            }
        case .update:
            guard !spec.localSourcePath.isEmpty,
                  !spec.sourceDigest.isEmpty,
                  spec.archiveByteCount > 0,
                  spec.archiveByteCount <= Int(Self.maximumArchiveBytes),
                  spec.expectedDestinationDigest?.isEmpty == false,
                  !spec.createsDestinationRoot else {
                throw RemoteSkillOperationError.invalidPlan
            }
        case .uninstall:
            guard spec.localSourcePath.isEmpty,
                  spec.sourceDigest.isEmpty,
                  spec.archiveByteCount == 0,
                  spec.expectedDestinationDigest?.isEmpty == false,
                  !spec.createsDestinationRoot else {
                throw RemoteSkillOperationError.invalidPlan
            }
        }
    }

    private func validateName(_ value: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard !value.isEmpty,
              value.count <= 128,
              value != ".",
              value != "..",
              !value.hasPrefix("-"),
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RemoteSkillOperationError.invalidSkillName
        }
    }

    private func validateRemotePath(_ value: String) throws {
        guard RemotePOSIXPath.isNormalizedAbsolute(value) else {
            throw RemoteSkillOperationError.invalidRemotePath
        }
    }

    private func validatePlanningContext(
        host: ManagedHost,
        hostIdentity: HostIdentityEvidence,
        agentVersion: String,
        session: any HostSession
    ) throws {
        guard host.connection.isRemote,
              session.host.id == host.id,
              session.host.connection.isRemote else {
            throw RemoteSkillOperationError.remoteHostRequired
        }
        guard hostIdentity.kind != .derived,
              !hostIdentity.value.isEmpty else {
            throw RemoteSkillOperationError.stableHostIdentityRequired
        }
        guard !agentVersion.isEmpty else {
            throw RemoteSkillOperationError.agentVersionRequired
        }
    }

    private func inspectRemoteSkillDigest(
        at path: String,
        session: any HostSession
    ) async throws -> String {
        try validateRemotePath(path)
        let result: CommandResult
        do {
            result = try await session.execute(
                CommandRequest(
                    executable: "/bin/sh",
                    arguments: [
                        "-c",
                        Self.inspectTreeEnvelope,
                        "kitroom-remote-skill-inspect-v1",
                        path,
                        String(Self.maximumFileCount),
                        String(Self.maximumTotalBytes)
                    ],
                    environment: [
                        "LC_ALL": "C",
                        "PATH": "/usr/bin:/bin"
                    ],
                    timeout: .seconds(30),
                    maximumOutputBytes: 131_072
                )
            )
        } catch {
            throw RemoteSkillOperationError.remoteInspectionFailed
        }
        guard result.succeeded,
              !result.standardOutputWasTruncated,
              !result.standardErrorWasTruncated else {
            if result.exitCode == 40 {
                throw RemoteSkillOperationError.destinationUnavailable
            }
            throw RemoteSkillOperationError.remoteInspectionFailed
        }
        let prefix = "KITROOM_REMOTE_SKILL_V1|PRESENT|"
        guard let line = result.standardOutput
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.hasPrefix(prefix) }) else {
            throw RemoteSkillOperationError.remoteInspectionFailed
        }
        let digest = String(line.dropFirst(prefix.count))
        guard digest.count == 64,
              digest.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            throw RemoteSkillOperationError.remoteInspectionFailed
        }
        return digest
    }

    private func applyRequest(
        spec: RemoteSkillOperationSpec,
        archive: Data?,
        planID: UUID
    ) -> CommandRequest {
        let envelope: String
        var arguments: [String]
        switch spec.action {
        case .install:
            envelope = Self.installEnvelope
            arguments = [
                "-c",
                envelope,
                "kitroom-remote-v1",
                spec.remoteDestinationPath,
                spec.remoteBackupPath,
                spec.createsDestinationRoot ? "1" : "0",
                planID.uuidString
            ]
        case .update:
            envelope = Self.updateEnvelope
            arguments = [
                "-c",
                envelope,
                "kitroom-remote-v1",
                spec.remoteDestinationPath,
                spec.remoteBackupPath,
                spec.expectedDestinationDigest ?? "",
                String(Self.maximumFileCount),
                String(Self.maximumTotalBytes),
                planID.uuidString
            ]
        case .uninstall:
            envelope = Self.uninstallEnvelope
            arguments = [
                "-c",
                envelope,
                "kitroom-remote-v1",
                spec.remoteDestinationPath,
                spec.remoteBackupPath,
                spec.expectedDestinationDigest ?? "",
                String(Self.maximumFileCount),
                String(Self.maximumTotalBytes)
            ]
        }
        return CommandRequest(
            executable: "/bin/sh",
            arguments: arguments,
            environment: [
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin"
            ],
            standardInput: archive,
            timeout: spec.action == .uninstall
                ? .seconds(30)
                : .seconds(90),
            maximumOutputBytes: 1_048_576
        )
    }

    private func rollbackRequest(
        spec: RemoteSkillOperationSpec
    ) -> CommandRequest {
        CommandRequest(
            executable: "/bin/sh",
            arguments: [
                "-c",
                Self.rollbackEnvelope,
                "kitroom-remote-v1",
                spec.remoteDestinationPath,
                spec.remoteBackupPath,
                spec.action.rawValue
            ],
            environment: [
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin"
            ],
            timeout: .seconds(30),
            maximumOutputBytes: 131_072
        )
    }

    private func commandFailure(_ result: CommandResult) -> String {
        let detail = result.standardError
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SensitiveValueRedactor.redact(
            detail.isEmpty
                ? "The remote envelope did not complete."
                : "The remote envelope failed: \(detail)"
        )
    }

    private func applyingMessage(for action: LocalSkillAction) -> String {
        switch action {
        case .install:
            "Fresh remote state matched. Transferring the approved archive through the fixed envelope."
        case .update:
            "Fresh remote state matched. Transferring and applying the approved replacement through the fixed envelope."
        case .uninstall:
            "Fresh remote state matched. Moving the exact approved destination into the retained remote backup."
        }
    }

    private static let installEnvelope = #"""
    set -eu
    destination=$1
    backup=$2
    create_root=$3
    plan_id=$4
    parent=${destination%/*}
    base=${destination##*/}
    grand=${parent%/*}
    stage=$parent/.$base.kitroom-stage-$plan_id
    [ ! -L "$grand" ]
    if [ "$create_root" = 1 ]; then
      [ ! -e "$parent" ]
      [ -d "$grand" ]
      mkdir -m 700 -- "$parent"
    else
      [ -d "$parent" ]
      [ ! -L "$parent" ]
    fi
    [ ! -e "$destination" ]
    [ ! -e "$stage" ]
    umask 077
    mkdir -m 700 -- "$stage"
    tar -xf - -C "$stage"
    (
      cd "$stage"
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c .kitroom-manifest.sha256 >/dev/null
      elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c .kitroom-manifest.sha256 >/dev/null
      else
        exit 42
      fi
      rm -- .kitroom-manifest.sha256
      [ -f SKILL.md ]
      [ ! -L SKILL.md ]
    )
    mv -- "$stage" "$destination"
    printf 'KITROOM_REMOTE_V1|APPLIED\n'
    """#

    private static let inspectTreeEnvelope = #"""
    set -eu
    path=$1
    maximum_entries=$2
    maximum_bytes=$3
    [ -d "$path" ] || exit 40
    [ ! -L "$path" ] || exit 41
    special=$(find "$path" ! -type f ! -type d -print -quit)
    [ -z "$special" ] || exit 42
    entries=$(find "$path" -mindepth 1 -print | wc -l | tr -d ' ')
    [ "$entries" -le "$maximum_entries" ] || exit 43
    bytes=$(find "$path" -type f -exec wc -c {} \; | awk '{total += $1} END {print total + 0}')
    [ "$bytes" -le "$maximum_bytes" ] || exit 44
    parent=${path%/*}
    base=${path##*/}
    if command -v sha256sum >/dev/null 2>&1; then
      digest=$(tar -cf - -C "$parent" "$base" | sha256sum | cut -d ' ' -f 1)
    elif command -v shasum >/dev/null 2>&1; then
      digest=$(tar -cf - -C "$parent" "$base" | shasum -a 256 | cut -d ' ' -f 1)
    else
      exit 45
    fi
    printf 'KITROOM_REMOTE_SKILL_V1|PRESENT|%s\n' "$digest"
    """#

    private static let updateEnvelope = #"""
    set -eu
    destination=$1
    backup=$2
    expected=$3
    maximum_entries=$4
    maximum_bytes=$5
    plan_id=$6
    parent=${destination%/*}
    base=${destination##*/}
    stage=$parent/.$base.kitroom-stage-$plan_id
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
    [ ! -L "$parent" ]
    [ -d "$destination" ]
    [ ! -L "$destination" ]
    [ ! -e "$backup" ]
    [ ! -e "$stage" ]
    reject_symlink_chain "$backup_dir"
    umask 077
    mkdir -m 700 -- "$stage"
    tar -xf - -C "$stage"
    (
      cd "$stage"
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c .kitroom-manifest.sha256 >/dev/null
      elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c .kitroom-manifest.sha256 >/dev/null
      else
        exit 45
      fi
      rm -- .kitroom-manifest.sha256
      [ -f SKILL.md ]
      [ ! -L SKILL.md ]
    )
    special=$(find "$destination" ! -type f ! -type d -print -quit)
    [ -z "$special" ] || exit 42
    entries=$(find "$destination" -mindepth 1 -print | wc -l | tr -d ' ')
    [ "$entries" -le "$maximum_entries" ] || exit 43
    bytes=$(find "$destination" -type f -exec wc -c {} \; | awk '{total += $1} END {print total + 0}')
    [ "$bytes" -le "$maximum_bytes" ] || exit 44
    if command -v sha256sum >/dev/null 2>&1; then
      actual=$(tar -cf - -C "$parent" "$base" | sha256sum | cut -d ' ' -f 1)
    elif command -v shasum >/dev/null 2>&1; then
      actual=$(tar -cf - -C "$parent" "$base" | shasum -a 256 | cut -d ' ' -f 1)
    else
      exit 45
    fi
    [ "$actual" = "$expected" ]
    mkdir -p -m 700 -- "$backup_dir"
    chmod 700 "$backup_dir"
    mv -- "$destination" "$backup"
    if ! mv -- "$stage" "$destination"; then
      if [ ! -e "$destination" ] && [ -d "$backup" ]; then
        mv -- "$backup" "$destination" || true
      fi
      exit 46
    fi
    printf 'KITROOM_REMOTE_V1|APPLIED\n'
    """#

    private static let uninstallEnvelope = #"""
    set -eu
    destination=$1
    backup=$2
    expected=$3
    maximum_entries=$4
    maximum_bytes=$5
    parent=${destination%/*}
    base=${destination##*/}
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
    [ ! -L "$parent" ]
    [ -d "$destination" ]
    [ ! -L "$destination" ]
    [ ! -e "$backup" ]
    reject_symlink_chain "$backup_dir"
    special=$(find "$destination" ! -type f ! -type d -print -quit)
    [ -z "$special" ] || exit 42
    entries=$(find "$destination" -mindepth 1 -print | wc -l | tr -d ' ')
    [ "$entries" -le "$maximum_entries" ] || exit 43
    bytes=$(find "$destination" -type f -exec wc -c {} \; | awk '{total += $1} END {print total + 0}')
    [ "$bytes" -le "$maximum_bytes" ] || exit 44
    if command -v sha256sum >/dev/null 2>&1; then
      actual=$(tar -cf - -C "$parent" "$base" | sha256sum | cut -d ' ' -f 1)
    elif command -v shasum >/dev/null 2>&1; then
      actual=$(tar -cf - -C "$parent" "$base" | shasum -a 256 | cut -d ' ' -f 1)
    else
      exit 45
    fi
    [ "$actual" = "$expected" ]
    umask 077
    mkdir -p -m 700 -- "$backup_dir"
    chmod 700 "$backup_dir"
    mv -- "$destination" "$backup"
    printf 'KITROOM_REMOTE_V1|APPLIED\n'
    """#

    private static let rollbackEnvelope = #"""
    set -eu
    destination=$1
    backup=$2
    action=$3
    parent=${destination%/*}
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
    [ ! -L "$parent" ]
    reject_symlink_chain "$backup_dir"
    case "$action" in
      install)
        [ -d "$destination" ]
        [ ! -L "$destination" ]
        [ ! -e "$backup" ]
        umask 077
        mkdir -p -m 700 -- "$backup_dir"
        chmod 700 "$backup_dir"
        mv -- "$destination" "$backup"
        ;;
      update)
        failed=$backup_dir/replacement-content
        [ -d "$destination" ]
        [ ! -L "$destination" ]
        [ -d "$backup" ]
        [ ! -L "$backup" ]
        [ ! -e "$failed" ]
        mv -- "$destination" "$failed"
        if ! mv -- "$backup" "$destination"; then
          if [ ! -e "$destination" ] && [ -d "$failed" ]; then
            mv -- "$failed" "$destination" || true
          fi
          exit 47
        fi
        ;;
      uninstall)
        [ ! -e "$destination" ]
        [ -d "$parent" ]
        [ -d "$backup" ]
        [ ! -L "$backup" ]
        mv -- "$backup" "$destination"
        ;;
      *)
        exit 48
        ;;
    esac
    printf 'KITROOM_REMOTE_V1|ROLLED_BACK\n'
    """#
}

private struct RemoteSkillArchive {
    let data: Data
    let contentDigest: String

    static func build(
        from source: URL,
        maximumFileCount: Int,
        maximumTotalBytes: Int64
    ) throws -> Self {
        let fileManager = FileManager.default
        let source = source.standardizedFileURL
        let rootDescriptor = source.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard rootDescriptor >= 0 else {
            if errno == ELOOP {
                throw RemoteSkillOperationError.unsafeSymbolicLink
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: source.path,
                isDirectory: &isDirectory
            ) else {
                throw RemoteSkillOperationError.sourceUnavailable
            }
            throw isDirectory.boolValue
                ? RemoteSkillOperationError.sourceUnavailable
                : RemoteSkillOperationError.sourceIsNotDirectory
        }
        defer {
            Darwin.close(rootDescriptor)
        }
        guard let enumerator = fileManager.enumerator(
            atPath: source.path
        ) else {
            throw RemoteSkillOperationError.sourceUnavailable
        }

        var directories: [String] = []
        var files: [(path: String, data: Data, digest: String)] = []
        var totalBytes: Int64 = 0
        var entryCount = 0
        for case let relativePath as String in enumerator {
            try validateArchivePath(relativePath)
            entryCount += 1
            guard entryCount <= maximumFileCount else {
                throw RemoteSkillOperationError.skillTooLarge
            }
            let url = source.appendingPathComponent(relativePath)
            let values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey
                ]
            )
            if values.isSymbolicLink == true {
                throw RemoteSkillOperationError.unsafeSymbolicLink
            }
            if values.isDirectory == true {
                try verifyDirectory(
                    relativePath,
                    beneath: rootDescriptor
                )
                directories.append(relativePath)
                continue
            }
            guard values.isRegularFile == true else {
                throw RemoteSkillOperationError.unsupportedFile
            }
            let data = try readRegularFile(
                relativePath,
                beneath: rootDescriptor,
                maximumBytes: maximumTotalBytes - totalBytes
            )
            totalBytes += Int64(data.count)
            files.append(
                (
                    relativePath,
                    data,
                    sha256(data)
                )
            )
        }
        guard files.contains(where: { $0.path == "SKILL.md" }) else {
            throw RemoteSkillOperationError.missingSkillManifest
        }

        let sortedFiles = files.sorted { $0.path < $1.path }
        let manifest = sortedFiles.map {
            "\($0.digest)  \($0.path)\n"
        }.joined()
        var archive = Data()
        for directory in directories.sorted() {
            appendTarEntry(
                name: directory + "/",
                contents: Data(),
                type: UInt8(ascii: "5"),
                to: &archive
            )
        }
        for file in sortedFiles {
            appendTarEntry(
                name: file.path,
                contents: file.data,
                type: UInt8(ascii: "0"),
                to: &archive
            )
        }
        appendTarEntry(
            name: ".kitroom-manifest.sha256",
            contents: Data(manifest.utf8),
            type: UInt8(ascii: "0"),
            to: &archive
        )
        archive.append(Data(repeating: 0, count: 1_024))

        let digestMaterial = (
            directories.map {
                "directory\u{1f}\($0)"
            }
            + sortedFiles.map {
                "file\u{1f}\($0.path)\u{1f}\($0.digest)"
            }
        )
        .sorted()
        .joined(separator: "\u{1e}")
        return Self(
            data: archive,
            contentDigest: sha256(Data(digestMaterial.utf8))
        )
    }

    private static func verifyDirectory(
        _ relativePath: String,
        beneath rootDescriptor: Int32
    ) throws {
        let descriptor = try openRelativePath(
            relativePath,
            beneath: rootDescriptor,
            finalFlags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        Darwin.close(descriptor)
    }

    private static func readRegularFile(
        _ relativePath: String,
        beneath rootDescriptor: Int32,
        maximumBytes: Int64
    ) throws -> Data {
        guard maximumBytes >= 0 else {
            throw RemoteSkillOperationError.skillTooLarge
        }
        let descriptor = try openRelativePath(
            relativePath,
            beneath: rootDescriptor,
            finalFlags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        defer {
            Darwin.close(descriptor)
        }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG else {
            throw RemoteSkillOperationError.unsupportedFile
        }
        guard before.st_size >= 0,
              before.st_size <= maximumBytes else {
            throw RemoteSkillOperationError.skillTooLarge
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remaining = maximumBytes - Int64(data.count)
            guard remaining >= 0 else {
                throw RemoteSkillOperationError.skillTooLarge
            }
            let requestCount = Int(
                min(Int64(buffer.count), remaining + 1)
            )
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(
                    descriptor,
                    $0.baseAddress,
                    requestCount
                )
            }
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw RemoteSkillOperationError.sourceUnavailable
            }
            data.append(contentsOf: buffer.prefix(count))
            guard Int64(data.count) <= maximumBytes else {
                throw RemoteSkillOperationError.skillTooLarge
            }
        }

        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              Int64(data.count) == after.st_size else {
            throw RemoteSkillOperationError.sourceChangedDuringRead
        }
        return data
    }

    private static func openRelativePath(
        _ relativePath: String,
        beneath rootDescriptor: Int32,
        finalFlags: Int32
    ) throws -> Int32 {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let final = parts.last else {
            throw RemoteSkillOperationError.unsafeArchivePath
        }
        var parentDescriptor = Darwin.dup(rootDescriptor)
        guard parentDescriptor >= 0 else {
            throw RemoteSkillOperationError.sourceUnavailable
        }

        for component in parts.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            Darwin.close(parentDescriptor)
            guard nextDescriptor >= 0 else {
                if errno == ELOOP {
                    throw RemoteSkillOperationError.unsafeSymbolicLink
                }
                throw RemoteSkillOperationError.sourceChangedDuringRead
            }
            parentDescriptor = nextDescriptor
        }
        defer {
            Darwin.close(parentDescriptor)
        }

        let descriptor = final.withCString {
            Darwin.openat(parentDescriptor, $0, finalFlags)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw RemoteSkillOperationError.unsafeSymbolicLink
            }
            throw RemoteSkillOperationError.sourceChangedDuringRead
        }
        return descriptor
    }

    private static func validateArchivePath(_ value: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-"
        )
        let parts = value.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !value.isEmpty,
              value.utf8.count <= 99,
              !value.hasPrefix("/"),
              !value.hasPrefix("-"),
              parts.allSatisfy({
                  !$0.isEmpty
                      && $0 != "."
                      && $0 != ".."
                      && !$0.hasPrefix("-")
              }),
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw RemoteSkillOperationError.unsafeArchivePath
        }
    }

    private static func appendTarEntry(
        name: String,
        contents: Data,
        type: UInt8,
        to archive: inout Data
    ) {
        var header = Data(repeating: 0, count: 512)
        write(name, to: &header, offset: 0, length: 100)
        writeOctal(0o700, to: &header, offset: 100, length: 8)
        writeOctal(0, to: &header, offset: 108, length: 8)
        writeOctal(0, to: &header, offset: 116, length: 8)
        writeOctal(contents.count, to: &header, offset: 124, length: 12)
        writeOctal(0, to: &header, offset: 136, length: 12)
        for index in 148 ..< 156 {
            header[index] = UInt8(ascii: " ")
        }
        header[156] = type
        write("ustar", to: &header, offset: 257, length: 6)
        write("00", to: &header, offset: 263, length: 2)
        let checksum = header.reduce(0) { $0 + Int($1) }
        let checksumValue = String(format: "%06o", checksum)
        write(
            checksumValue,
            to: &header,
            offset: 148,
            length: 6
        )
        header[154] = 0
        header[155] = UInt8(ascii: " ")
        archive.append(header)
        archive.append(contents)
        let remainder = contents.count % 512
        if remainder != 0 {
            archive.append(
                Data(repeating: 0, count: 512 - remainder)
            )
        }
    }

    private static func write(
        _ value: String,
        to data: inout Data,
        offset: Int,
        length: Int
    ) {
        let bytes = Array(value.utf8.prefix(length))
        data.replaceSubrange(
            offset ..< offset + bytes.count,
            with: bytes
        )
    }

    private static func writeOctal(
        _ value: Int,
        to data: inout Data,
        offset: Int,
        length: Int
    ) {
        let text = String(
            format: "%0*o",
            length - 1,
            value
        )
        write(text, to: &data, offset: offset, length: length - 1)
        data[offset + length - 1] = 0
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
