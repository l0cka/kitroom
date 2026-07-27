import CryptoKit
import Foundation

enum InventoryIdentifier {
    static func make(_ components: String...) -> String {
        let material = components.joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct ProbeCapture: Sendable {
    let result: CommandResult?
    let evidence: EvidenceRecord
    let issue: InventoryIssue?
}

struct PathInspectionResult: Sendable {
    let isPresent: Bool?
    let evidence: [EvidenceRecord]
    let issue: InventoryIssue?
}

enum PathInventoryInspector {
    enum ExpectedKind: String, Sendable {
        case file
        case directory

        var testFlag: String {
            switch self {
            case .file:
                "-f"
            case .directory:
                "-d"
            }
        }
    }

    static func inspect(
        session: any HostSession,
        path: String,
        kind: ExpectedKind,
        name: String,
        parserVersion: String,
        capturedAt: Date,
        environment: [String: String]
    ) async -> PathInspectionResult {
        let kindProbe = await AdapterProbeRunner.run(
            session: session,
            request: CommandRequest(
                executable: "/bin/test",
                arguments: [kind.testFlag, path],
                environment: environment,
                timeout: .seconds(5),
                maximumOutputBytes: 4_096
            ),
            name: name,
            sourceReference: path,
            parserVersion: parserVersion,
            capturedAt: capturedAt
        )

        if kindProbe.result?.succeeded == true {
            return PathInspectionResult(
                isPresent: true,
                evidence: [kindProbe.evidence],
                issue: nil
            )
        }
        guard kindProbe.result != nil else {
            return PathInspectionResult(
                isPresent: nil,
                evidence: [kindProbe.evidence],
                issue: kindProbe.issue
            )
        }

        let visibilityProbe = await AdapterProbeRunner.run(
            session: session,
            request: CommandRequest(
                executable: "/bin/ls",
                arguments: ["-d", path],
                environment: environment.merging(["LC_ALL": "C"]) {
                    current, _ in current
                },
                timeout: .seconds(5),
                maximumOutputBytes: 16_384
            ),
            name: "\(name)-visibility",
            sourceReference: path,
            parserVersion: parserVersion,
            capturedAt: capturedAt
        )

        if visibilityProbe.result?.succeeded == true {
            let issue = InventoryIssue(
                summary: "\(name) has an unexpected type",
                detail: "The path exists but is not a \(kind.rawValue)."
            )
            return PathInspectionResult(
                isPresent: nil,
                evidence: [visibilityProbe.evidence],
                issue: issue
            )
        }

        let standardError = visibilityProbe.result?.standardError.lowercased() ?? ""
        if standardError.contains("no such file")
            || standardError.contains("not found") {
            return PathInspectionResult(
                isPresent: false,
                evidence: [
                    EvidenceRecord(
                        id: visibilityProbe.evidence.id,
                        probeName: name,
                        sourceReference: path,
                        capturedAt: capturedAt,
                        parserVersion: parserVersion,
                        status: .success,
                        diagnostic: "Path is absent."
                    )
                ],
                issue: nil
            )
        }

        return PathInspectionResult(
            isPresent: nil,
            evidence: [visibilityProbe.evidence],
            issue: visibilityProbe.issue
                ?? InventoryIssue(
                    summary: "\(name) could not be inspected",
                    detail: "The path's presence or type could not be established."
                )
        )
    }
}

struct ProjectDirectoryInspection: Sendable {
    let root: String?
    let hierarchy: [String]
    let evidence: [EvidenceRecord]
    let issues: [InventoryIssue]
}

enum ProjectDirectoryInspector {
    static func inspect(
        session: any HostSession,
        workingDirectory: String,
        agent: AgentKind,
        parserVersion: String,
        capturedAt: Date,
        environment: [String: String]
    ) async -> ProjectDirectoryInspection {
        guard workingDirectory.hasPrefix("/") else {
            let diagnostic = "The project directory must be an absolute path."
            return ProjectDirectoryInspection(
                root: nil,
                hierarchy: [],
                evidence: [
                    EvidenceRecord(
                        id: InventoryIdentifier.make(
                            session.host.id.uuidString,
                            agent.rawValue,
                            "project-directory",
                            workingDirectory,
                            capturedAt.ISO8601Format()
                        ),
                        probeName: "\(agent.rawValue)-project-directory",
                        sourceReference: "User-selected project directory",
                        capturedAt: capturedAt,
                        parserVersion: parserVersion,
                        status: .failure,
                        diagnostic: diagnostic
                    )
                ],
                issues: [
                    InventoryIssue(
                        summary: "Project directory is invalid",
                        detail: diagnostic
                    )
                ]
            )
        }

        let normalizedWorkingDirectory = URL(
            fileURLWithPath: workingDirectory
        ).standardized.path
        let presence = await PathInventoryInspector.inspect(
            session: session,
            path: normalizedWorkingDirectory,
            kind: .directory,
            name: "\(agent.rawValue)-project-directory",
            parserVersion: parserVersion,
            capturedAt: capturedAt,
            environment: environment
        )
        guard presence.isPresent == true else {
            return ProjectDirectoryInspection(
                root: nil,
                hierarchy: [],
                evidence: presence.evidence,
                issues: presence.issue.map { [$0] } ?? [
                    InventoryIssue(
                        summary: "Project directory is unavailable",
                        detail: "The selected directory does not exist on this host."
                    )
                ]
            )
        }

        let gitExecutable = await AdapterProbeRunner.run(
            session: session,
            request: CommandRequest(
                executable: "/usr/bin/which",
                arguments: ["git"],
                environment: environment,
                timeout: .seconds(5),
                maximumOutputBytes: 16_384
            ),
            name: "\(agent.rawValue)-git-executable",
            sourceReference: "which git",
            parserVersion: parserVersion,
            capturedAt: capturedAt
        )
        var evidence = presence.evidence + [gitExecutable.evidence]
        guard let gitResult = gitExecutable.result,
              gitResult.succeeded,
              !gitResult.standardOutputWasTruncated
        else {
            return ProjectDirectoryInspection(
                root: nil,
                hierarchy: [],
                evidence: evidence,
                issues: gitExecutable.issue.map { [$0] } ?? []
            )
        }
        let gitPath = gitResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard gitPath.hasPrefix("/") else {
            return ProjectDirectoryInspection(
                root: nil,
                hierarchy: [],
                evidence: evidence,
                issues: [
                    InventoryIssue(
                        summary: "Git executable could not be resolved",
                        detail: "Project-scope inventory is unknown."
                    )
                ]
            )
        }

        let rootProbe = await AdapterProbeRunner.run(
            session: session,
            request: CommandRequest(
                executable: gitPath,
                arguments: [
                    "-C",
                    normalizedWorkingDirectory,
                    "rev-parse",
                    "--show-toplevel"
                ],
                environment: environment,
                timeout: .seconds(10),
                maximumOutputBytes: 65_536
            ),
            name: "\(agent.rawValue)-repository-root",
            sourceReference: normalizedWorkingDirectory,
            parserVersion: parserVersion,
            capturedAt: capturedAt
        )
        evidence.append(rootProbe.evidence)
        guard let rootResult = rootProbe.result,
              rootResult.succeeded,
              !rootResult.standardOutputWasTruncated
        else {
            return ProjectDirectoryInspection(
                root: nil,
                hierarchy: [],
                evidence: evidence,
                issues: rootProbe.issue.map { [$0] } ?? []
            )
        }

        let root = URL(
            fileURLWithPath: rootResult.standardOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ).standardized.path
        let prefixProbe = await AdapterProbeRunner.run(
            session: session,
            request: CommandRequest(
                executable: gitPath,
                arguments: [
                    "-C",
                    normalizedWorkingDirectory,
                    "rev-parse",
                    "--show-prefix"
                ],
                environment: environment,
                timeout: .seconds(10),
                maximumOutputBytes: 65_536
            ),
            name: "\(agent.rawValue)-repository-prefix",
            sourceReference: normalizedWorkingDirectory,
            parserVersion: parserVersion,
            capturedAt: capturedAt
        )
        evidence.append(prefixProbe.evidence)
        guard let prefixResult = prefixProbe.result,
              prefixResult.succeeded,
              !prefixResult.standardOutputWasTruncated
        else {
            return ProjectDirectoryInspection(
                root: nil,
                hierarchy: [],
                evidence: evidence,
                issues: prefixProbe.issue.map { [$0] } ?? []
            )
        }

        let prefix = prefixResult.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !prefix.hasPrefix("/"),
              !prefix.split(separator: "/").contains("..")
        else {
            return ProjectDirectoryInspection(
                root: nil,
                hierarchy: [],
                evidence: evidence,
                issues: [
                    InventoryIssue(
                        summary: "Repository prefix is invalid",
                        detail: "Git returned an unsafe project-relative path."
                    )
                ]
            )
        }
        let resolvedWorkingDirectory = prefix.isEmpty
            ? root
            : URL(fileURLWithPath: root)
                .appendingPathComponent(prefix)
                .standardized.path

        var hierarchy = [resolvedWorkingDirectory]
        var cursor = resolvedWorkingDirectory
        while cursor != root {
            let parent = URL(fileURLWithPath: cursor)
                .deletingLastPathComponent()
                .standardized.path
            guard parent != cursor,
                  parent == root || parent.hasPrefix(root + "/")
            else {
                return ProjectDirectoryInspection(
                    root: nil,
                    hierarchy: [],
                    evidence: evidence,
                    issues: [
                        InventoryIssue(
                            summary: "Project hierarchy could not be resolved",
                            detail: "Project-scope inventory is unknown."
                        )
                    ]
                )
            }
            hierarchy.append(parent)
            cursor = parent
        }

        return ProjectDirectoryInspection(
            root: root,
            hierarchy: hierarchy.reversed(),
            evidence: evidence,
            issues: []
        )
    }
}

enum AdapterProbeRunner {
    static func run(
        session: any HostSession,
        request: CommandRequest,
        name: String,
        sourceReference: String,
        parserVersion: String,
        capturedAt: Date
    ) async -> ProbeCapture {
        let evidenceID = InventoryIdentifier.make(
            session.host.id.uuidString,
            name,
            sourceReference,
            parserVersion,
            capturedAt.ISO8601Format()
        )

        if Task.isCancelled {
            let diagnostic = "Inventory scan was cancelled."
            return ProbeCapture(
                result: nil,
                evidence: EvidenceRecord(
                    id: evidenceID,
                    probeName: name,
                    sourceReference: sourceReference,
                    capturedAt: capturedAt,
                    parserVersion: parserVersion,
                    status: .failure,
                    diagnostic: diagnostic
                ),
                issue: InventoryIssue(
                    summary: "\(name) cancelled",
                    detail: diagnostic
                )
            )
        }

        do {
            let result = try await session.execute(request)
            let truncated = result.standardOutputWasTruncated
                || result.standardErrorWasTruncated
            let succeeded = result.succeeded && !truncated
            let status: EvidenceStatus = succeeded
                ? .success
                : (result.succeeded ? .partial : .failure)
            let diagnostic: String?

            if succeeded {
                diagnostic = nil
            } else if truncated {
                diagnostic = "Probe output exceeded its configured limit."
            } else {
                diagnostic = SensitiveValueRedactor.redact(
                    "Exit \(result.exitCode.map(String.init) ?? "signal"): "
                        + result.standardError
                )
            }

            return ProbeCapture(
                result: result,
                evidence: EvidenceRecord(
                    id: evidenceID,
                    probeName: name,
                    sourceReference: sourceReference,
                    capturedAt: capturedAt,
                    parserVersion: parserVersion,
                    status: status,
                    diagnostic: diagnostic
                ),
                issue: succeeded
                    ? nil
                    : InventoryIssue(
                        summary: "\(name) did not complete",
                        detail: diagnostic ?? "The probe returned an unknown failure."
                    )
            )
        } catch {
            let diagnostic = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
            return ProbeCapture(
                result: nil,
                evidence: EvidenceRecord(
                    id: evidenceID,
                    probeName: name,
                    sourceReference: sourceReference,
                    capturedAt: capturedAt,
                    parserVersion: parserVersion,
                    status: .failure,
                    diagnostic: diagnostic
                ),
                issue: InventoryIssue(
                    summary: "\(name) failed",
                    detail: diagnostic
                )
            )
        }
    }
}

public enum SensitiveValueRedactor {
    private static let patterns: [(String, String)] = [
        (
            #"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]+"#,
            "$1 <redacted>"
        ),
        (
            #"(?i)\b(token|secret|password|passphrase|api[_-]?key|access[_-]?key|authorization)(\s*[:=]\s*)([^\s,;]+)"#,
            "$1$2<redacted>"
        ),
        (
            #"(https?://[^:/\s]+:)[^@\s]+@"#,
            "$1<redacted>@"
        ),
        (
            #"\b(sk|rk|pk)-[A-Za-z0-9_-]{12,}\b"#,
            "$1-<redacted>"
        )
    ]

    public static func redact(_ value: String) -> String {
        var result = value

        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: replacement
            )
        }

        return String(result.prefix(1_000))
    }

    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return [
            "token",
            "secret",
            "password",
            "passphrase",
            "apikey",
            "accesskey",
            "authorization",
            "privatekey",
            "clientsecret"
        ].contains { normalized.contains($0) }
    }
}

