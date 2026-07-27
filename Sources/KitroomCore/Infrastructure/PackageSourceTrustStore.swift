import Foundation

public actor PackageSourceTrustStore {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    public static func live(
        fileManager: FileManager = .default
    ) throws -> PackageSourceTrustStore {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return PackageSourceTrustStore(
            fileURL: applicationSupport
                .appendingPathComponent("Kitroom", isDirectory: true)
                .appendingPathComponent("package-source-allowlist.json")
        )
    }

    public func load() throws -> [ApprovedPackageSource] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 1_048_576 else {
            throw PackageSourceTrustError.invalidReference
        }
        return try JSONDecoder().decode(
            [ApprovedPackageSource].self,
            from: Data(contentsOf: fileURL)
        )
    }

    public func approve(
        source: CatalogSource,
        at date: Date
    ) throws -> [ApprovedPackageSource] {
        let reference = try PackageSourceTrustPolicy.validatedReference(
            for: source
        )
        var entries = try load()
        let approval = ApprovedPackageSource(
            agent: source.agent,
            reference: reference,
            approvedAt: date
        )
        entries.removeAll { $0.id == approval.id }
        entries.append(approval)
        try save(entries)
        return entries.sorted { $0.approvedAt < $1.approvedAt }
    }

    public func revoke(
        source: CatalogSource
    ) throws -> [ApprovedPackageSource] {
        let reference = try PackageSourceTrustPolicy.validatedReference(
            for: source
        )
        let id = ApprovedPackageSource.identifier(
            agent: source.agent,
            reference: reference
        )
        var entries = try load()
        entries.removeAll { $0.id == id }
        try save(entries)
        return entries.sorted { $0.approvedAt < $1.approvedAt }
    }

    private func save(
        _ entries: [ApprovedPackageSource]
    ) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
