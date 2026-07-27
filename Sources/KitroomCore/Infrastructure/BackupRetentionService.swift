import Darwin
import Foundation

public enum BackupRetentionError: LocalizedError, Equatable, Sendable {
    case noRetainedBackup
    case operationNotTerminal
    case rollbackEvidenceRequired
    case remoteBackupUnsupported
    case pathOutsideBackupRoot
    case invalidOperationDirectory
    case backupUnavailable

    public var errorDescription: String? {
        switch self {
        case .noRetainedBackup:
            "This operation has no retained backup."
        case .operationNotTerminal:
            "A backup cannot be deleted while its operation is active."
        case .rollbackEvidenceRequired:
            "This backup is still required because rollback has not been proven safe."
        case .remoteBackupUnsupported:
            "Remote backup deletion is not implemented. Kitroom will not issue an unreviewed remote delete."
        case .pathOutsideBackupRoot:
            "The recorded backup is outside Kitroom's verified local backup root."
        case .invalidOperationDirectory:
            "The retained backup does not match the exact operation directory."
        case .backupUnavailable:
            "The retained backup is missing or cannot be inspected safely."
        }
    }
}

public actor BackupRetentionService {
    private let backupRoot: URL

    public init(backupRoot: URL) {
        self.backupRoot = VerifiedDirectoryTree.normalizedURL(backupRoot)
    }

    public static func live() throws -> BackupRetentionService {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return BackupRetentionService(
            backupRoot: applicationSupport
                .appendingPathComponent("Kitroom", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true)
        )
    }

    public nonisolated static func canDelete(
        _ record: OperationRecord
    ) -> Bool {
        guard record.state.isTerminal,
              record.backupPath != nil,
              record.backupDeletedAt == nil,
              isLocalExecution(record.plan.execution) else {
            return false
        }
        switch record.state {
        case .completed:
            return record.rollbackState == .available
                || record.rollbackState == .notRequired
        case .rolledBack, .verificationFailed:
            return record.rollbackState == .succeeded
        case .failed, .invalidated, .draft, .planned, .awaitingApproval,
                .applying, .verifying:
            return false
        }
    }

    public func deleteBackup(
        for record: OperationRecord,
        at date: Date
    ) throws -> OperationRecord {
        guard record.backupPath != nil,
              record.backupDeletedAt == nil else {
            throw BackupRetentionError.noRetainedBackup
        }
        guard record.state.isTerminal else {
            throw BackupRetentionError.operationNotTerminal
        }
        guard Self.isLocalExecution(record.plan.execution) else {
            throw BackupRetentionError.remoteBackupUnsupported
        }
        guard Self.canDelete(record) else {
            throw BackupRetentionError.rollbackEvidenceRequired
        }
        let expectedDirectory = backupRoot.appendingPathComponent(
            record.id.uuidString,
            isDirectory: true
        )
        guard expectedDirectory.deletingLastPathComponent().path
                == backupRoot.path else {
            throw BackupRetentionError.invalidOperationDirectory
        }
        guard let recordedPath = record.backupPath else {
            throw BackupRetentionError.noRetainedBackup
        }
        let recordedURL = VerifiedDirectoryTree.normalizedURL(
            URL(fileURLWithPath: recordedPath)
        )
        guard recordedURL == expectedDirectory
                || recordedURL.path.hasPrefix(
                    expectedDirectory.path + "/"
                ) else {
            throw BackupRetentionError.pathOutsideBackupRoot
        }
        do {
            try VerifiedDirectoryTree.removeChildDirectory(
                named: record.id.uuidString,
                beneath: backupRoot
            )
        } catch {
            throw BackupRetentionError.backupUnavailable
        }
        guard !FileManager.default.fileExists(
            atPath: expectedDirectory.path
        ) else {
            throw BackupRetentionError.backupUnavailable
        }
        return record.deletingRetainedBackup(at: date)
    }

    private nonisolated static func isLocalExecution(
        _ execution: OperationExecutionSpec?
    ) -> Bool {
        switch execution {
        case .localSkill, .nativePlugin, .nativeMCP:
            true
        case .remoteSkill, .remotePlugin, .remoteMCP, nil:
            false
        }
    }
}

enum VerifiedDirectoryTreeError: Error {
    case unavailable
    case unsafePath
    case alreadyExists
}

enum VerifiedDirectoryTree {
    static func normalizedURL(_ url: URL) -> URL {
        let path = URL(fileURLWithPath: url.path)
            .standardized
            .path
        let normalized: String
        if path == "/var" || path.hasPrefix("/var/") {
            normalized = "/private" + path
        } else if path == "/tmp" || path.hasPrefix("/tmp/") {
            normalized = "/private" + path
        } else if path == "/etc" || path.hasPrefix("/etc/") {
            normalized = "/private" + path
        } else {
            normalized = path
        }
        return URL(fileURLWithPath: normalized, isDirectory: true)
    }