struct SkillScanResult: Sendable {
    var packages: [PackageRecord] = []
    var capabilities: [ProvidedCapability] = []
    var installations: [InstallationRecord] = []
    var evidence: [EvidenceRecord] = []
    var issues: [InventoryIssue] = []
}

enum SkillInventoryScanner {
    static func scan(
        session: any HostSession,
        agent: AgentKind,
        root: String,
        scope: InventoryScope,
        origin: InstallationOrigin,
        capturedAt: Date,
        parserVersion: String,
        environment: [String: String],
        excludedPathPrefixes: [String] = []
    ) async -> SkillScanResult {
        var inventory = SkillScanResult()
        let presence = await PathInventoryInspector.inspect(
            session: session,
            path: root,
            kind: .directory,
            name: "\(agent.rawValue)-skill-root",
            parserVersion: parserVersion,
            capturedAt: capturedAt,
            environment: environment
        )
        inventory.evidence.append(contentsOf: presence.evidence)
        guard presence.isPresent == true else {
            if let issue = presence.issue {
                inventory.issues.append(issue)
            }
            return inventory
        }

        let listing = await AdapterProbeRunner.run(
            session: session,
            request: CommandRequest(
                executable: "/usr/bin/find",
                arguments: ["-L", root, "-type", "f", "-name", "SKILL.md", "-print0"],
                environment: environment,
                timeout: .seconds(10),
                maximumOutputBytes: 1_048_576
            ),
            name: "\(agent.rawValue)-skill-list",
            sourceReference: root,
            parserVersion: parserVersion,
            capturedAt: capturedAt
        )
        inventory.evidence.append(listing.evidence)

        guard let result = listing.result,
              result.succeeded,
              listing.evidence.status == .success
        else {
            if let issue = listing.issue {
                inventory.issues.append(issue)
            }
            return inventory
        }

        let paths = result.standardOutput
            .split(separator: "\0")
            .map(String.init)
            .filter { path in
                !excludedPathPrefixes.contains { prefix in
                    path == prefix || path.hasPrefix(
                        prefix.hasSuffix("/") ? prefix : prefix + "/"
                    )
                }
            }
            .sorted()

        for path in paths {
            guard !Task.isCancelled else {
                break
            }
            let file = await AdapterProbeRunner.run(
                session: session,
                request: CommandRequest(
                    executable: "/bin/cat",
                    arguments: [path],
                    environment: environment,
                    timeout: .seconds(5),
                    maximumOutputBytes: 131_072
                ),
                name: "\(agent.rawValue)-skill-metadata",
                sourceReference: path,
                parserVersion: parserVersion,
                capturedAt: capturedAt
            )
            inventory.evidence.append(file.evidence)

            guard let content = file.result?.standardOutput,
                  file.result?.succeeded == true
            else {
                if let issue = file.issue {
                    inventory.issues.append(issue)
                }
                continue
            }

            let metadata = SkillMetadataParser.parse(
                content,
                fallbackName: URL(fileURLWithPath: path)
                    .deletingLastPathComponent()
                    .lastPathComponent
            )
            let packageID = InventoryIdentifier.make(
                agent.rawValue,
                "standalone-skill",
                path
            )
            let capabilityID = InventoryIdentifier.make(packageID, "skill", metadata.name)
            inventory.packages.append(
                PackageRecord(
                    id: packageID,
                    agent: agent,
                    name: metadata.name,
                    description: metadata.description,
                    manifestDigest: InventoryIdentifier.digest(content),
                    evidenceIDs: [file.evidence.id]
                )
            )
            inventory.capabilities.append(
                ProvidedCapability(
                    id: capabilityID,
                    agent: agent,
                    packageID: packageID,
                    kind: .skill,
                    name: metadata.name,
                    relativePath: path,
                    contentDigest: InventoryIdentifier.digest(content),
                    evidenceIDs: [file.evidence.id]
                )
            )
            inventory.installations.append(
                InstallationRecord(
                    id: InventoryIdentifier.make(
                        session.host.id.uuidString,
                        capabilityID,
                        scope.rawValue
                    ),
                    hostID: session.host.id,
                    agent: agent,
                    packageID: packageID,
                    capabilityID: capabilityID,
                    scope: scope,
                    origin: origin,
                    state: .enabled,
                    physicalOrigin: URL(fileURLWithPath: path)
                        .deletingLastPathComponent()
                        .path,
                    restriction: scope == .managed ? .administratorManaged : .userManaged,
                    evidenceIDs: [file.evidence.id]
                )
            )
        }

        return inventory
    }
}

