import Foundation

public enum DiagnosticReportBuilder {
    public static func makeReport(
        generatedAt: Date,
        hosts: [ManagedHost],
        discoveries: [HostDiscoverySnapshot],
        inventories: [InventorySnapshot]
    ) throws -> Data {
        let report = DiagnosticReport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            hosts: hosts.map { host in
                DiagnosticHost(
                    id: host.id,
                    displayName: SensitiveValueRedactor.redact(host.name),
                    transport: host.connection.isRemote ? "ssh" : "local"
                )
            },
            discoveries: discoveries.map { snapshot in
                DiagnosticDiscovery(
                    hostID: snapshot.hostID,
                    attemptedAt: snapshot.attemptedAt,
                    completedAt: snapshot.completedAt,
                    state: snapshot.connectionState.rawValue,
                    operatingSystem: snapshot.platform?.operatingSystem,
                    architecture: snapshot.platform?.architecture,
                    agents: snapshot.agents.map {
                        DiagnosticAgent(
                            agent: $0.agent.rawValue,
                            availability: $0.availability.rawValue,
                            version: $0.version
                        )
                    },
                    issueSummaries: snapshot.issues.map {
                        SensitiveValueRedactor.redact($0.summary)
                    }
                )
            },
            inventories: inventories.map { snapshot in
                DiagnosticInventory(
                    hostID: snapshot.hostID,
                    agent: snapshot.agent.rawValue,
                    capturedAt: snapshot.capturedAt,
                    status: snapshot.status.rawValue,
                    agentVersion: snapshot.agentVersion,
                    packageCount: snapshot.packages.count,
                    capabilityCount: snapshot.providedCapabilities.count,
                    installationCount: snapshot.installations.count,
                    evidence: snapshot.evidence.map {
                        DiagnosticEvidence(
                            probeName: $0.probeName,
                            parserVersion: $0.parserVersion,
                            status: $0.status.rawValue
                        )
                    },
                    issueSummaries: snapshot.issues.map {
                        SensitiveValueRedactor.redact($0.summary)
                    }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }
}

private struct DiagnosticReport: Encodable {
    let schemaVersion: Int
    let generatedAt: Date
    let hosts: [DiagnosticHost]
    let discoveries: [DiagnosticDiscovery]
    let inventories: [DiagnosticInventory]
}

private struct DiagnosticHost: Encodable {
    let id: UUID
    let displayName: String
    let transport: String
}

private struct DiagnosticDiscovery: Encodable {
    let hostID: UUID
    let attemptedAt: Date
    let completedAt: Date?
    let state: String
    let operatingSystem: String?
    let architecture: String?
    let agents: [DiagnosticAgent]
    let issueSummaries: [String]
}

private struct DiagnosticAgent: Encodable {
    let agent: String
    let availability: String
    let version: String?
}

private struct DiagnosticInventory: Encodable {
    let hostID: UUID
    let agent: String
    let capturedAt: Date
    let status: String
    let agentVersion: String?
    let packageCount: Int
    let capabilityCount: Int
    let installationCount: Int
    let evidence: [DiagnosticEvidence]
    let issueSummaries: [String]
}

private struct DiagnosticEvidence: Encodable {
    let probeName: String
    let parserVersion: String
    let status: String
}