    static func createDirectoryHierarchy(
        at url: URL
    ) throws -> URL {
        let normalized = normalizedURL(url)
        let descriptor = try openDirectoryChain(
            normalized,
            createMissing: true
        )
        guard Darwin.fchmod(descriptor, 0o700) == 0 else {
            Darwin.close(descriptor)
            throw VerifiedDirectoryTreeError.unavailable
        }
        Darwin.close(descriptor)
        return normalized
    }

    static func createChildDirectory(
        named name: String,
        beneath root: URL
    ) throws -> URL {
        try validateComponent(name)
        let normalizedRoot = try createDirectoryHierarchy(at: root)
        let rootDescriptor = try openDirectoryChain(
            normalizedRoot,
            createMissing: false
        )
        defer {
            Darwin.close(rootDescriptor)
        }
        let result = name.withCString {
            Darwin.mkdirat(rootDescriptor, $0, 0o700)
        }
        guard result == 0 else {
            throw errno == EEXIST
                ? VerifiedDirectoryTreeError.alreadyExists
                : VerifiedDirectoryTreeError.unavailable
        }
        let childDescriptor = name.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard childDescriptor >= 0 else {
            throw VerifiedDirectoryTreeError.unsafePath
        }
        defer {
            Darwin.close(childDescriptor)
        }
        guard Darwin.fchmod(childDescriptor, 0o700) == 0 else {
            throw VerifiedDirectoryTreeError.unavailable
        }
        return normalizedRoot.appendingPathComponent(
            name,
            isDirectory: true
        )
    }

    static func removeChildDirectory(
        named name: String,
        beneath root: URL
    ) throws {
        try validateComponent(name)
        let rootDescriptor = try openDirectoryChain(
            normalizedURL(root),
            createMissing: false
        )
        defer {
            Darwin.close(rootDescriptor)
        }
        let childDescriptor = name.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard childDescriptor >= 0 else {
            throw VerifiedDirectoryTreeError.unsafePath
        }
        do {
            try removeContents(of: childDescriptor)
            Darwin.close(childDescriptor)
        } catch {
            Darwin.close(childDescriptor)
            throw error
        }
        let result = name.withCString {
            Darwin.unlinkat(rootDescriptor, $0, AT_REMOVEDIR)
        }
        guard result == 0 else {
            throw VerifiedDirectoryTreeError.unavailable
        }
    }

    private static func openDirectoryChain(
        _ url: URL,
        createMissing: Bool
    ) throws -> Int32 {
        let normalized = normalizedURL(url)
        guard normalized.path.hasPrefix("/") else {
            throw VerifiedDirectoryTreeError.unsafePath
        }
        let components = normalized.path.split(separator: "/").map(String.init)
        var descriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw VerifiedDirectoryTreeError.unavailable
        }

        for component in components {
            do {
                try validateComponent(component)
            } catch {
                Darwin.close(descriptor)
                throw error
            }
            var next = component.withCString {
                Darwin.openat(
                    descriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            if next < 0, errno == ENOENT, createMissing {
                let created = component.withCString {
                    Darwin.mkdirat(descriptor, $0, 0o700)
                }
                guard created == 0 || errno == EEXIST else {
                    Darwin.close(descriptor)
                    throw VerifiedDirectoryTreeError.unavailable
                }
                next = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
            }
            guard next >= 0 else {
                Darwin.close(descriptor)
                throw errno == ELOOP
                    ? VerifiedDirectoryTreeError.unsafePath
                    : VerifiedDirectoryTreeError.unavailable
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }

    private static func removeContents(
        of directoryDescriptor: Int32
    ) throws {
        let duplicate = Darwin.dup(directoryDescriptor)
        guard duplicate >= 0,
              let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 {
                Darwin.close(duplicate)
            }
            throw VerifiedDirectoryTreeError.unavailable
        }
        defer {
            Darwin.closedir(stream)
        }

        errno = 0
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." {
                continue
            }

            var information = stat()
            let inspected = name.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &information,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard inspected == 0 else {
                throw VerifiedDirectoryTreeError.unavailable
            }

            if information.st_mode & S_IFMT == S_IFDIR {
                let child = name.withCString {
                    Darwin.openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard child >= 0 else {
                    throw VerifiedDirectoryTreeError.unsafePath
                }
                do {
                    try removeContents(of: child)
                    Darwin.close(child)
                } catch {
                    Darwin.close(child)
                    throw error
                }
                let removed = name.withCString {
                    Darwin.unlinkat(
                        directoryDescriptor,
                        $0,
                        AT_REMOVEDIR
                    )
                }
                guard removed == 0 else {
                    throw VerifiedDirectoryTreeError.unavailable
                }
            } else {
                let removed = name.withCString {
                    Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
                guard removed == 0 else {
                    throw VerifiedDirectoryTreeError.unavailable
                }
            }
            errno = 0
        }
        guard errno == 0 else {
            throw VerifiedDirectoryTreeError.unavailable
        }
    }

    private static func validateComponent(_ value: String) throws {
        guard !value.isEmpty,
              value != ".",
              value != "..",
              !value.utf8.contains(0),
              !value.contains("/") else {
            throw VerifiedDirectoryTreeError.unsafePath
        }
    }
}