enum LegacyCommandInventoryScanner {
    static func scan(
        session: any HostSession,
        root: String,
        capturedAt: Date,
        parserVersion: String,
        environment: [String: String],
        scope: InventoryScope = .user,
        origin: InstallationOrigin = .legacy
    ) async -> SkillScanResult {
        var inventory = SkillScanResult()
        let presence = await PathInventoryInspector.inspect(
            session: session,
            path: root,
            kind: .directory,
            name: "claude-legacy-command-root",
            parserVersion: parserVersion,
            capturedAt: capturedAt,
            environment: environment
        )
        inventory.evidence.append(contentsOf: presence.evidence)
        guard presence.isPresent == true else {
            if let issue = presence.issue {
                inventory.issues.append(issue)
            }
            return inventory
        }

        let listing = await AdapterProbeRunner.run(
            session: session,
            request: CommandRequest(
                executable: "/usr/bin/find",
                arguments: [root, "-type", "f", "-name", "*.md", "-print0"],
                environment: environment,
                timeout: .seconds(10),
                maximumOutputBytes: 1_048_576
            ),
            name: "claude-legacy-command-list",
            sourceReference: root,
            parserVersion: parserVersion,
            capturedAt: capturedAt
        )
        inventory.evidence.append(listing.evidence)
        guard let result = listing.result,
              result.succeeded,
              listing.evidence.status == .success
        else {
            if let issue = listing.issue {
                inventory.issues.append(issue)
            }
            return inventory
        }

        for path in result.standardOutput.split(separator: "\0").map(String.init).sorted() {
            let name = URL(fileURLWithPath: path)
                .deletingPathExtension()
                .lastPathComponent
            let packageID = InventoryIdentifier.make("claude", "legacy-command", path)
            let capabilityID = InventoryIdentifier.make(packageID, "skill", name)
            inventory.packages.append(
                PackageRecord(
                    id: packageID,
                    agent: .claude,
                    name: name,
                    displayName: name,
                    evidenceIDs: [listing.evidence.id]
                )
            )
            inventory.capabilities.append(
                ProvidedCapability(
                    id: capabilityID,
                    agent: .claude,
                    packageID: packageID,
                    kind: .skill,
                    name: name,
                    relativePath: path,
                    evidenceIDs: [listing.evidence.id]
                )
            )
            inventory.installations.append(
                InstallationRecord(
                    id: InventoryIdentifier.make(
                        session.host.id.uuidString,
                        capabilityID,
                        "legacy"
                    ),
                    hostID: session.host.id,
                    agent: .claude,
                    packageID: packageID,
                    capabilityID: capabilityID,
                    scope: scope,
                    origin: origin,
                    state: .enabled,
                    physicalOrigin: path,
                    restriction: .userManaged,
                    evidenceIDs: [listing.evidence.id]
                )
            )
        }

        return inventory
    }
}

