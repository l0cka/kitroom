import Foundation

struct ParsedCatalogue: Sendable {
    var sources: [CatalogSource] = []
    var packages: [PackageRecord] = []
    var packageStates: [CataloguePackageState] = []
    var componentRoots: [CatalogueComponentRoot] = []
}

struct CatalogueComponentRoot: Hashable, Sendable {
    let packageID: PackageRecord.ID
    let path: String
    let containerPath: String?

    init(
        packageID: PackageRecord.ID,
        path: String,
        containerPath: String? = nil
    ) {
        self.packageID = packageID
        self.path = path
        self.containerPath = containerPath
    }
}

enum CatalogueVersionJoin {
    static func status(
        installedVersion: String?,
        availableVersion: String?
    ) -> UpdateStatus {
        guard let installedVersion else {
            return .notInstalled
        }
        guard let availableVersion,
              !installedVersion.isEmpty,
              !availableVersion.isEmpty,
              installedVersion.lowercased() != "unknown",
              availableVersion.lowercased() != "unknown"
        else {
            return .incomparable
        }
        return installedVersion == availableVersion
            ? .upToDate
            : .updateAvailable
    }

    static func installedVersion(
        packageID: PackageRecord.ID,
        inventory: InventorySnapshot?,
        fallback: String?
    ) -> String? {
        inventory?.installations.first {
            $0.packageID == packageID && $0.capabilityID == nil
        }?.installedVersion
            ?? inventory?.packages.first { $0.id == packageID }?.version
            ?? fallback
    }
}

enum CatalogueComponentCollector {
    static func scan(
        roots: [CatalogueComponentRoot],
        session: any HostSession,
        agent: AgentKind,
        capturedAt: Date,
        parserVersion: String,
        environment: [String: String],
        maximumConcurrentScans: Int = 4
    ) async -> PluginComponentScanResult {
        var result = PluginComponentScanResult()
        let directRoots = roots.filter { $0.containerPath == nil }
        let containedRoots = Dictionary(
            grouping: roots.filter { $0.containerPath != nil }
        ) {
            $0.containerPath!
        }
        var indexedInputs: [
            (
                root: CatalogueComponentRoot,
                paths: [String],
                evidenceID: EvidenceRecord.ID
            )
        ] = []

        let listings = await withTaskGroup(
            of: (String, [CatalogueComponentRoot], ProbeCapture).self
        ) { group in
            for (containerPath, candidates) in containedRoots {
                group.addTask {
                    let capture = await AdapterProbeRunner.run(
                        session: session,
                        request: CommandRequest(
                            executable: "/usr/bin/find",
                            arguments: [
                                "-L",
                                containerPath,
                                "-type",
                                "f",
                                "-print0"
                            ],
                            environment: environment,
                            timeout: .seconds(10),
                            maximumOutputBytes: 4_194_304
                        ),
                        name: "\(agent.rawValue)-catalogue-component-index",
                        sourceReference: containerPath,
                        parserVersion: parserVersion,
                        capturedAt: capturedAt
                    )
                    return (containerPath, candidates, capture)
                }
            }

            var values: [
                (String, [CatalogueComponentRoot], ProbeCapture)
            ] = []
            for await value in group {
                values.append(value)
            }
            return values.sorted { $0.0 < $1.0 }
        }

        for (_, candidates, capture) in listings {
            result.evidence.append(capture.evidence)
            guard capture.result?.succeeded == true,
                  capture.evidence.status == .success
            else {
                if let issue = capture.issue {
                    result.issues.append(issue)
                }
                continue
            }
            let paths = (
                capture.result?.standardOutput
                    .split(separator: "\0")
                    .map(String.init)
                    ?? []
            )
            .sorted()
            for candidate in candidates.sorted(by: { $0.path < $1.path }) {
                let prefix = candidate.path.hasSuffix("/")
                    ? candidate.path
                    : candidate.path + "/"
                let matching = paths.filter {
                    $0.hasPrefix(prefix)
                }
                guard !matching.isEmpty else {
                    continue
                }
                indexedInputs.append(
                    (
                        root: candidate,
                        paths: matching,
                        evidenceID: capture.evidence.id
                    )
                )
            }
        }

        let indexedResults = await withTaskGroup(
            of: (Int, PluginComponentScanResult).self
        ) { group in
            guard !indexedInputs.isEmpty else {
                return [] as [PluginComponentScanResult]
            }
            let concurrency = max(
                1,
                min(maximumConcurrentScans, indexedInputs.count)
            )
            var nextIndex = 0
            var values: [(Int, PluginComponentScanResult)] = []

            func addTask(at index: Int) {
                let input = indexedInputs[index]
                group.addTask {
                    let value = await PluginComponentScanner.scanKnownFiles(
                        session: session,
                        agent: agent,
                        packageID: input.root.packageID,
                        root: input.root.path,
                        paths: input.paths,
                        listingEvidenceID: input.evidenceID,
                        capturedAt: capturedAt,
                        parserVersion: parserVersion,
                        environment: environment
                    )
                    return (index, value)
                }
            }

            while nextIndex < concurrency {
                addTask(at: nextIndex)
                nextIndex += 1
            }
            while let value = await group.next() {
                values.append(value)
                if nextIndex < indexedInputs.count, !Task.isCancelled {
                    addTask(at: nextIndex)
                    nextIndex += 1
                }
            }
            return values
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }

        for scan in indexedResults {
            result.capabilities.append(contentsOf: scan.capabilities)
            result.evidence.append(contentsOf: scan.evidence)
            result.issues.append(contentsOf: scan.issues)
        }

        let installations = directRoots.map { root in
            InstallationRecord(
                id: InventoryIdentifier.make(
                    session.host.id.uuidString,
                    root.packageID,
                    "catalogue"
                ),
                hostID: session.host.id,
                agent: agent,
                packageID: root.packageID,
                scope: .unknown,
                origin: .marketplace,
                state: .unknown,
                physicalOrigin: root.path,
                restriction: .readOnly
            )
        }
        let directScans = await PluginComponentScanner.scanInstalledPackages(
            session: session,
            agent: agent,
            installations: installations,
            capturedAt: capturedAt,
            parserVersion: parserVersion,
            environment: environment,
            maximumConcurrentScans: maximumConcurrentScans
        )
        return directScans.reduce(into: result) {
            $0.capabilities.append(contentsOf: $1.result.capabilities)
            $0.evidence.append(contentsOf: $1.result.evidence)
            $0.issues.append(contentsOf: $1.result.issues)
        }
    }
}
