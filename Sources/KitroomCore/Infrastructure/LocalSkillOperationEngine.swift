import CryptoKit
import Darwin
import Foundation

public enum LocalSkillMutationFault: String, Sendable {
    case none
    case afterStaging
    case afterMutation
    case forceVerificationMismatch
}

public enum LocalSkillOperationError: LocalizedError, Equatable, Sendable {
    case localHostRequired
    case invalidSkillName
    case sourceUnavailable
    case sourceIsNotDirectory
    case missingSkillManifest
    case unsafeSymbolicLink
    case unsupportedFile
    case skillTooLarge
    case destinationRootUnavailable
    case destinationExists
    case noChangesRequired
    case targetUnavailable
    case invalidPlan

    public var errorDescription: String? {
        switch self {
        case .localHostRequired:
            "Standalone skill mutations are currently limited to the local host."
        case .invalidSkillName:
            "The skill folder name is not safe to use as an exact target."
        case .sourceUnavailable:
            "The selected skill source is unavailable."
        case .sourceIsNotDirectory:
            "The selected skill source is not a directory."
        case .missingSkillManifest:
            "The selected directory does not contain a regular SKILL.md file."
        case .unsafeSymbolicLink:
            "The skill contains a symbolic link and cannot be installed safely."
        case .unsupportedFile:
            "The skill contains a file type that Kitroom cannot copy safely."
        case .skillTooLarge:
            "The skill exceeds Kitroom's bounded file-count or size limit."
        case .destinationRootUnavailable:
            "The agent's user skill directory is unavailable."
        case .destinationExists:
            "A different skill already exists at the exact destination."
        case .noChangesRequired:
            "The requested operation would not change the target."
        case .targetUnavailable:
            "The exact installed skill target is unavailable."
        case .invalidPlan:
            "The operation plan cannot be executed by the local skill engine."
        }
    }
}