private enum SkillMetadataParser {
    struct Metadata {
        let name: String
        let description: String?
    }

    static func parse(_ content: String, fallbackName: String) -> Metadata {
        let lines = content.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return Metadata(name: fallbackName, description: nil)
        }

        var name: String?
        var description: String?
        for line in lines.dropFirst() {
            let value = String(line)
            if value.trimmingCharacters(in: .whitespaces) == "---" {
                break
            }
            let fields = value.split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else {
                continue
            }
            let key = fields[0].trimmingCharacters(in: .whitespaces)
            let fieldValue = fields[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if key == "name", !fieldValue.isEmpty {
                name = fieldValue
            } else if key == "description", !fieldValue.isEmpty {
                description = fieldValue
            }
        }

        return Metadata(name: name ?? fallbackName, description: description)
    }
}

struct PluginComponentScanResult: Sendable {
    var capabilities: [ProvidedCapability] = []
    var evidence: [EvidenceRecord] = []
    var issues: [InventoryIssue] = []
}

enum PluginComponentScanner {
    static func scanInstalledPackages(
        session: any HostSession,
        agent: AgentKind,
        installations: [InstallationRecord],
        capturedAt: Date,
        parserVersion: String,
        environment: [String: String],
        maximumConcurrentScans: Int = 4
    ) async -> [
        (
            installation: InstallationRecord,
            result: PluginComponentScanResult
        )
    ] {
        let candidates = installations.filter {
            $0.packageID != nil && $0.physicalOrigin?.hasPrefix("/") == true
        }
        guard !candidates.isEmpty else {
            return []
        }
        let concurrency = max(
            1,
            min(maximumConcurrentScans, candidates.count)
        )

        return await withTaskGroup(
            of: (
                Int,
                InstallationRecord,
                PluginComponentScanResult
            ).self
        ) { group in
            var nextIndex = 0
            var results: [
                (
                    Int,
                    InstallationRecord,
                    PluginComponentScanResult
                )
            ] = []

            func addTask(at index: Int) {
                let installation = candidates[index]
                group.addTask {
                    guard !Task.isCancelled,
                          let packageID = installation.packageID,
                          let root = installation.physicalOrigin
                    else {
                        return (
                            index,
                            installation,
                            PluginComponentScanResult()
                        )
                    }
                    let result = await scan(
                        session: session,
                        agent: agent,
                        packageID: packageID,
                        root: root,
                        capturedAt: capturedAt,
                        parserVersion: parserVersion,
                        environment: environment
                    )
                    return (index, installation, result)
                }
            }

            while nextIndex < concurrency {
                addTask(at: nextIndex)
                nextIndex += 1
            }

            while let result = await group.next() {
                results.append(result)
                if nextIndex < candidates.count, !Task.isCancelled {
                    addTask(at: nextIndex)
                    nextIndex += 1
                }
            }

            return results
                .sorted { $0.0 < $1.0 }
                .map {
                    (installation: $0.1, result: $0.2)
                }
        }
    }

