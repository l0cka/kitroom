import Foundation

public struct CodexAdapter: AgentAdapter {
    public let agent = AgentKind.codex

    public let discoveryProfile = AgentDiscoveryProfile(
        agent: .codex,
        executableNames: ["codex"],
        candidateConfigurationPaths: [
            "~/.codex/config.toml"
        ],
        candidateSkillPaths: [
            "~/.codex/skills",
            "~/.agents/skills"
        ]
    )

    public let implementedCapabilities: AdapterCapabilities = [.inventory]

    private let clock: any KitroomClock

    public init(clock: any KitroomClock = SystemKitroomClock()) {
        self.clock = clock
    }

    public func inspect(
        context: InventoryContext,
        using session: any HostSession
    ) async throws -> InventorySnapshot {
        let capturedAt = clock.now
        let environment = session.host.connection == .local
            ? HostEnvironment.standard
            : [:]
        var sources: [CatalogSource] = []
        var packages: [PackageRecord] = []
        var providedCapabilities: [ProvidedCapability] = []
        var installations: [InstallationRecord] = []
        var evidence: [EvidenceRecord] = []
        var issues: [InventoryIssue] = []
        var capabilityReports: [AdapterCapabilityReport] = []

        let executableProbe = await probe(
            session: session,
            executable: "/usr/bin/which",
            arguments: ["codex"],
            environment: environment,
            name: "codex-executable",
            source: "which codex",
            capturedAt: capturedAt
        )
        evidence.append(executableProbe.evidence)

        guard let executable = successfulText(executableProbe) else {
            if let issue = executableProbe.issue {
                issues.append(issue)
            }
            return InventorySnapshot(
                hostID: session.host.id,
                agent: .codex,
                capturedAt: capturedAt,
                status: .unavailable,
                capabilities: unsupportedReports(
                    evidenceID: executableProbe.evidence.id
                ),
                evidence: evidence,
                issues: issues.isEmpty
                    ? [
                        InventoryIssue(
                            summary: "Codex is unavailable",
                            detail: "The codex executable was not found on this host."
                        )
                    ]
                    : issues
            )
        }

        let versionProbe = await probe(
            session: session,
            executable: executable,
            arguments: ["--version"],
            environment: environment,
            name: "codex-version",
            source: "codex --version",
            capturedAt: capturedAt
        )
        evidence.append(versionProbe.evidence)
        if let issue = versionProbe.issue {
            issues.append(issue)
        }
        let version = successfulText(versionProbe)

        let helpProbe = await probe(
            session: session,
            executable: executable,
            arguments: ["plugin", "--help"],
            environment: environment,
            name: "codex-plugin-capabilities",
            source: "codex plugin --help",
            capturedAt: capturedAt
        )
        evidence.append(helpProbe.evidence)

        let pluginProbe = await probe(
            session: session,
            executable: executable,
            arguments: ["plugin", "list", "--json"],
            environment: environment,
            name: "codex-plugin-inventory",
            source: "codex plugin list --json",
            capturedAt: capturedAt
        )
        evidence.append(pluginProbe.evidence)
        let parsedPlugins: ParsedAgentInventory?
        if let data = successfulData(pluginProbe) {
            parsedPlugins = parse(
                name: "Codex plugin inventory",
                evidenceID: pluginProbe.evidence.id,
                evidence: &evidence,
                issues: &issues,
                capturedAt: capturedAt
            ) {
                try CodexInventoryParser.parsePlugins(
                    data,
                    hostID: session.host.id,
                    capturedAt: capturedAt,
                    evidenceID: pluginProbe.evidence.id
                )
            }
        } else {
            parsedPlugins = nil
            if let issue = pluginProbe.issue {
                issues.append(issue)
            }
        }

        if let parsedPlugins {
            merge(
                parsedPlugins,
                sources: &sources,
                packages: &packages,
                capabilities: &providedCapabilities,
                installations: &installations
            )
        }

        let marketplaceProbe = await probe(
            session: session,
            executable: executable,
            arguments: ["plugin", "marketplace", "list", "--json"],
            environment: environment,
            name: "codex-marketplace-inventory",
            source: "codex plugin marketplace list --json",
            capturedAt: capturedAt
        )
        evidence.append(marketplaceProbe.evidence)
        var parsedMarketplaces = false
        if let data = successfulData(marketplaceProbe) {
            let values: [CatalogSource]? = parse(
                name: "Codex marketplace inventory",
                evidenceID: marketplaceProbe.evidence.id,
                evidence: &evidence,
                issues: &issues,
                capturedAt: capturedAt
            ) {
                try CodexInventoryParser.parseMarketplaces(
                    data,
                    capturedAt: capturedAt,
                    evidenceID: marketplaceProbe.evidence.id
                )
            }
            if let values {
                sources.append(contentsOf: values)
                parsedMarketplaces = true
            }
        } else if let issue = marketplaceProbe.issue {
            issues.append(issue)
        }

        let mcpProbe = await probe(
            session: session,
            executable: executable,
            arguments: ["mcp", "list", "--json"],
            environment: environment,
            name: "codex-mcp-inventory",
            source: "codex mcp list --json",
            capturedAt: capturedAt
        )
        evidence.append(mcpProbe.evidence)
        let parsedMCP: ParsedAgentInventory?
        if let data = successfulData(mcpProbe) {
            parsedMCP = parse(
                name: "Codex MCP inventory",
                evidenceID: mcpProbe.evidence.id,
                evidence: &evidence,
                issues: &issues,
                capturedAt: capturedAt
            ) {
                try CodexInventoryParser.parseMCPServers(
                    data,
                    hostID: session.host.id,
                    evidenceID: mcpProbe.evidence.id
                )
            }
        } else {
            parsedMCP = nil
            if let issue = mcpProbe.issue {
                issues.append(issue)
            }
        }
        if let parsedMCP {
            merge(
                parsedMCP,
                sources: &sources,
                packages: &packages,
                capabilities: &providedCapabilities,
                installations: &installations
            )
        }

        let homeProbe = await probe(
            session: session,
            executable: "/usr/bin/printenv",
            arguments: ["HOME"],
            environment: environment,
            name: "codex-home-directory",
            source: "printenv HOME",
            capturedAt: capturedAt
        )
        evidence.append(homeProbe.evidence)
        var skillProbeSucceeded = false
        var discoveredHome: String?
        var configurationOverrides: [CodexSkillConfigurationOverride] = []

        if let home = successfulText(homeProbe) {
            discoveredHome = home
            let compatibilityRoot = URL(fileURLWithPath: home)
                .appendingPathComponent(".codex/skills")
                .path
            let bundledRoot = URL(fileURLWithPath: compatibilityRoot)
                .appendingPathComponent(".system")
                .path
            let roots: [
                (
                    path: String,
                    scope: InventoryScope,
                    origin: InstallationOrigin,
                    excluded: [String]
                )
            ] = [
                (
                    URL(fileURLWithPath: home)
                        .appendingPathComponent(".agents/skills")
                        .path,
                    .user,
                    .standalone,
                    []
                ),
                (
                    bundledRoot,
                    .system,
                    .bundled,
                    []
                ),
                (
                    compatibilityRoot,
                    .user,
                    .legacy,
                    [bundledRoot]
                ),
                ("/etc/codex/skills", .managed, .standalone, [])
            ]

            let issueCountBeforeSkills = issues.count
            for root in roots {
                guard !Task.isCancelled else {
                    break
                }
                let scan = await SkillInventoryScanner.scan(
                    session: session,
                    agent: .codex,
                    root: root.path,
                    scope: root.scope,
                    origin: root.origin,
                    capturedAt: capturedAt,
                    parserVersion: CodexInventoryParser.parserVersion,
                    environment: environment,
                    excludedPathPrefixes: root.excluded
                )
                packages.append(contentsOf: scan.packages)
                providedCapabilities.append(contentsOf: scan.capabilities)
                installations.append(contentsOf: scan.installations)
                evidence.append(contentsOf: scan.evidence)
                issues.append(contentsOf: scan.issues)
            }

            let configurationPaths = [
                "/etc/codex/config.toml",
                URL(fileURLWithPath: home)
                    .appendingPathComponent(".codex/config.toml")
                    .path
            ]
            for configurationPath in configurationPaths {
                guard !Task.isCancelled else {
                    break
                }
                let presence = await PathInventoryInspector.inspect(
                    session: session,
                    path: configurationPath,
                    kind: .file,
                    name: "codex-skill-configuration-file",
                    parserVersion: CodexInventoryParser.parserVersion,
                    capturedAt: capturedAt,
                    environment: environment
                )
                evidence.append(contentsOf: presence.evidence)

                if presence.isPresent == true {
                    let configuration = await probe(
                        session: session,
                        executable: "/bin/cat",
                        arguments: [configurationPath],
                        environment: environment,
                        name: "codex-skill-configuration",
                        source: configurationPath,
                        capturedAt: capturedAt
                    )
                    evidence.append(configuration.evidence)
                    if let value = successfulText(configuration) {
                        let parsed: [CodexSkillConfigurationOverride]? = parse(
                            name: "Codex skill configuration",
                            evidenceID: configuration.evidence.id,
                            evidence: &evidence,
                            issues: &issues,
                            capturedAt: capturedAt
                        ) {
                            try CodexInventoryParser.parseSkillConfiguration(value)
                        }
                        if let parsed {
                            configurationOverrides.append(contentsOf: parsed)
                        }
                    } else if let issue = configuration.issue {
                        issues.append(issue)
                    }
                } else if presence.isPresent == nil,
                          let issue = presence.issue {
                    issues.append(issue)
                }
            }

            skillProbeSucceeded = issues.count == issueCountBeforeSkills
        } else if let issue = homeProbe.issue {
            issues.append(issue)
        }

        if let workingDirectory = context.workingDirectory {
            let issueCountBeforeProject = issues.count
            let project = await ProjectDirectoryInspector.inspect(
                session: session,
                workingDirectory: workingDirectory,
                agent: .codex,
                parserVersion: CodexInventoryParser.parserVersion,
                capturedAt: capturedAt,
                environment: environment
            )
            evidence.append(contentsOf: project.evidence)
            issues.append(contentsOf: project.issues)

            for directory in project.hierarchy {
                guard !Task.isCancelled else {
                    break
                }
                let skillRoot = URL(fileURLWithPath: directory)
                    .appendingPathComponent(".agents/skills")
                    .path
                let scan = await SkillInventoryScanner.scan(
                    session: session,
                    agent: .codex,
                    root: skillRoot,
                    scope: .repository,
                    origin: .standalone,
                    capturedAt: capturedAt,
                    parserVersion: CodexInventoryParser.parserVersion,
                    environment: environment
                )
                packages.append(contentsOf: scan.packages)
                providedCapabilities.append(contentsOf: scan.capabilities)
                installations.append(contentsOf: scan.installations)
                evidence.append(contentsOf: scan.evidence)
                issues.append(contentsOf: scan.issues)

                let configurationPath = URL(fileURLWithPath: directory)
                    .appendingPathComponent(".codex/config.toml")
                    .path
                let presence = await PathInventoryInspector.inspect(
                    session: session,
                    path: configurationPath,
                    kind: .file,
                    name: "codex-project-skill-configuration-file",
                    parserVersion: CodexInventoryParser.parserVersion,
                    capturedAt: capturedAt,
                    environment: environment
                )
                evidence.append(contentsOf: presence.evidence)
                if presence.isPresent == true {
                    let configuration = await probe(
                        session: session,
                        executable: "/bin/cat",
                        arguments: [configurationPath],
                        environment: environment,
                        name: "codex-project-skill-configuration",
                        source: configurationPath,
                        capturedAt: capturedAt
                    )
                    evidence.append(configuration.evidence)
                    if let value = successfulText(configuration) {
                        let parsed: [CodexSkillConfigurationOverride]? = parse(
                            name: "Codex project skill configuration",
                            evidenceID: configuration.evidence.id,
                            evidence: &evidence,
                            issues: &issues,
                            capturedAt: capturedAt
                        ) {
                            try CodexInventoryParser.parseSkillConfiguration(value)
                        }
                        if let parsed {
                            configurationOverrides.append(contentsOf: parsed)
                        }
                    } else if let issue = configuration.issue {
                        issues.append(issue)
                    }
                } else if presence.isPresent == nil,
                          let issue = presence.issue {
                    issues.append(issue)
                }
            }

            skillProbeSucceeded = skillProbeSucceeded
                && issues.count == issueCountBeforeProject
        }

        if let discoveredHome {
            installations = applyingSkillConfiguration(
                configurationOverrides,
                home: discoveredHome,
                capabilities: providedCapabilities,
                installations: installations
            )
        }

        if let parsedPlugins {
            let resolvedPluginInstallations = parsedPlugins.installations.map {
                resolvingPluginInstallation(
                    $0,
                    packages: parsedPlugins.packages,
                    sources: sources
                )
            }
            let resolvedByID = Dictionary(
                uniqueKeysWithValues: resolvedPluginInstallations.map {
                    ($0.id, $0)
                }
            )
            installations = installations.map {
                resolvedByID[$0.id] ?? $0
            }

            for installation in resolvedPluginInstallations
                where installation.physicalOrigin?.hasPrefix("/") != true {
                guard let packageID = installation.packageID,
                      installation.physicalOrigin != nil
                else {
                    continue
                }
                    let diagnostic = "The agent reported a relative plugin path without a resolvable local marketplace root."
                    let evidenceID = InventoryIdentifier.make(
                        session.host.id.uuidString,
                        packageID,
                        "plugin-component-root",
                        capturedAt.ISO8601Format()
                    )
                    evidence.append(
                        EvidenceRecord(
                            id: evidenceID,
                            probeName: "codex-plugin-component-root",
                            sourceReference: packageID,
                            capturedAt: capturedAt,
                            parserVersion: CodexInventoryParser.parserVersion,
                            status: .partial,
                            diagnostic: diagnostic
                        )
                    )
                    issues.append(
                        InventoryIssue(
                            summary: "Codex plugin components are partially known",
                            detail: diagnostic
                        )
                    )
            }

            let componentScans = await PluginComponentScanner
                .scanInstalledPackages(
                    session: session,
                    agent: .codex,
                    installations: resolvedPluginInstallations,
                    capturedAt: capturedAt,
                    parserVersion: CodexInventoryParser.parserVersion,
                    environment: environment
                )
            for (installation, componentScan) in componentScans {
                guard !Task.isCancelled,
                      let packageID = installation.packageID,
                      let root = installation.physicalOrigin
                else {
                    break
                }
                providedCapabilities.append(contentsOf: componentScan.capabilities)
                evidence.append(contentsOf: componentScan.evidence)
                issues.append(contentsOf: componentScan.issues)

                for capability in componentScan.capabilities {
                    installations.append(
                        InstallationRecord(
                            id: InventoryIdentifier.make(
                                session.host.id.uuidString,
                                capability.id,
                                "plugin-provided"
                            ),
                            hostID: session.host.id,
                            agent: .codex,
                            packageID: packageID,
                            capabilityID: capability.id,
                            scope: installation.scope,
                            origin: .pluginProvided,
                            state: installation.state,
                            installedVersion: installation.installedVersion,
                            physicalOrigin: root,
                            restriction: installation.restriction,
                            evidenceIDs: capability.evidenceIDs
                        )
                    )
                }
            }
        }

        capabilityReports = capabilityMatrix(
            help: successfulText(helpProbe),
            helpEvidenceID: helpProbe.evidence.id,
            pluginInventory: parsedPlugins != nil,
            pluginEvidenceID: pluginProbe.evidence.id,
            marketplaceInventory: parsedMarketplaces,
            marketplaceEvidenceID: marketplaceProbe.evidence.id,
            skillInventory: skillProbeSucceeded,
            skillEvidenceID: homeProbe.evidence.id,
            mcpInventory: parsedMCP != nil,
            mcpEvidenceID: mcpProbe.evidence.id
        )

        let normalizedCapabilities = InventoryNormalizer
            .removingStandaloneDuplicatesOfPluginCapabilities(
                capabilities: providedCapabilities,
                installations: installations
            )
        providedCapabilities = normalizedCapabilities.capabilities
        installations = normalizedCapabilities.installations
        sources = deduplicated(sources)
        packages = deduplicated(packages)
        providedCapabilities = deduplicated(providedCapabilities)
        installations = deduplicated(installations)

        return InventorySnapshot(
            hostID: session.host.id,
            agent: .codex,
            capturedAt: capturedAt,
            status: issues.isEmpty ? .complete : .partial,
            agentVersion: version,
            capabilities: capabilityReports,
            catalogSources: sources,
            packages: packages,
            providedCapabilities: providedCapabilities,
            installations: installations,
            evidence: evidence,
            issues: issues
        )
    }

