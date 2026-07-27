import CryptoKit
import Foundation

public struct ApprovedPackageSource: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let agent: AgentKind
    public let reference: String
    public let approvedAt: Date

    public init(
        agent: AgentKind,
        reference: String,
        approvedAt: Date
    ) {
        self.agent = agent
        self.reference = reference
        self.approvedAt = approvedAt
        id = Self.identifier(agent: agent, reference: reference)
    }

    public static func identifier(
        agent: AgentKind,
        reference: String
    ) -> String {
        SHA256.hash(
            data: Data("\(agent.rawValue)\u{1f}\(reference)".utf8)
        )
        .map { String(format: "%02x", $0) }
        .joined()
    }
}

public enum PackageSourceTrustError: LocalizedError, Equatable, Sendable {
    case marketplaceSourceRequired
    case stableReferenceRequired
    case invalidReference
    case digestEvidenceRequired

    public var errorDescription: String? {
        switch self {
        case .marketplaceSourceRequired:
            "Only an agent-reported marketplace source can be allowed."
        case .stableReferenceRequired:
            "The marketplace did not report a stable source reference."
        case .invalidReference:
            "The marketplace source reference is empty, oversized, or contains control characters."
        case .digestEvidenceRequired:
            "Install and update are blocked because the catalogue did not provide package digest evidence."
        }
    }
}

public enum PackageSourceTrustPolicy {
    public static func validatedReference(
        for source: CatalogSource
    ) throws -> String {
        guard source.kind == .marketplace else {
            throw PackageSourceTrustError.marketplaceSourceRequired
        }
        guard let reference = source.reference else {
            throw PackageSourceTrustError.stableReferenceRequired
        }
        guard !reference.isEmpty,
              reference.utf8.count <= 2_048,
              !reference.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw PackageSourceTrustError.invalidReference
        }
        return reference
    }

    public static func allowsCodeIntroduction(
        package: PackageRecord,
        state: CataloguePackageState?,
        source: CatalogSource,
        approvals: Set<ApprovedPackageSource.ID>
    ) -> Bool {
        guard let reference = try? validatedReference(for: source),
              approvals.contains(
                  ApprovedPackageSource.identifier(
                      agent: source.agent,
                      reference: reference
                  )
              ),
              let digest = package.manifestDigest,
              !digest.isEmpty,
              state?.integrity == .digestDeclared
                || state?.integrity == .digestVerified else {
            return false
        }
        return true
    }
}