    static func scan(
        session: any HostSession,
        agent: AgentKind,
        packageID: String,
        root: String,
        capturedAt: Date,
        parserVersion: String,
        environment: [String: String]
    ) async -> PluginComponentScanResult {
        var inventory = PluginComponentScanResult()
        let listing = await AdapterProbeRunner.run(
            session: session,
            request: CommandRequest(
                executable: "/usr/bin/find",
                arguments: ["-L", root, "-type", "f", "-print0"],
                environment: environment,
                timeout: .seconds(10),
                maximumOutputBytes: 1_048_576
            ),
            name: "\(agent.rawValue)-plugin-components",
            sourceReference: root,
            parserVersion: parserVersion,
            capturedAt: capturedAt
        )
        inventory.evidence.append(listing.evidence)

        guard let result = listing.result, result.succeeded else {
            if let issue = listing.issue {
                inventory.issues.append(issue)
            }
            return inventory
        }

        let paths = result.standardOutput
            .split(separator: "\0")
            .map(String.init)
            .sorted()
        let parsed = await scanKnownFiles(
            session: session,
            agent: agent,
            packageID: packageID,
            root: root,
            paths: paths,
            listingEvidenceID: listing.evidence.id,
            capturedAt: capturedAt,
            parserVersion: parserVersion,
            environment: environment
        )
        inventory.capabilities.append(contentsOf: parsed.capabilities)
        inventory.evidence.append(contentsOf: parsed.evidence)
        inventory.issues.append(contentsOf: parsed.issues)
        return inventory
    }

