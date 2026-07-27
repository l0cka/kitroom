import Foundation

public enum ComparisonEntityKind: String, Codable, Hashable, Sendable {
    case package
    case capability
}

public enum ComparisonFindingKind: String, Codable, Hashable, Sendable {
    case onlyOnLeft
    case onlyOnRight
    case versionMismatch
    case enabledStateMismatch
    case sourceMismatch
    case digestMismatch
    case matching
    case incomparable
    case unknown
}

public struct HostComparisonItem: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let agent: AgentKind
    public let entityKind: ComparisonEntityKind
    public let name: String
    public let leftHostID: ManagedHost.ID
    public let rightHostID: ManagedHost.ID
    public let findings: [ComparisonFindingKind]
    public let leftSummary: String?
    public let rightSummary: String?

    public init(
        id: String,
        agent: AgentKind,
        entityKind: ComparisonEntityKind,
        name: String,
        leftHostID: ManagedHost.ID,
        rightHostID: ManagedHost.ID,
        findings: [ComparisonFindingKind],
        leftSummary: String? = nil,
        rightSummary: String? = nil
    ) {
        self.id = id
        self.agent = agent
        self.entityKind = entityKind
        self.name = name
        self.leftHostID = leftHostID
        self.rightHostID = rightHostID
        self.findings = findings
        self.leftSummary = leftSummary
        self.rightSummary = rightSummary
    }
}

public enum HostComparisonEngine {
    public static func compare(
        leftHostID: ManagedHost.ID,
        rightHostID: ManagedHost.ID,
        left: [InventorySnapshot],
        right: [InventorySnapshot]
    ) -> [HostComparisonItem] {
        comparePackages(
            leftHostID: leftHostID,
            rightHostID: rightHostID,
            left: left,
            right: right
        ) + compareStandaloneCapabilities(
            leftHostID: leftHostID,
            rightHostID: rightHostID,
            left: left,
            right: right
        )
    }

    private static func comparePackages(
        leftHostID: ManagedHost.ID,
        rightHostID: ManagedHost.ID,
        left: [InventorySnapshot],
        right: [InventorySnapshot]
    ) -> [HostComparisonItem] {
        let leftItems = packageItems(from: left)
        let rightItems = packageItems(from: right)
        let keys = Set(leftItems.keys).union(rightItems.keys).sorted()

        return keys.map { key in
            let lhs = leftItems[key]
            let rhs = rightItems[key]
            var findings: [ComparisonFindingKind] = []
            if lhs == nil {
                findings = [.onlyOnRight]
            } else if rhs == nil {
                findings = [.onlyOnLeft]
            } else if let lhs, let rhs {
                if lhs.sourceSignature != rhs.sourceSignature {
                    findings.append(.sourceMismatch)
                }
                if lhs.version != rhs.version {
                    findings.append(
                        lhs.version == nil || rhs.version == nil
                            ? .incomparable
                            : .versionMismatch
                    )
                }
                if lhs.state != rhs.state {
                    findings.append(
                        lhs.state == nil || rhs.state == nil
                            ? .unknown
                            : .enabledStateMismatch
                    )
                }
                if lhs.digest != rhs.digest {
                    findings.append(
                        lhs.digest == nil || rhs.digest == nil
                            ? .incomparable
                            : .digestMismatch
                    )
                }
                if findings.isEmpty {
                    findings.append(.matching)
                }
            }

            return HostComparisonItem(
                id: InventoryIdentifier.make(
                    "comparison",
                    key.agent.rawValue,
                    "package",
                    key.name
                ),
                agent: key.agent,
                entityKind: .package,
                name: lhs?.displayName ?? rhs?.displayName ?? key.name,
                leftHostID: leftHostID,
                rightHostID: rightHostID,
                findings: deduplicated(findings),
                leftSummary: lhs?.summary,
                rightSummary: rhs?.summary
            )
        }
    }

    private static func compareStandaloneCapabilities(
        leftHostID: ManagedHost.ID,
        rightHostID: ManagedHost.ID,
        left: [InventorySnapshot],
        right: [InventorySnapshot]
    ) -> [HostComparisonItem] {
        let leftItems = standaloneItems(from: left)
        let rightItems = standaloneItems(from: right)
        let keys = Set(leftItems.keys).union(rightItems.keys).sorted()

        return keys.map { key in
            let lhs = leftItems[key]
            let rhs = rightItems[key]
            let findings: [ComparisonFindingKind]
            if lhs == nil {
                findings = [.onlyOnRight]
            } else if rhs == nil {
                findings = [.onlyOnLeft]
            } else if lhs?.state != rhs?.state {
                findings = lhs?.state == nil || rhs?.state == nil
                    ? [.unknown]
                    : [.enabledStateMismatch]
            } else {
                findings = [.matching]
            }

            return HostComparisonItem(
                id: InventoryIdentifier.make(
                    "comparison",
                    key.agent.rawValue,
                    key.kind.rawValue,
                    key.name
                ),
                agent: key.agent,
                entityKind: .capability,
                name: lhs?.displayName ?? rhs?.displayName ?? key.name,
                leftHostID: leftHostID,
                rightHostID: rightHostID,
                findings: findings,
                leftSummary: lhs?.summary,
                rightSummary: rhs?.summary
            )
        }
    }

