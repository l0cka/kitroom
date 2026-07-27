import Foundation

public struct ClaudeAdapter: AgentAdapter {
    public let agent = AgentKind.claude
    public let userSkillRelativePath = ".claude/skills"

    public let discoveryProfile = AgentDiscoveryProfile(
        agent: .claude,
        executableNames: ["claude"],
        candidateConfigurationPaths: [
            "~/.claude/settings.json"
        ],
        candidateSkillPaths: [
            "~/.claude/skills",
            "~/.agents/skills"
        ]
    )

    public let implementedCapabilities: AdapterCapabilities = [
        .inventory,
        .catalogue
    ]

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

        let executableProbe = await probe(
            session: session,
            executable: "/usr/bin/which",
            arguments: ["claude"],
            environment: environment,
            name: "claude-executable",
            source: "which claude",
            capturedAt: capturedAt
        )
        evidence.append(executableProbe.evidence)

        guard let executable = successfulText(executableProbe) else {
            if let issue = executableProbe.issue {
                issues.append(issue)
            }
            return InventorySnapshot(
                hostID: session.host.id,
                agent: .claude,
                capturedAt: capturedAt,
                status: .unavailable,
                capabilities: unsupportedReports(
                    evidenceID: executableProbe.evidence.id
                ),
                evidence: evidence,
                issues: issues.isEmpty
                    ? [
                        InventoryIssue(
                            summary: "Claude Code is unavailable",
                            detail: "The claude executable was not found on this host."
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
            name: "claude-version",
            source: "claude --version",
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
            name: "claude-plugin-capabilities",
            source: "claude plugin --help",
            capturedAt: capturedAt
        )
        evidence.append(helpProbe.evidence)

        let pluginProbe = await probe(
            session: session,
            executable: executable,
            arguments: ["plugin", "list", "--json"],
            environment: environment,
            name: "claude-plugin-inventory",
            source: "claude plugin list --json",
            capturedAt: capturedAt
        )
        evidence.append(pluginProbe.evidence)
        let parsedPlugins: ParsedAgentInventory?
        if let data = successfulData(pluginProbe) {
            parsedPlugins = parse(
                name: "Claude plugin inventory",
                evidenceID: pluginProbe.evidence.id,
                evidence: &evidence,
                issues: &issues,
                capturedAt: capturedAt
            ) {
                try ClaudeInventoryParser.parsePlugins(
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
            name: "claude-marketplace-inventory",
            source: "claude plugin marketplace list --json",
            capturedAt: capturedAt
        )
        evidence.append(marketplaceProbe.evidence)
        var parsedMarketplaces = false
        if let data = successfulData(marketplaceProbe) {
            let values: [CatalogSource]? = parse(
                name: "Claude marketplace inventory",
                evidenceID: marketplaceProbe.evidence.id,
                evidence: &evidence,
                issues: &issues,
                capturedAt: capturedAt
            ) {
                try ClaudeInventoryParser.parseMarketplaces(
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

        let homeProbe = await probe(
            session: session,
            executable: "/usr/bin/printenv",
            arguments: ["HOME"],
            environment: environment,
            name: "claude-home-directory",
            source: "printenv HOME",
            capturedAt: capturedAt
        )
        evidence.append(homeProbe.evidence)
        var skillProbeSucceeded = false
        var mcpProbeSucceeded = false
        var mcpEvidenceID = homeProbe.evidence.id
        var userConfigurationData: Data?

        if let home = successfulText(homeProbe) {
            let skillRoot = URL(fileURLWithPath: home)
                .appendingPathComponent(".claude/skills")
                .path
            let skillScan = await SkillInventoryScanner.scan(
                session: session,
                agent: .claude,
                root: skillRoot,
                scope: .user,
                origin: .standalone,
                capturedAt: capturedAt,
                parserVersion: ClaudeInventoryParser.parserVersion,
                environment: environment
            )
            packages.append(contentsOf: skillScan.packages)
            providedCapabilities.append(contentsOf: skillScan.capabilities)
            installations.append(contentsOf: skillScan.installations)
            evidence.append(contentsOf: skillScan.evidence)
            issues.append(contentsOf: skillScan.issues)

            let commandRoot = URL(fileURLWithPath: home)
                .appendingPathComponent(".claude/commands")
                .path
            let legacyScan = await LegacyCommandInventoryScanner.scan(
                session: session,
                root: commandRoot,
                capturedAt: capturedAt,
                parserVersion: ClaudeInventoryParser.parserVersion,
                environment: environment
            )
            packages.append(contentsOf: legacyScan.packages)
            providedCapabilities.append(contentsOf: legacyScan.capabilities)
            installations.append(contentsOf: legacyScan.installations)
            evidence.append(contentsOf: legacyScan.evidence)
            issues.append(contentsOf: legacyScan.issues)
            skillProbeSucceeded = skillScan.issues.isEmpty
                && legacyScan.issues.isEmpty

            let configurationPath = URL(fileURLWithPath: home)
                .appendingPathComponent(".claude.json")
                .path
            let configurationPresence = await PathInventoryInspector.inspect(
                session: session,
                path: configurationPath,
                kind: .file,
                name: "claude-mcp-configuration-file",
                parserVersion: ClaudeInventoryParser.parserVersion,
                capturedAt: capturedAt,
                environment: environment
            )
            evidence.append(contentsOf: configurationPresence.evidence)
            mcpEvidenceID = configurationPresence.evidence.last?.id
                ?? homeProbe.evidence.id

            if configurationPresence.isPresent == true {
                let configurationProbe = await probe(
                    session: session,
                    executable: "/bin/cat",
                    arguments: [configurationPath],
                    environment: environment,
                    name: "claude-mcp-configuration",
                    source: "~/.claude.json (MCP names and state only)",
                    capturedAt: capturedAt
                )
                evidence.append(configurationProbe.evidence)
                mcpEvidenceID = configurationProbe.evidence.id

                if let data = successfulData(configurationProbe) {
                    userConfigurationData = data
                    let parsedMCP: ParsedAgentInventory? = parse(
                        name: "Claude MCP configuration",
                        evidenceID: configurationProbe.evidence.id,
                        evidence: &evidence,
                        issues: &issues,
                        capturedAt: capturedAt
                    ) {
                        try ClaudeMCPConfigurationParser.parse(
                            data,
                            hostID: session.host.id,
                            evidenceID: configurationProbe.evidence.id
                        )
                    }
                    if let parsedMCP {
                        merge(
                            parsedMCP,
                            sources: &sources,
                            packages: &packages,
                            capabilities: &providedCapabilities,
                            installations: &installations
                        )
                        mcpProbeSucceeded = true
                    }
                } else if let issue = configurationProbe.issue {
                    issues.append(issue)
                }
            } else if configurationPresence.isPresent == false {
                mcpProbeSucceeded = true
            } else if let issue = configurationPresence.issue {
                issues.append(issue)
            }
        } else if let issue = homeProbe.issue {
            issues.append(issue)
        }

        if let workingDirectory = context.workingDirectory {
            let issueCountBeforeProject = issues.count
            let project = await ProjectDirectoryInspector.inspect(
                session: session,
                workingDirectory: workingDirectory,
                agent: .claude,
                parserVersion: ClaudeInventoryParser.parserVersion,
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
                    .appendingPathComponent(".claude/skills")
                    .path
                let skillScan = await SkillInventoryScanner.scan(
                    session: session,
                    agent: .claude,
                    root: skillRoot,
                    scope: .repository,
                    origin: .standalone,
                    capturedAt: capturedAt,
                    parserVersion: ClaudeInventoryParser.parserVersion,
                    environment: environment
                )
                packages.append(contentsOf: skillScan.packages)
                providedCapabilities.append(contentsOf: skillScan.capabilities)
                installations.append(contentsOf: skillScan.installations)
                evidence.append(contentsOf: skillScan.evidence)
                issues.append(contentsOf: skillScan.issues)

                let commandRoot = URL(fileURLWithPath: directory)
                    .appendingPathComponent(".claude/commands")
                    .path
                let commandScan = await LegacyCommandInventoryScanner.scan(
                    session: session,
                    root: commandRoot,
                    capturedAt: capturedAt,
                    parserVersion: ClaudeInventoryParser.parserVersion,
                    environment: environment,
                    scope: .repository,
                    origin: .legacy
                )
                packages.append(contentsOf: commandScan.packages)
                providedCapabilities.append(contentsOf: commandScan.capabilities)
                installations.append(contentsOf: commandScan.installations)
                evidence.append(contentsOf: commandScan.evidence)
                issues.append(contentsOf: commandScan.issues)
            }

            if let projectRoot = project.root {
                let projectMCPPath = URL(fileURLWithPath: projectRoot)
                    .appendingPathComponent(".mcp.json")
                    .path
                let presence = await PathInventoryInspector.inspect(
                    session: session,
                    path: projectMCPPath,
                    kind: .file,
                    name: "claude-project-mcp-configuration-file",
                    parserVersion: ClaudeInventoryParser.parserVersion,
                    capturedAt: capturedAt,
                    environment: environment
                )
                evidence.append(contentsOf: presence.evidence)
                mcpEvidenceID = presence.evidence.last?.id ?? mcpEvidenceID

                if presence.isPresent == true {
                    let projectMCP = await probe(
                        session: session,
                        executable: "/bin/cat",
                        arguments: [projectMCPPath],
                        environment: environment,
                        name: "claude-project-mcp-configuration",
                        source: ".mcp.json (server names and approval state only)",
                        capturedAt: capturedAt
                    )
                    evidence.append(projectMCP.evidence)
                    mcpEvidenceID = projectMCP.evidence.id
                    if let data = successfulData(projectMCP) {
                        let parsed: ParsedAgentInventory? = parse(
                            name: "Claude project MCP configuration",
                            evidenceID: projectMCP.evidence.id,
                            evidence: &evidence,
                            issues: &issues,
                            capturedAt: capturedAt
                        ) {
                            try ClaudeMCPConfigurationParser
                                .parseProjectConfiguration(
                                    data,
                                    userConfigurationData: userConfigurationData,
                                    hostID: session.host.id,
                                    projectRoot: projectRoot,
                                    evidenceID: projectMCP.evidence.id
                                )
                        }
                        if let parsed {
                            merge(
                                parsed,
                                sources: &sources,
                                packages: &packages,
                                capabilities: &providedCapabilities,
                                installations: &installations
                            )
                            mcpProbeSucceeded = true
                        }
                    } else if let issue = projectMCP.issue {
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

        if let parsedPlugins {
            let componentScans = await PluginComponentScanner
                .scanInstalledPackages(
                    session: session,
                    agent: .claude,
                    installations: parsedPlugins.installations,
                    capturedAt: capturedAt,
                    parserVersion: ClaudeInventoryParser.parserVersion,
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
                            agent: .claude,
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

        let capabilityReports = capabilityMatrix(
            help: successfulText(helpProbe),
            helpEvidenceID: helpProbe.evidence.id,
            pluginInventory: parsedPlugins != nil,
            pluginEvidenceID: pluginProbe.evidence.id,
            marketplaceInventory: parsedMarketplaces,
            marketplaceEvidenceID: marketplaceProbe.evidence.id,
            skillInventory: skillProbeSucceeded,
            skillEvidenceID: homeProbe.evidence.id,
            mcpInventory: mcpProbeSucceeded,
            mcpEvidenceID: mcpEvidenceID
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
            agent: .claude,
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

    public func inspectCatalogue(
        installed: InventorySnapshot?,
        using session: any HostSession
    ) async throws -> CatalogueSnapshot {
        let capturedAt = clock.now
        let environment = session.host.connection == .local
            ? HostEnvironment.standard
            : [:]
        var evidence: [EvidenceRecord] = []
        var issues: [InventoryIssue] = []

        let executableProbe = await probe(
            session: session,
            executable: "/usr/bin/which",
            arguments: ["claude"],
            environment: environment,
            name: "claude-catalogue-executable",
            source: "which claude",
            capturedAt: capturedAt
        )
        evidence.append(executableProbe.evidence)
        guard let executable = successfulText(executableProbe) else {
            if let issue = executableProbe.issue {
                issues.append(issue)
            }
            return CatalogueSnapshot(
                hostID: session.host.id,
                agent: .claude,
                capturedAt: capturedAt,
                status: .unavailable,
                capabilities: unsupportedReports(
                    evidenceID: executableProbe.evidence.id
                ),
                evidence: evidence,
                issues: issues
            )
        }

        async let versionCapture = probe(
            session: session,
            executable: executable,
            arguments: ["--version"],
            environment: environment,
            name: "claude-catalogue-version",
            source: "claude --version",
            capturedAt: capturedAt
        )
        async let helpCapture = probe(
            session: session,
            executable: executable,
            arguments: ["plugin", "--help"],
            environment: environment,
            name: "claude-catalogue-capabilities",
            source: "claude plugin --help",
            capturedAt: capturedAt
        )
        async let availableCapture = probe(
            session: session,
            executable: executable,
            arguments: ["plugin", "list", "--available", "--json"],
            environment: environment,
            name: "claude-native-catalogue",
            source: "claude plugin list --available --json",
            capturedAt: capturedAt
        )
        async let marketplaceCapture = probe(
            session: session,
            executable: executable,
            arguments: ["plugin", "marketplace", "list", "--json"],
            environment: environment,
            name: "claude-catalogue-marketplaces",
            source: "claude plugin marketplace list --json",
            capturedAt: capturedAt
        )

        let versionProbe = await versionCapture
        let helpProbe = await helpCapture
        let availableProbe = await availableCapture
        let marketplaceProbe = await marketplaceCapture
        evidence.append(contentsOf: [
            versionProbe.evidence,
            helpProbe.evidence,
            availableProbe.evidence,
            marketplaceProbe.evidence
        ])
        if let issue = versionProbe.issue {
            issues.append(issue)
        }
        if let issue = helpProbe.issue {
            issues.append(issue)
        }

        var marketplaces: [CatalogSource] = []
        if let data = successfulData(marketplaceProbe) {
            marketplaces = parse(
                name: "Claude catalogue marketplaces",
                evidenceID: marketplaceProbe.evidence.id,
                evidence: &evidence,
                issues: &issues,
                capturedAt: capturedAt
            ) {
                try ClaudeInventoryParser.parseMarketplaces(
                    data,
                    capturedAt: capturedAt,
                    evidenceID: marketplaceProbe.evidence.id
                )
            } ?? []
        } else if let issue = marketplaceProbe.issue {
            issues.append(issue)
        }

        var parsed = ParsedCatalogue()
        if let data = successfulData(availableProbe) {
            parsed = parse(
                name: "Claude native catalogue",
                evidenceID: availableProbe.evidence.id,
                evidence: &evidence,
                issues: &issues,
                capturedAt: capturedAt
            ) {
                try ClaudeInventoryParser.parseCatalogue(
                    data,
                    hostID: session.host.id,
                    capturedAt: capturedAt,
                    installedInventory: installed,
                    marketplaces: marketplaces,
                    evidenceID: availableProbe.evidence.id
                )
            } ?? ParsedCatalogue()
        } else if let issue = availableProbe.issue {
            issues.append(issue)
        }

        let components = await CatalogueComponentCollector.scan(
            roots: parsed.componentRoots,
            session: session,
            agent: .claude,
            capturedAt: capturedAt,
            parserVersion: ClaudeInventoryParser.parserVersion,
            environment: environment,
            maximumConcurrentScans: session.host.connection.isRemote ? 4 : 8
        )
        evidence.append(contentsOf: components.evidence)
        issues.append(contentsOf: components.issues)
        let help = successfulText(helpProbe)?.lowercased()
        let catalogueSupport: CapabilitySupport =
            help?.contains("\n  list ") == true ? .supported : .unknown
        let updateSupport: CapabilitySupport =
            help?.contains("\n  update ") == true ? .supported : .unknown

        return CatalogueSnapshot(
            hostID: session.host.id,
            agent: .claude,
            capturedAt: capturedAt,
            status: issues.isEmpty ? .complete : .partial,
            agentVersion: successfulText(versionProbe),
            capabilities: [
                AdapterCapabilityReport(
                    feature: .catalogueInventory,
                    support: catalogueSupport,
                    evidenceID: availableProbe.evidence.id
                ),
                AdapterCapabilityReport(
                    feature: .updatePlugin,
                    support: updateSupport,
                    evidenceID: helpProbe.evidence.id
                )
            ],
            sources: deduplicated(marketplaces + parsed.sources),
            packages: deduplicated(parsed.packages),
            providedCapabilities: deduplicated(components.capabilities),
            packageStates: deduplicated(parsed.packageStates),
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
            parserVersion: ClaudeInventoryParser.parserVersion,
            capturedAt: capturedAt
        )
    }
}

private extension ClaudeAdapter {
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
                    parserVersion: ClaudeInventoryParser.parserVersion,
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

        func support(_ command: String) -> CapabilitySupport {
            help?.contains("\n  \(command) ") == true ? .supported : .unknown
        }

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
                feature: .catalogueInventory,
                support: .unknown,
                evidenceID: helpEvidenceID
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
                support: support("details"),
                evidenceID: helpEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .installPlugin,
                support: support("install"),
                evidenceID: helpEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .updatePlugin,
                support: support("update"),
                evidenceID: helpEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .enablePlugin,
                support: support("enable"),
                evidenceID: helpEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .disablePlugin,
                support: support("disable"),
                evidenceID: helpEvidenceID
            ),
            AdapterCapabilityReport(
                feature: .uninstallPlugin,
                support: support("uninstall"),
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
}