    static func scanKnownFiles(
        session: any HostSession,
        agent: AgentKind,
        packageID: String,
        root: String,
        paths: [String],
        listingEvidenceID: EvidenceRecord.ID,
        capturedAt: Date,
        parserVersion: String,
        environment: [String: String]
    ) async -> PluginComponentScanResult {
        var inventory = PluginComponentScanResult()
        var seen = Set<String>()
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"

        for path in paths {
            guard !Task.isCancelled else {
                break
            }
            let relativePath = path.hasPrefix(rootPrefix)
                ? String(path.dropFirst(rootPrefix.count))
                : path

            if relativePath == ".mcp.json"
                || relativePath == ".app.json"
                || relativePath == ".lsp.json"
                || relativePath.hasSuffix("/.lsp.json") {
                let configuration = await AdapterProbeRunner.run(
                    session: session,
                    request: CommandRequest(
                        executable: "/bin/cat",
                        arguments: [path],
                        environment: environment,
                        timeout: .seconds(5),
                        maximumOutputBytes: 262_144
                    ),
                    name: "\(agent.rawValue)-plugin-component-config",
                    sourceReference: path,
                    parserVersion: parserVersion,
                    capturedAt: capturedAt
                )
                inventory.evidence.append(configuration.evidence)
                guard let content = configuration.result?.standardOutput,
                      configuration.result?.succeeded == true
                else {
                    if let issue = configuration.issue {
                        inventory.issues.append(issue)
                    }
                    continue
                }

                do {
                    let components = try ConfigurationComponentParser.parse(
                        Data(content.utf8),
                        relativePath: relativePath
                    )
                    for component in components {
                        append(
                            component,
                            relativePath: relativePath,
                            agent: agent,
                            packageID: packageID,
                            seen: &seen,
                            capabilities: &inventory.capabilities,
                            evidenceIDs: [configuration.evidence.id]
                        )
                    }
                } catch {
                    let diagnostic = SensitiveValueRedactor.redact(
                        error.localizedDescription
                    )
                    inventory.evidence.append(
                        EvidenceRecord(
                            id: InventoryIdentifier.make(
                                configuration.evidence.id,
                                "parser"
                            ),
                            probeName: "\(agent.rawValue)-plugin-component-config parser",
                            sourceReference: path,
                            capturedAt: capturedAt,
                            parserVersion: parserVersion,
                            status: .failure,
                            diagnostic: diagnostic
                        )
                    )
                    inventory.issues.append(
                        InventoryIssue(
                            summary: "Plugin component configuration could not be parsed",
                            detail: diagnostic
                        )
                    )
                }
                continue
            }

            guard let component = classify(relativePath) else {
                continue
            }
            append(
                component,
                relativePath: relativePath,
                agent: agent,
                packageID: packageID,
                seen: &seen,
                capabilities: &inventory.capabilities,
                evidenceIDs: [listingEvidenceID]
            )
        }

        return inventory
    }