    private static func packageItems(
        from snapshots: [InventorySnapshot]
    ) -> [PackageKey: PackageComparisonValue] {
        var result: [PackageKey: PackageComparisonValue] = [:]
        for snapshot in snapshots {
            let sources = Dictionary(
                uniqueKeysWithValues: snapshot.catalogSources.map {
                    ($0.id, $0)
                }
            )
            for package in snapshot.packages.sorted(by: { $0.id < $1.id }) {
                let installation = snapshot.installations.first {
                    $0.packageID == package.id && $0.capabilityID == nil
                } ?? snapshot.installations.first {
                    $0.packageID == package.id
                }
                let source = package.sourceID.flatMap { sources[$0] }
                let key = PackageKey(
                    agent: package.agent,
                    name: package.name.lowercased()
                )
                let value = PackageComparisonValue(
                    displayName: package.displayName,
                    sourceSignature: [
                        source?.kind.rawValue,
                        source?.name,
                        source?.reference,
                        package.repository
                    ]
                    .compactMap { $0 }
                    .joined(separator: "|"),
                    version: installation?.installedVersion ?? package.version,
                    state: installation?.state,
                    digest: package.manifestDigest,
                    summary: summary(
                        version: installation?.installedVersion ?? package.version,
                        state: installation?.state,
                        source: source?.name
                    )
                )
                if result[key] == nil {
                    result[key] = value
                } else if result[key]?.sourceSignature != value.sourceSignature {
                    result[key] = result[key]?.markingAmbiguousSource()
                }
            }
        }
        return result
    }

    private static func standaloneItems(
        from snapshots: [InventorySnapshot]
    ) -> [CapabilityKey: CapabilityComparisonValue] {
        var result: [CapabilityKey: CapabilityComparisonValue] = [:]
        for snapshot in snapshots {
            for capability in snapshot.providedCapabilities
            where capability.packageID == nil {
                let installation = snapshot.installations.first {
                    $0.capabilityID == capability.id
                }
                let key = CapabilityKey(
                    agent: capability.agent,
                    kind: capability.kind,
                    name: capability.name.lowercased()
                )
                result[key] = CapabilityComparisonValue(
                    displayName: capability.displayName,
                    state: installation?.state,
                    summary: installation.map {
                        "\($0.scope.rawValue), \($0.state.rawValue)"
                    }
                )
            }
        }
        return result
    }

    private static func summary(
        version: String?,
        state: EffectiveState?,
        source: String?
    ) -> String? {
        let values = [
            version.map { "version \($0)" },
            state.map(\.rawValue),
            source
        ]
        .compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private static func deduplicated<Value: Hashable>(
        _ values: [Value]
    ) -> [Value] {
        var seen = Set<Value>()
        return values.filter { seen.insert($0).inserted }
    }
}

private struct PackageKey: Hashable, Comparable {
    let agent: AgentKind
    let name: String

    static func < (lhs: PackageKey, rhs: PackageKey) -> Bool {
        (lhs.agent.rawValue, lhs.name) < (rhs.agent.rawValue, rhs.name)
    }
}

private struct CapabilityKey: Hashable, Comparable {
    let agent: AgentKind
    let kind: CapabilityKind
    let name: String

    static func < (lhs: CapabilityKey, rhs: CapabilityKey) -> Bool {
        (lhs.agent.rawValue, lhs.kind.rawValue, lhs.name)
            < (rhs.agent.rawValue, rhs.kind.rawValue, rhs.name)
    }
}

private struct PackageComparisonValue {
    let displayName: String
    let sourceSignature: String
    let version: String?
    let state: EffectiveState?
    let digest: String?
    let summary: String?

    func markingAmbiguousSource() -> PackageComparisonValue {
        PackageComparisonValue(
            displayName: displayName,
            sourceSignature: sourceSignature + "|ambiguous",
            version: version,
            state: state,
            digest: digest,
            summary: summary.map { $0 + ", multiple sources" }
                ?? "multiple sources"
        )
    }
}

private struct CapabilityComparisonValue {
    let displayName: String
    let state: EffectiveState?
    let summary: String?
}
