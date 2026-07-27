import Foundation

public enum InventoryFreshness: String, Codable, Hashable, Sendable {
    case current
    case stale
    case futureDated

    public static func evaluate(
        capturedAt: Date,
        now: Date,
        staleAfter: TimeInterval = 15 * 60
    ) -> InventoryFreshness {
        if capturedAt > now.addingTimeInterval(60) {
            return .futureDated
        }
        return now.timeIntervalSince(capturedAt) > staleAfter
            ? .stale
            : .current
    }
}

public enum UpdateStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case upToDate
    case updateAvailable
    case unknown
    case incomparable
}

public struct InventoryQuery: Hashable, Sendable {
    public var searchText: String
    public var agent: AgentKind?
    public var kind: CapabilityKind?
    public var scope: InventoryScope?
    public var origin: InstallationOrigin?
    public var state: EffectiveState?
    public var updateStatus: UpdateStatus?

    public init(
        searchText: String = "",
        agent: AgentKind? = nil,
        kind: CapabilityKind? = nil,
        scope: InventoryScope? = nil,
        origin: InstallationOrigin? = nil,
        state: EffectiveState? = nil,
        updateStatus: UpdateStatus? = nil
    ) {
        self.searchText = searchText
        self.agent = agent
        self.kind = kind
        self.scope = scope
        self.origin = origin
        self.state = state
        self.updateStatus = updateStatus
    }

    public func matches(
        package: PackageRecord?,
        capability: ProvidedCapability?,
        installation: InstallationRecord?
    ) -> Bool {
        if let agent {
            let itemAgent = capability?.agent ?? package?.agent
            guard itemAgent == agent else {
                return false
            }
        }
        if let kind, capability?.kind != kind {
            return false
        }
        if let scope, installation?.scope != scope {
            return false
        }
        if let origin, installation?.origin != origin {
            return false
        }
        if let state, installation?.state != state {
            return false
        }
        if let updateStatus {
            let actual = installation?.updateStatus ?? .unknown
            guard actual == updateStatus else {
                return false
            }
        }

        let needle = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !needle.isEmpty else {
            return true
        }
        let haystack = [
            package?.name,
            package?.displayName,
            package?.publisher,
            package?.description,
            capability?.name,
            capability?.displayName
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(needle)
    }
}

public struct InventoryAccessibilityDescription: Hashable, Sendable {
    public let label: String
    public let value: String
    public let hint: String

    public init(
        package: PackageRecord?,
        capability: ProvidedCapability?,
        installation: InstallationRecord?,
        evidenceStatus: EvidenceStatus?
    ) {
        label = capability?.displayName
            ?? package?.displayName
            ?? "Unknown inventory item"
        let components = [
            capability?.kind.accessibilityName,
            installation?.scope.accessibilityName,
            installation?.origin.accessibilityName,
            installation?.state.accessibilityName,
            evidenceStatus.map { "Evidence \($0.rawValue)" }
        ]
        .compactMap { $0 }
        value = components.joined(separator: ", ")
        hint = "Shows source and evidence details"
    }
}

private extension CapabilityKind {
    var accessibilityName: String {
        rawValue
    }
}

private extension InventoryScope {
    var accessibilityName: String {
        rawValue
    }
}

private extension InstallationOrigin {
    var accessibilityName: String {
        rawValue
    }
}

private extension EffectiveState {
    var accessibilityName: String {
        rawValue
    }
}