    public func makePlan(
        kind: OperationKind,
        extensionID: String,
        from snapshot: InventorySnapshot,
        using session: any HostSession
    ) async throws -> OperationPlan {
        throw AdapterError.notImplemented(agent: agent, capability: kind.rawValue)
    }

    private func probe(
        session: any HostSession,
        executable: String,
        arguments: [String],
        environment: [String: String],
        name: String,
        source: String,
        capturedAt: Date
    ) async -> ProbeCapture {
        await AdapterProbeRunner.run(
            session: session,
            request: CommandRequest(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: .seconds(15),
                maximumOutputBytes: 4_194_304
            ),
            name: name,
            sourceReference: source,
            parserVersion: CodexInventoryParser.parserVersion,
            capturedAt: capturedAt
        )
    }
}

private extension CodexAdapter {
    func successfulText(_ probe: ProbeCapture) -> String? {
        guard let result = probe.result, result.succeeded,
              !result.standardOutputWasTruncated
        else {
            return nil
        }
        let value = result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func successfulData(_ probe: ProbeCapture) -> Data? {
        successfulText(probe).map { Data($0.utf8) }
    }

    func parse<Value>(
        name: String,
        evidenceID: String,
        evidence: inout [EvidenceRecord],
        issues: inout [InventoryIssue],
        capturedAt: Date,
        parser: () throws -> Value
    ) -> Value? {
        do {
            return try parser()
        } catch {
            let diagnostic = SensitiveValueRedactor.redact(
                error.localizedDescription
            )
            evidence.append(
                EvidenceRecord(
                    id: InventoryIdentifier.make(evidenceID, "parser"),
                    probeName: "\(name) parser",
                    sourceReference: evidenceID,
                    capturedAt: capturedAt,
                    parserVersion: CodexInventoryParser.parserVersion,
                    status: .failure,
                    diagnostic: diagnostic
                )
            )
            issues.append(
                InventoryIssue(
                    summary: "\(name) could not be parsed",
                    detail: diagnostic
                )
            )
            return nil
        }
    }

    func merge(
        _ parsed: ParsedAgentInventory,
        sources: inout [CatalogSource],
        packages: inout [PackageRecord],
        capabilities: inout [ProvidedCapability],
        installations: inout [InstallationRecord]
    ) {
        sources.append(contentsOf: parsed.sources)
        packages.append(contentsOf: parsed.packages)
        capabilities.append(contentsOf: parsed.capabilities)
        installations.append(contentsOf: parsed.installations)
    }

    func capabilityMatrix(
        help: String?,
        helpEvidenceID: String,
        pluginInventory: Bool,
        pluginEvidenceID: String,
        marketplaceInventory: Bool,
        marketplaceEvidenceID: String,
        skillInventory: Bool,
        skillEvidenceID: String,
        mcpInventory: Bool,
        mcpEvidenceID: String
    ) -> [AdapterCapabilityReport] {
        let help = help?.lowercased()

        return [
            AdapterCapabilityReport(
                feature: .pluginInventory,
                support: pluginInventory ? .supported : .unknown,
                evidenceID: pluginEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .marketplaceInventory,
                support: marketplaceInventory ? .supported : .unknown,
                evidenceID: marketplaceEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .skillInventory,
                support: skillInventory ? .supported : .unknown,
                evidenceID: skillEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .mcpInventory,
                support: mcpInventory ? .supported : .unknown,
                evidenceID: mcpEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .pluginDetails,
                support: .unsupported,
                evidenceID: helpEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .installPlugin,
                support: help?.contains("\n  add ") == true ? .supported : .unknown,
                evidenceID: helpEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .updatePlugin,
                support: .unsupported,
                evidenceID: helpEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .enablePlugin,
                support: .unsupported,
                evidenceID: helpEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .disablePlugin,
                support: .unsupported,
                evidenceID: helpEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .uninstallPlugin,
                support: help?.contains("\n  remove ") == true ? .supported : .unknown,
                evidenceID: helpEvidenceID
            )
        ]
    }

    func unsupportedReports(evidenceID: String) -> [AdapterCapabilityReport] {
        AdapterFeature.allCases.map {
            AdapterCapabilityReport(
                feature: $0,
                support: .unsupported,
                evidenceID: evidenceID
            )
        }
    }

    func deduplicated<Value: Identifiable>(
        _ values: [Value]
    ) -> [Value] where Value.ID: Hashable {
        var seen = Set<Value.ID>()
        return values.filter { seen.insert($0.id).inserted }
    }

    func applyingSkillConfiguration(
        _ overrides: [CodexSkillConfigurationOverride],
        home: String,
        capabilities: [ProvidedCapability],
        installations: [InstallationRecord]
    ) -> [InstallationRecord] {
        let statesByPath = Dictionary(
            overrides.map {
                (
                    normalizedSkillPath($0.path, home: home),
                    $0.enabled ? EffectiveState.enabled : .disabled
                )
            },
            uniquingKeysWith: { _, latest in latest }
        )
        let skillPathsByCapability: [ProvidedCapability.ID: String] = Dictionary(
            capabilities.compactMap { capability in
                guard capability.kind == .skill,
                      let path = capability.relativePath
                else {
                    return nil
                }
                return (
                    capability.id,
                    normalizedSkillPath(path, home: home)
                ) as (ProvidedCapability.ID, String)
            },
            uniquingKeysWith: { first, _ in first }
        )

        return installations.map { installation in
            guard let capabilityID = installation.capabilityID,
                  let path = skillPathsByCapability[capabilityID],
                  let state = statesByPath[path]
            else {
                return installation
            }
            return InstallationRecord(
                id: installation.id,
                hostID: installation.hostID,
                agent: installation.agent,
                packageID: installation.packageID,
                capabilityID: installation.capabilityID,
                scope: installation.scope,
                origin: installation.origin,
                state: state,
                installedVersion: installation.installedVersion,
                physicalOrigin: installation.physicalOrigin,
                restriction: installation.restriction,
                evidenceIDs: installation.evidenceIDs
            )
        }
    }

    func normalizedSkillPath(_ path: String, home: String) -> String {
        let expanded: String
        if path == "~" {
            expanded = home
        } else if path.hasPrefix("~/") {
            expanded = URL(fileURLWithPath: home)
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        } else {
            expanded = path
        }
        return URL(fileURLWithPath: expanded).standardized.path
    }

    func resolvingPluginInstallation(
        _ installation: InstallationRecord,
        packages: [PackageRecord],
        sources: [CatalogSource]
    ) -> InstallationRecord {
        guard let origin = installation.physicalOrigin,
              !origin.hasPrefix("/"),
              let packageID = installation.packageID,
              let sourceID = packages.first(where: {
                  $0.id == packageID
              })?.sourceID
        else {
            return installation
        }
        let references = sources
            .filter { $0.id == sourceID }
            .flatMap { source in
                [source.localRoot, source.reference].compactMap { $0 }
            }
        guard let reference = references.first(where: {
            $0.hasPrefix("/") || URL(string: $0)?.isFileURL == true
        }) else {
            return installation
        }

        let basePath: String?
        if reference.hasPrefix("/") {
            basePath = reference
        } else if let url = URL(string: reference),
                  url.isFileURL {
            basePath = url.path
        } else {
            basePath = nil
        }
        guard let basePath else {
            return installation
        }

        let base = URL(fileURLWithPath: basePath).standardized.path
        let resolved = URL(fileURLWithPath: base)
            .appendingPathComponent(origin)
            .standardized.path
        guard resolved == base || resolved.hasPrefix(base + "/") else {
            return installation
        }

        return InstallationRecord(
            id: installation.id,
            hostID: installation.hostID,
            agent: installation.agent,
            packageID: installation.packageID,
            capabilityID: installation.capabilityID,
            scope: installation.scope,
            origin: installation.origin,
            state: installation.state,
            installedVersion: installation.installedVersion,
            physicalOrigin: resolved,
            restriction: installation.restriction,
            evidenceIDs: installation.evidenceIDs
        )
    }
}