public actor LocalSkillOperationEngine {
    public static let maximumFileCount = 1_000
    public static let maximumTotalBytes: Int64 = 50 * 1_024 * 1_024

    private let backupRoot: URL
    private let injectedFault: LocalSkillMutationFault

    public init(
        backupRoot: URL,
        injectedFault: LocalSkillMutationFault = .none
    ) {
        self.backupRoot = backupRoot.standardizedFileURL
        self.injectedFault = injectedFault
    }

    public static func live(
        fileManager: FileManager = .default
    ) throws -> LocalSkillOperationEngine {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return LocalSkillOperationEngine(
            backupRoot: applicationSupport
                .appendingPathComponent("Kitroom", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true)
        )
    }

    public func planInstall(
        host: ManagedHost,
        hostIdentity: String?,
        agent: AgentKind,
        sourceDirectory: URL,
        destinationRoot: URL,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) throws -> OperationPlan {
        try requireLocal(host)
        let source = sourceDirectory.standardizedFileURL
        let root = destinationRoot.standardizedFileURL
        let skillName = source.lastPathComponent
        try validateSkillName(skillName)
        let rootExists = FileManager.default.fileExists(atPath: root.path)
        if rootExists {
            try requireDirectory(root, error: .destinationRootUnavailable)
        } else {
            try requireDirectory(
                root.deletingLastPathComponent(),
                error: .destinationRootUnavailable
            )
        }

        let sourceDigest = try inspectSkill(at: source)
        let destination = root
            .appendingPathComponent(skillName, isDirectory: true)
            .standardizedFileURL
        guard destination.deletingLastPathComponent() == root else {
            throw LocalSkillOperationError.invalidSkillName
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            let destinationDigest = try inspectSkill(at: destination)
            if destinationDigest == sourceDigest {
                throw LocalSkillOperationError.noChangesRequired
            }
            throw LocalSkillOperationError.destinationExists
        }

        let spec = LocalSkillOperationSpec(
            action: .install,
            skillName: skillName,
            sourcePath: source.path,
            destinationPath: destination.path,
            backupRoot: backupRoot.path,
            createsDestinationRoot: !rootExists,
            sourceDigest: sourceDigest
        )
        var changes: [PlannedChange] = []
        if !rootExists {
            changes.append(
                PlannedChange(
                    summary: "Create the agent's user skill directory",
                    target: root.path,
                    commandPreview: "Create one owner-only directory.",
                    rollback: "Leave the empty agent directory in place."
                )
            )
        }
        changes.append(
            PlannedChange(
                summary: "Install standalone skill \(skillName)",
                target: destination.path,
                commandPreview: "Stage, verify, and atomically rename the selected directory.",
                rollback: "Move only the installed directory into Kitroom's private backup area."
            )
        )
        return OperationPlan(
            kind: .install,
            risk: .medium,
            hostID: host.id,
            hostIdentity: hostIdentity,
            agent: agent,
            extensionID: skillName,
            scope: .user,
            sourceReference: source.path,
            contentDigest: sourceDigest,
            expectedAfterDigest: sourceDigest,
            basedOnSnapshotAt: basedOnSnapshotAt,
            changes: changes,
            warnings: [
                "Skill content is executable agent instruction. Review the selected source before approval."
            ],
            verificationSteps: [
                "Confirm the destination digest matches the approved source digest.",
                "Run a fresh \(agent.displayName) inventory scan."
            ],
            execution: .localSkill(spec),
            createdAt: createdAt
        )
    }

    public func planUninstall(
        host: ManagedHost,
        hostIdentity: String?,
        agent: AgentKind,
        skillName: String,
        destinationDirectory: URL,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) throws -> OperationPlan {
        try requireLocal(host)
        try validateSkillName(skillName)
        let destination = destinationDirectory.standardizedFileURL
        guard destination.lastPathComponent == skillName else {
            throw LocalSkillOperationError.invalidSkillName
        }
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw LocalSkillOperationError.noChangesRequired
        }
        let destinationDigest = try inspectSkill(at: destination)
        let spec = LocalSkillOperationSpec(
            action: .uninstall,
            skillName: skillName,
            destinationPath: destination.path,
            backupRoot: backupRoot.path,
            expectedDestinationDigest: destinationDigest
        )
        return OperationPlan(
            kind: .uninstall,
            risk: .high,
            hostID: host.id,
            hostIdentity: hostIdentity,
            agent: agent,
            extensionID: skillName,
            scope: .user,
            contentDigest: destinationDigest,
            expectedBeforeDigest: destinationDigest,
            basedOnSnapshotAt: basedOnSnapshotAt,
            changes: [
                PlannedChange(
                    summary: "Uninstall standalone skill \(skillName)",
                    target: destination.path,
                    commandPreview: "Move the exact installed directory into Kitroom's private backup area.",
                    rollback: "Move the captured directory back to the same exact target."
                )
            ],
            warnings: [
                "The skill will stop loading from this user-level path after verification."
            ],
            verificationSteps: [
                "Confirm the exact target is absent.",
                "Run a fresh \(agent.displayName) inventory scan."
            ],
            execution: .localSkill(spec),
            createdAt: createdAt
        )
    }

    public func planUpdate(
        host: ManagedHost,
        hostIdentity: String?,
        agent: AgentKind,
        sourceDirectory: URL,
        destinationRoot: URL,
        basedOnSnapshotAt: Date,
        createdAt: Date
    ) throws -> OperationPlan {
        try requireLocal(host)
        let source = sourceDirectory.standardizedFileURL
        let root = destinationRoot.standardizedFileURL
        let skillName = source.lastPathComponent
        try validateSkillName(skillName)
        try requireDirectory(root, error: .destinationRootUnavailable)
        let destination = root
            .appendingPathComponent(skillName, isDirectory: true)
            .standardizedFileURL
        guard destination.deletingLastPathComponent() == root else {
            throw LocalSkillOperationError.invalidSkillName
        }
        guard FileManager.default.fileExists(
            atPath: destination.path
        ) else {
            throw LocalSkillOperationError.targetUnavailable
        }
        let sourceDigest = try inspectSkill(at: source)
        let destinationDigest = try inspectSkill(at: destination)
        guard sourceDigest != destinationDigest else {
            throw LocalSkillOperationError.noChangesRequired
        }
        let spec = LocalSkillOperationSpec(
            action: .update,
            skillName: skillName,
            sourcePath: source.path,
            destinationPath: destination.path,
            backupRoot: backupRoot.path,
            sourceDigest: sourceDigest,
            expectedDestinationDigest: destinationDigest
        )
        return OperationPlan(
            kind: .update,
            risk: .high,
            hostID: host.id,
            hostIdentity: hostIdentity,
            agent: agent,
            extensionID: skillName,
            scope: .user,
            sourceReference: source.path,
            contentDigest: sourceDigest,
            expectedBeforeDigest: destinationDigest,
            expectedAfterDigest: sourceDigest,
            basedOnSnapshotAt: basedOnSnapshotAt,
            changes: [
                PlannedChange(
                    summary: "Update standalone skill \(skillName)",
                    target: destination.path,
                    commandPreview: "Stage and digest the selected directory, atomically exchange it with the exact target, then retain the previous content in Kitroom's private backup area.",
                    rollback: "Atomically exchange the captured previous content back into the same exact target."
                )
            ],
            warnings: [
                "Skill content is executable agent instruction. Review the selected source and both digests before approval."
            ],
            verificationSteps: [
                "Confirm the target digest matches the approved new digest.",
                "Run a fresh \(agent.displayName) inventory scan."
            ],
            execution: .localSkill(spec),
            createdAt: createdAt
        )
    }

    public func apply(
        plan: OperationPlan,
        approval: OperationApproval,
        preflight: OperationPreflight,
        now: Date,
        verifyEffectiveState: @escaping @Sendable () async -> Bool = {
            true
        }
    ) async -> OperationRecord {
        var record = OperationRecord(
            plan: plan,
            state: .awaitingApproval,
            updatedAt: now,
            events: [
                OperationEvent(
                    state: .planned,
                    occurredAt: plan.createdAt,
                    message: "The immutable operation plan was created."
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
                message: "Current inventory no longer matches the approved plan baseline.",
                failure: "Inventory changed after planning."
            )
        }
        guard case let .localSkill(spec) = plan.execution else {
            return record.transitioned(
                to: .invalidated,
                at: now,
                message: "The plan has no supported local skill execution specification.",
                failure: LocalSkillOperationError.invalidPlan.localizedDescription
            )
        }

        record = record.transitioned(
            to: .applying,
            at: now,
            message: "Approval validated. Applying the exact planned change."
        )
        do {
            switch spec.action {
            case .install:
                return try await applyInstall(
                    spec: spec,
                    record: record,
                    at: now,
                    verifyEffectiveState: verifyEffectiveState
                )
            case .update:
                return try await applyUpdate(
                    spec: spec,
                    record: record,
                    at: now,
                    verifyEffectiveState: verifyEffectiveState
                )
            case .uninstall:
                return try await applyUninstall(
                    spec: spec,
                    record: record,
                    at: now,
                    verifyEffectiveState: verifyEffectiveState
                )
            }
        } catch {
            return record.transitioned(
                to: .failed,
                at: now,
                message: "The planned change could not be applied.",
                failure: SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
    }

    public func digestOfSkill(at directory: URL) throws -> String {
        try inspectSkill(at: directory.standardizedFileURL)
    }

    private func applyInstall(
        spec: LocalSkillOperationSpec,
        record: OperationRecord,
        at date: Date,
        verifyEffectiveState: @escaping @Sendable () async -> Bool
    ) async throws -> OperationRecord {
        guard let sourcePath = spec.sourcePath,
              let expectedDigest = spec.sourceDigest
        else {
            throw LocalSkillOperationError.invalidPlan
        }
        let fileManager = FileManager.default
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let destination = URL(
            fileURLWithPath: spec.destinationPath
        ).standardizedFileURL
        let destinationRoot = destination.deletingLastPathComponent()
        guard try inspectSkill(at: source) == expectedDigest else {
            return record.transitioned(
                to: .invalidated,
                at: date,
                message: "The selected source changed after the plan was created.",
                failure: "Source digest changed."
            )
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            return record.transitioned(
                to: .invalidated,
                at: date,
                message: "The exact destination changed after planning.",
                failure: "Destination is no longer absent."
            )
        }
        let rootExists = fileManager.fileExists(
            atPath: destinationRoot.path
        )
        guard rootExists != spec.createsDestinationRoot else {
            return record.transitioned(
                to: .invalidated,
                at: date,
                message: "The destination root changed after planning.",
                failure: "Destination root state changed."
            )
        }
        if rootExists {
            try requireDirectory(
                destinationRoot,
                error: .destinationRootUnavailable
            )
        } else {
            try requireDirectory(
                destinationRoot.deletingLastPathComponent(),
                error: .destinationRootUnavailable
            )
            try fileManager.createDirectory(
                at: destinationRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try setPrivateDirectoryPermissions(destinationRoot)
        }

        let staging = destinationRoot.appendingPathComponent(
            ".\(spec.skillName).kitroom-stage-\(record.id.uuidString)",
            isDirectory: true
        )
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }
        try fileManager.copyItem(at: source, to: staging)
        try setPrivateDirectoryPermissions(staging)
        guard try inspectSkill(at: staging) == expectedDigest else {
            throw LocalSkillOperationError.sourceUnavailable
        }
        if injectedFault == .afterStaging {
            throw CocoaError(.fileWriteUnknown)
        }

        try fileManager.moveItem(at: staging, to: destination)
        if injectedFault == .afterMutation {
            return rollbackInstalledSkill(
                destination: destination,
                record: record,
                at: date,
                reason: "An injected interruption occurred after the atomic rename.",
                verificationFailure: false
            )
        }

        let verifying = record.transitioned(
            to: .verifying,
            at: date,
            message: "The change was applied. Verifying the installed content digest."
        )
        let actualDigest: String
        do {
            actualDigest = try inspectSkill(at: destination)
        } catch {
            return rollbackInstalledSkill(
                destination: destination,
                record: verifying,
                at: date,
                reason: "The installed content could not be verified.",
                verificationFailure: true
            )
        }
        if injectedFault == .forceVerificationMismatch
            || actualDigest != expectedDigest {
            return rollbackInstalledSkill(
                destination: destination,
                record: verifying,
                at: date,
                reason: "Installed content did not match the approved digest.",
                verificationFailure: true
            )
        }
        guard await verifyEffectiveState() else {
            return rollbackInstalledSkill(
                destination: destination,
                record: verifying,
                at: date,
                reason: "Fresh agent inventory did not confirm the installed skill.",
                verificationFailure: true
            )
        }
        return verifying.transitioned(
            to: .completed,
            at: date,
            message: "The installed skill matches the approved content digest.",
            verificationDigest: actualDigest
        )
    }

    private func applyUninstall(
        spec: LocalSkillOperationSpec,
        record: OperationRecord,
        at date: Date,
        verifyEffectiveState: @escaping @Sendable () async -> Bool
    ) async throws -> OperationRecord {
        guard let expectedDigest = spec.expectedDestinationDigest else {
            throw LocalSkillOperationError.invalidPlan
        }
        let fileManager = FileManager.default
        let destination = URL(
            fileURLWithPath: spec.destinationPath
        ).standardizedFileURL
        guard fileManager.fileExists(atPath: destination.path) else {
            return record.transitioned(
                to: .invalidated,
                at: date,
                message: "The exact target was already absent before apply.",
                failure: "Target state changed after planning."
            )
        }
        guard try inspectSkill(at: destination) == expectedDigest else {
            return record.transitioned(
                to: .invalidated,
                at: date,
                message: "The exact target changed after the plan was created.",
                failure: "Target digest changed."
            )
        }

        let backup = try operationBackupDirectory(for: record.id)
        let capturedContent = backup.appendingPathComponent(
            "content",
            isDirectory: true
        )
        try fileManager.moveItem(at: destination, to: capturedContent)
        try setPrivateDirectoryPermissions(backup)

        if injectedFault == .afterMutation {
            return rollbackUninstalledSkill(
                capturedContent: capturedContent,
                destination: destination,
                record: record,
                at: date,
                reason: "An interruption occurred after the target was moved."
            )
        }

        var verifying = record.transitioned(
            to: .verifying,
            at: date,
            message: "The exact target was moved into a private backup. Verifying its absence.",
            backupPath: capturedContent.path,
            rollbackState: .available
        )
        if injectedFault == .forceVerificationMismatch
            || fileManager.fileExists(atPath: destination.path) {
            verifying = rollbackUninstalledSkill(
                capturedContent: capturedContent,
                destination: destination,
                record: verifying,
                at: date,
                reason: "The target remained present after the uninstall step.",
                verificationFailure: true
            )
            return verifying
        }
        guard await verifyEffectiveState() else {
            return rollbackUninstalledSkill(
                capturedContent: capturedContent,
                destination: destination,
                record: verifying,
                at: date,
                reason: "Fresh agent inventory still reported the uninstalled skill.",
                verificationFailure: true
            )
        }
        return verifying.transitioned(
            to: .completed,
            at: date,
            message: "The exact target is absent and a recoverable backup remains.",
            backupPath: capturedContent.path,
            rollbackState: .available,
            verificationDigest: expectedDigest
        )
    }

    private func applyUpdate(
        spec: LocalSkillOperationSpec,
        record: OperationRecord,
        at date: Date,
        verifyEffectiveState: @escaping @Sendable () async -> Bool
    ) async throws -> OperationRecord {
        guard let sourcePath = spec.sourcePath,
              let newDigest = spec.sourceDigest,
              let previousDigest = spec.expectedDestinationDigest else {
            throw LocalSkillOperationError.invalidPlan
        }
        let fileManager = FileManager.default
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let destination = URL(
            fileURLWithPath: spec.destinationPath
        ).standardizedFileURL
        guard try inspectSkill(at: source) == newDigest else {
            return record.transitioned(
                to: .invalidated,
                at: date,
                message: "The selected update source changed after planning.",
                failure: "Source digest changed."
            )
        }
        guard fileManager.fileExists(atPath: destination.path),
              try inspectSkill(at: destination) == previousDigest else {
            return record.transitioned(
                to: .invalidated,
                at: date,
                message: "The installed skill changed after planning.",
                failure: "Target digest changed."
            )
        }

        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(spec.skillName).kitroom-stage-\(record.id.uuidString)",
                isDirectory: true
            )
        defer {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
        }
        try fileManager.copyItem(at: source, to: staging)
        try setPrivateDirectoryPermissions(staging)
        guard try inspectSkill(at: staging) == newDigest else {
            throw LocalSkillOperationError.sourceUnavailable
        }
        if injectedFault == .afterStaging {
            throw CocoaError(.fileWriteUnknown)
        }

        let backup = try operationBackupDirectory(for: record.id)
        let capturedContent = backup.appendingPathComponent(
            "previous-content",
            isDirectory: true
        )
        try atomicSwap(staging, destination)
        do {
            try fileManager.moveItem(
                at: staging,
                to: capturedContent
            )
            try setPrivateDirectoryPermissions(backup)
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                try? atomicSwap(staging, destination)
            }
            throw error
        }

        if injectedFault == .afterMutation {
            return rollbackUpdatedSkill(
                capturedContent: capturedContent,
                destination: destination,
                record: record,
                at: date,
                reason: "An interruption occurred after the atomic update."
            )
        }

        let verifying = record.transitioned(
            to: .verifying,
            at: date,
            message: "The skill was atomically exchanged. Verifying the approved new digest.",
            backupPath: capturedContent.path,
            rollbackState: .available
        )
        let actualDigest: String
        do {
            actualDigest = try inspectSkill(at: destination)
        } catch {
            return rollbackUpdatedSkill(
                capturedContent: capturedContent,
                destination: destination,
                record: verifying,
                at: date,
                reason: "The updated skill could not be verified.",
                verificationFailure: true
            )
        }
        if injectedFault == .forceVerificationMismatch
            || actualDigest != newDigest {
            return rollbackUpdatedSkill(
                capturedContent: capturedContent,
                destination: destination,
                record: verifying,
                at: date,
                reason: "Updated content did not match the approved digest.",
                verificationFailure: true
            )
        }
        guard await verifyEffectiveState() else {
            return rollbackUpdatedSkill(
                capturedContent: capturedContent,
                destination: destination,
                record: verifying,
                at: date,
                reason: "Fresh agent inventory did not confirm the updated skill.",
                verificationFailure: true
            )
        }
        return verifying.transitioned(
            to: .completed,
            at: date,
            message: "The updated skill matches the approved content digest.",
            backupPath: capturedContent.path,
            rollbackState: .available,
            verificationDigest: actualDigest
        )
    }

    private func rollbackInstalledSkill(
        destination: URL,
        record: OperationRecord,
        at date: Date,
        reason: String,
        verificationFailure: Bool
    ) -> OperationRecord {
        do {
            let backup = try operationBackupDirectory(for: record.id)
            let capturedContent = backup.appendingPathComponent(
                "failed-install-content",
                isDirectory: true
            )
            try FileManager.default.moveItem(
                at: destination,
                to: capturedContent
            )
            return record.transitioned(
                to: verificationFailure ? .verificationFailed : .rolledBack,
                at: date,
                message: "\(reason) The installed directory was moved into a private backup.",
                backupPath: capturedContent.path,
                rollbackState: .succeeded,
                failure: reason
            )
        } catch {
            return record.transitioned(
                to: verificationFailure ? .verificationFailed : .failed,
                at: date,
                message: "\(reason) Rollback also failed.",
                rollbackState: .failed,
                failure: SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
    }

    private func rollbackUninstalledSkill(
        capturedContent: URL,
        destination: URL,
        record: OperationRecord,
        at date: Date,
        reason: String,
        verificationFailure: Bool = false
    ) -> OperationRecord {
        do {
            try FileManager.default.moveItem(
                at: capturedContent,
                to: destination
            )
            return record.transitioned(
                to: verificationFailure ? .verificationFailed : .rolledBack,
                at: date,
                message: "\(reason) The backup was restored to the exact target.",
                rollbackState: .succeeded,
                failure: reason
            )
        } catch {
            return record.transitioned(
                to: verificationFailure ? .verificationFailed : .failed,
                at: date,
                message: "\(reason) Restoring the backup also failed.",
                backupPath: capturedContent.path,
                rollbackState: .failed,
                failure: SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
    }

    private func rollbackUpdatedSkill(
        capturedContent: URL,
        destination: URL,
        record: OperationRecord,
        at date: Date,
        reason: String,
        verificationFailure: Bool = false
    ) -> OperationRecord {
        let fileManager = FileManager.default
        let rollbackStaging = destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.lastPathComponent).kitroom-rollback-\(record.id.uuidString)",
                isDirectory: true
            )
        do {
            try fileManager.moveItem(
                at: capturedContent,
                to: rollbackStaging
            )
            do {
                try atomicSwap(rollbackStaging, destination)
            } catch {
                try? fileManager.moveItem(
                    at: rollbackStaging,
                    to: capturedContent
                )
                throw error
            }
            let failedContent = capturedContent
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "failed-update-content",
                    isDirectory: true
                )
            let retainedPath: String
            do {
                try fileManager.moveItem(
                    at: rollbackStaging,
                    to: failedContent
                )
                retainedPath = failedContent.path
            } catch {
                try? setPrivateDirectoryPermissions(rollbackStaging)
                retainedPath = rollbackStaging.path
            }
            return record.transitioned(
                to: verificationFailure ? .verificationFailed : .rolledBack,
                at: date,
                message: "\(reason) The previous content was atomically restored.",
                backupPath: retainedPath,
                rollbackState: .succeeded,
                failure: reason
            )
        } catch {
            return record.transitioned(
                to: verificationFailure ? .verificationFailed : .failed,
                at: date,
                message: "\(reason) Restoring the previous content also failed.",
                backupPath: capturedContent.path,
                rollbackState: .failed,
                failure: SensitiveValueRedactor.redact(
                    error.localizedDescription
                )
            )
        }
    }

    private func atomicSwap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
    }

    private func operationBackupDirectory(
        for planID: OperationPlan.ID
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: backupRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try setPrivateDirectoryPermissions(backupRoot)
        let directory = backupRoot.appendingPathComponent(
            planID.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try setPrivateDirectoryPermissions(directory)
        return directory
    }

    private func inspectSkill(at directory: URL) throws -> String {
        let fileManager = FileManager.default
        try requireDirectory(directory, error: .sourceIsNotDirectory)
        let rootValues = try directory.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        guard rootValues.isSymbolicLink != true else {
            throw LocalSkillOperationError.unsafeSymbolicLink
        }
        let canonicalDirectory = try canonicalURL(directory)

        let manifest = canonicalDirectory.appendingPathComponent("SKILL.md")
        let manifestValues = try? manifest.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard manifestValues?.isRegularFile == true,
              manifestValues?.isSymbolicLink != true
        else {
            throw LocalSkillOperationError.missingSkillManifest
        }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            atPath: canonicalDirectory.path
        ) else {
            throw LocalSkillOperationError.sourceUnavailable
        }

        var files: [(relativePath: String, url: URL, size: Int64)] = []
        var totalBytes: Int64 = 0
        for case let relativePath as String in enumerator {
            let url = canonicalDirectory.appendingPathComponent(relativePath)
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                throw LocalSkillOperationError.unsafeSymbolicLink
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                throw LocalSkillOperationError.unsupportedFile
            }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            files.append((relativePath, url, size))
            if files.count > Self.maximumFileCount
                || totalBytes > Self.maximumTotalBytes {
                throw LocalSkillOperationError.skillTooLarge
            }
        }

        var hasher = SHA256()
        for file in files.sorted(by: {
            $0.relativePath < $1.relativePath
        }) {
            hasher.update(data: Data(file.relativePath.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: file.url))
            hasher.update(data: Data([0xff]))
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func requireLocal(_ host: ManagedHost) throws {
        guard host.connection == .local else {
            throw LocalSkillOperationError.localHostRequired
        }
    }

    private func validateSkillName(_ name: String) throws {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
        )
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw LocalSkillOperationError.invalidSkillName
        }
    }

    private func requireDirectory(
        _ url: URL,
        error: LocalSkillOperationError
    ) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            throw error == .sourceIsNotDirectory
                ? LocalSkillOperationError.sourceUnavailable
                : error
        }
        guard isDirectory.boolValue else {
            throw error
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values.isSymbolicLink == true {
            throw LocalSkillOperationError.unsafeSymbolicLink
        }
    }

    private func setPrivateDirectoryPermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func canonicalURL(_ url: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else {
            throw LocalSkillOperationError.sourceUnavailable
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
        return URL(
            fileURLWithPath: String(decoding: bytes, as: UTF8.self)
        )
            .standardizedFileURL
    }
}
