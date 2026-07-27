import CryptoKit
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
        case .invalidPlan:
            "The operation plan cannot be executed by the remote skill engine."
        }
    }
}

public actor RemoteSkillOperationEngine {
    public static let envelopeVersion = 1
    public static let maximumFileCount = 1_000
    public static let maximumTotalBytes: Int64 = 50 * 1_024 * 1_024

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
        let destination = remoteDestinationRoot + "/" + skillName
        try validateRemotePath(destination)
        let planID = UUID()
        let backup = remoteHomeDirectory
            + "/.kitroom/backups/"
            + planID.uuidString
            + "/failed-install-content"
        try validateRemotePath(backup)
        let spec = RemoteSkillOperationSpec(
            envelopeVersion: Self.envelopeVersion,
            skillName: skillName,
            localSourcePath: source.path,
            remoteDestinationPath: destination,
            remoteBackupPath: backup,
            createsDestinationRoot: createsDestinationRoot,
            sourceDigest: archive.contentDigest,
            archiveByteCount: archive.data.count
        )
        let staging = remoteDestinationRoot
            + "/."
            + skillName
            + ".kitroom-stage-"
            + planID.uuidString
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
            let archive = try RemoteSkillArchive.build(
                from: URL(fileURLWithPath: spec.localSourcePath),
                maximumFileCount: Self.maximumFileCount,
                maximumTotalBytes: Self.maximumTotalBytes
            )
            guard archive.contentDigest == spec.sourceDigest else {
                return record.transitioned(
                    to: .invalidated,
                    at: now,
                    message: "The selected local source changed after planning.",
                    failure: "Source digest changed."
                )
            }
            record = record.transitioned(
                to: .applying,
                at: now,
                message: "Fresh remote state matched. Transferring the approved archive through the fixed envelope."
            )
            let result: CommandResult
            do {
                result = try await session.execute(
                    installRequest(
                        spec: spec,
                        archive: archive.data,
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
                    reason: "Fresh remote inventory did not confirm the approved skill.",
                    verificationFailure: true,
                    verifyRolledBackState: verifyRolledBackState
                )
            }
            return verifying.transitioned(
                to: .completed,
                at: now,
                message: "Fresh remote inventory matches the approved skill install.",
                verificationDigest: spec.sourceDigest
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
                message: "\(reason) Fresh inventory confirms the target remains absent.",
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
                message: "\(reason) Fresh remote inventory confirms the target is absent.",
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
        ), spec.archiveByteCount > 0,
           spec.archiveByteCount <= Int(Self.maximumTotalBytes) + 1_048_576
        else {
            throw RemoteSkillOperationError.invalidPlan
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
        guard value.hasPrefix("/"),
              !value.contains("\0"),
              !value.contains("\n"),
              URL(fileURLWithPath: value).standardizedFileURL.path
                == value else {
            throw RemoteSkillOperationError.invalidRemotePath
        }
    }

    private func installRequest(
        spec: RemoteSkillOperationSpec,
        archive: Data,
        planID: UUID
    ) -> CommandRequest {
        CommandRequest(
            executable: "/bin/sh",
            arguments: [
                "-c",
                Self.installEnvelope,
                "kitroom-remote-v1",
                spec.remoteDestinationPath,
                spec.remoteBackupPath,
                spec.createsDestinationRoot ? "1" : "0",
                planID.uuidString
            ],
            environment: [
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin"
            ],
            standardInput: archive,
            timeout: .seconds(90),
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
                spec.remoteBackupPath
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
    if [ "$create_root" = 1 ]; then
      [ ! -e "$parent" ]
      [ -d "$grand" ]
      mkdir -m 700 -- "$parent"
    else
      [ -d "$parent" ]
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

    private static let rollbackEnvelope = #"""
    set -eu
    destination=$1
    backup=$2
    backup_dir=${backup%/*}
    [ -d "$destination" ]
    [ ! -e "$backup" ]
    umask 077
    mkdir -p -m 700 -- "$backup_dir"
    mv -- "$destination" "$backup"
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
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: source.path,
            isDirectory: &isDirectory
        ) else {
            throw RemoteSkillOperationError.sourceUnavailable
        }
        guard isDirectory.boolValue else {
            throw RemoteSkillOperationError.sourceIsNotDirectory
        }
        let rootValues = try source.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        guard rootValues.isSymbolicLink != true else {
            throw RemoteSkillOperationError.unsafeSymbolicLink
        }
        guard let enumerator = fileManager.enumerator(
            atPath: source.path
        ) else {
            throw RemoteSkillOperationError.sourceUnavailable
        }

        var directories: [String] = []
        var files: [(path: String, data: Data, digest: String)] = []
        var totalBytes: Int64 = 0
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        for case let relativePath as String in enumerator {
            try validateArchivePath(relativePath)
            let url = source.appendingPathComponent(relativePath)
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                throw RemoteSkillOperationError.unsafeSymbolicLink
            }
            if values.isDirectory == true {
                directories.append(relativePath)
                continue
            }
            guard values.isRegularFile == true else {
                throw RemoteSkillOperationError.unsupportedFile
            }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            guard files.count + 1 <= maximumFileCount,
                  totalBytes <= maximumTotalBytes else {
                throw RemoteSkillOperationError.skillTooLarge
            }
            let data = try Data(contentsOf: url)
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

        let digestMaterial = sortedFiles.map {
            "\($0.path)\u{1f}\($0.digest)"
        }.joined(separator: "\u{1e}")
        return Self(
            data: archive,
            contentDigest: sha256(Data(digestMaterial.utf8))
        )
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
