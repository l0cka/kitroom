import Foundation

public enum AgentKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case codex
    case claude

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .codex:
            "Codex"
        case .claude:
            "Claude Code"
        }
    }
}