    private static func append(
        _ component: (kind: CapabilityKind, name: String),
        relativePath: String,
        agent: AgentKind,
        packageID: String,
        seen: inout Set<String>,
        capabilities: inout [ProvidedCapability],
        evidenceIDs: [EvidenceRecord.ID]
    ) {
        let id = InventoryIdentifier.make(
            agent.rawValue,
            packageID,
            component.kind.rawValue,
            component.name
        )
        guard seen.insert(id).inserted else {
            return
        }
        capabilities.append(
            ProvidedCapability(
                id: id,
                agent: agent,
                packageID: packageID,
                kind: component.kind,
                name: component.name,
                relativePath: relativePath,
                evidenceIDs: evidenceIDs
            )
        )
    }

    private static func classify(
        _ relativePath: String
    ) -> (kind: CapabilityKind, name: String)? {
        let components = relativePath.split(separator: "/").map(String.init)

        if components.count >= 3,
           components[0] == "skills",
           components.last == "SKILL.md" {
            return (.skill, components[1])
        }
        if components.count == 2,
           components[0] == "agents",
           relativePath.hasSuffix(".md") {
            return (.subagent, URL(fileURLWithPath: components[1]).deletingPathExtension().lastPathComponent)
        }
        if components.count == 2,
           components[0] == "commands",
           relativePath.hasSuffix(".md") {
            return (.command, URL(fileURLWithPath: components[1]).deletingPathExtension().lastPathComponent)
        }
        if relativePath == "hooks/hooks.json" {
            return (.hook, "Lifecycle hooks")
        }
        if components.count >= 2,
           components[0] == "bin" {
            return (.executable, components.dropFirst().joined(separator: "/"))
        }
        if components.count >= 2,
           components[0] == "scripts" {
            return (.executable, components.dropFirst().joined(separator: "/"))
        }

        return nil
    }
}

private enum ConfigurationComponentParser {
    static func parse(
        _ data: Data,
        relativePath: String
    ) throws -> [(kind: CapabilityKind, name: String)] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw AdapterError.invalidInventory(
                "Plugin component configuration is not a JSON object."
            )
        }

        let kind: CapabilityKind
        let containerKeys: [String]
        if relativePath == ".mcp.json" {
            kind = .mcpServer
            containerKeys = ["mcpServers"]
        } else if relativePath == ".app.json" {
            kind = .connector
            containerKeys = ["apps", "connectors"]
        } else {
            kind = .lspServer
            containerKeys = ["languageServers", "lspServers"]
        }

        let candidate: [String: Any]
        if let nested = containerKeys.compactMap({ root[$0] as? [String: Any] }).first {
            candidate = nested
        } else {
            candidate = root
        }

        return candidate.keys
            .filter { !SensitiveValueRedactor.isSensitiveKey($0) }
            .sorted()
            .map { (kind, $0) }
    }
}

enum InventoryNormalizer {
    static func removingStandaloneDuplicatesOfPluginCapabilities(
        capabilities: [ProvidedCapability],
        installations: [InstallationRecord]
    ) -> (
        capabilities: [ProvidedCapability],
        installations: [InstallationRecord]
    ) {
        let pluginKeys = Set(
            capabilities.compactMap { capability -> String? in
                guard capability.packageID != nil else {
                    return nil
                }
                return capabilityKey(capability)
            }
        )
        let removedCapabilityIDs = Set(
            capabilities.compactMap { capability -> ProvidedCapability.ID? in
                guard capability.packageID == nil,
                      pluginKeys.contains(capabilityKey(capability))
                else {
                    return nil
                }
                return capability.id
            }
        )

        return (
            capabilities.filter {
                !removedCapabilityIDs.contains($0.id)
            },
            installations.filter { installation in
                guard let capabilityID = installation.capabilityID else {
                    return true
                }
                return !removedCapabilityIDs.contains(capabilityID)
            }
        )
    }

    private static func capabilityKey(
        _ capability: ProvidedCapability
    ) -> String {
        [
            capability.agent.rawValue,
            capability.kind.rawValue,
            capability.name.lowercased()
        ].joined(separator: "\u{1f}")
    }
}
