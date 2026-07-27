import CryptoKit
import Foundation

public protocol HostDiscovering: Sendable {
    func discover(
        host: ManagedHost,
        resolvedHost: String?
    ) async -> HostDiscoverySnapshot
}

public struct HostDiscoveryService: HostDiscovering {
    private let connectionFactory: any HostConnectionFactory
    private let clock: any KitroomClock
    private let targetEnvironment: [String: String]

    public init(
        connectionFactory: any HostConnectionFactory,
        clock: any KitroomClock = SystemKitroomClock(),
        targetEnvironment: [String: String] = HostEnvironment.standard
    ) {
        self.connectionFactory = connectionFactory
        self.clock = clock
        self.targetEnvironment = targetEnvironment
    }

    public func discover(
        host: ManagedHost,
        resolvedHost: String? = nil
    ) async -> HostDiscoverySnapshot {
        let attemptedAt = clock.now
        let timer = ContinuousClock()
        let startedAt = timer.now

        do {
            let session = try await connectionFactory.connect(to: host)
            let operatingSystemResult = try await run(
                session,
                executable: "/usr/bin/uname",
                arguments: ["-s"]
            )

            guard case let .success(operatingSystem) = operatingSystemResult else {
                return partialSnapshot(
                    host: host,
                    attemptedAt: attemptedAt,
                    resolvedHost: resolvedHost,
                    startedAt: startedAt,
                    timer: timer,
                    issue: operatingSystemResult.issue(
                        summary: "Platform probe failed"
                    )
                )
            }

            async let architectureResult = runSafely(
                session,
                executable: "/usr/bin/uname",
                arguments: ["-m"]
            )
            async let homeResult = runSafely(
                session,
                executable: "/usr/bin/printenv",
                arguments: ["HOME"]
            )
            async let shellResult = runSafely(
                session,
                executable: "/usr/bin/printenv",
                arguments: ["SHELL"]
            )
            async let hostnameResult = runSafely(
                session,
                executable: "/bin/hostname"
            )

            let (architecture, home, shell, hostname) = await (
                architectureResult,
                homeResult,
                shellResult,
                hostnameResult
            )

            var issues = [architecture, home, shell, hostname].compactMap {
                $0.issue(summary: "Host metadata probe failed")
            }
            let platform = HostPlatform(
                operatingSystem: operatingSystem,
                architecture: architecture.value,
                homeDirectory: home.value,
                shell: shell.value,
                hostname: hostname.value
            )

            let identity = await discoverIdentity(
                session: session,
                platform: platform
            )
            if identity.kind == .derived {
                issues.append(
                    InventoryIssue(
                        summary: "Host identity is derived",
                        detail: "The platform did not expose a stable machine identifier."
                    )
                )
            }

            let paths = await discoverPathAccess(
                session: session,
                homeDirectory: home.value
            )
            let agents = await discoverAgents(session: session)
            if agents.contains(where: { $0.availability == .unknown }) {
                issues.append(
                    InventoryIssue(
                        summary: "Agent detection was incomplete",
                        detail: "At least one agent executable could not be checked."
                    )
                )
            }

            let completedAt = clock.now
            return HostDiscoverySnapshot(
                hostID: host.id,
                attemptedAt: attemptedAt,
                completedAt: completedAt,
                connectionState: issues.isEmpty ? .reachable : .partialDiscovery,
                resolvedHost: resolvedHost,
                platform: platform,
                identity: identity,
                pathAccess: paths,
                agents: agents,
                latencyMilliseconds: milliseconds(
                    startedAt.duration(to: timer.now)
                ),
                issues: issues
            )
        } catch let error as HostSessionError {
            return unavailableSnapshot(
                host: host,
                attemptedAt: attemptedAt,
                resolvedHost: resolvedHost,
                startedAt: startedAt,
                timer: timer,
                error: error
            )
        } catch {
            return unavailableSnapshot(
                host: host,
                attemptedAt: attemptedAt,
                resolvedHost: resolvedHost,
                startedAt: startedAt,
                timer: timer,
                error: .transportFailure(error.localizedDescription)
            )
        }
    }

    private func discoverIdentity(
        session: any HostSession,
        platform: HostPlatform
    ) async -> HostIdentityEvidence {
        if platform.operatingSystem.caseInsensitiveCompare("Darwin") == .orderedSame {
            let result = try? await run(
                session,
                executable: "/usr/sbin/ioreg",
                arguments: ["-rd1", "-c", "IOPlatformExpertDevice"]
            )
            if let value = result?.value,
               let uuid = platformUUID(from: value) {
                return HostIdentityEvidence(
                    kind: .platformUUID,
                    value: uuid,
                    source: "IOPlatformUUID"
                )
            }
        }

        if platform.operatingSystem.caseInsensitiveCompare("Linux") == .orderedSame {
            let result = try? await run(
                session,
                executable: "/bin/cat",
                arguments: ["/etc/machine-id"]
            )
            if let machineID = result?.value, !machineID.isEmpty {
                return HostIdentityEvidence(
                    kind: .machineID,
                    value: machineID,
                    source: "/etc/machine-id"
                )
            }
        }

        let material = [
            platform.hostname ?? "",
            platform.operatingSystem,
            platform.architecture ?? "",
            platform.homeDirectory ?? ""
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return HostIdentityEvidence(
            kind: .derived,
            value: digest,
            source: "hostname, platform, architecture, and home directory"
        )
    }

    private func discoverPathAccess(
        session: any HostSession,
        homeDirectory: String?
    ) async -> [HostPathAccess] {
        guard let homeDirectory else {
            return []
        }

        var results: [HostPathAccess] = []
        for component in [".codex", ".agents", ".claude", ".ssh"] {
            let path = URL(fileURLWithPath: homeDirectory)
                .appendingPathComponent(component)
                .path
            let exists = try? await run(
                session,
                executable: "/usr/bin/test",
                arguments: ["-e", path]
            )

            guard exists?.succeeded == true else {
                results.append(HostPathAccess(path: path, state: .missing))
                continue
            }

            let readable = try? await run(
                session,
                executable: "/usr/bin/test",
                arguments: ["-r", path]
            )
            let writable = try? await run(
                session,
                executable: "/usr/bin/test",
                arguments: ["-w", path]
            )

            let state: HostPathAccessState
            if readable?.succeeded == true, writable?.succeeded == true {
                state = .readWrite
            } else if readable?.succeeded == true {
                state = .readOnly
            } else if readable != nil {
                state = .denied
            } else {
                state = .unknown
            }
            results.append(HostPathAccess(path: path, state: state))
        }
        return results
    }

    private func discoverAgents(
        session: any HostSession
    ) async -> [DiscoveredAgent] {
        var agents: [DiscoveredAgent] = []

        for agent in AgentKind.allCases {
            let executableName = agent == .codex ? "codex" : "claude"
            let lookup = try? await run(
                session,
                executable: "/usr/bin/which",
                arguments: [executableName]
            )

            guard let lookup else {
                agents.append(
                    DiscoveredAgent(agent: agent, availability: .unknown)
                )
                continue
            }
            guard lookup.succeeded, let executablePath = lookup.value else {
                agents.append(
                    DiscoveredAgent(agent: agent, availability: .notInstalled)
                )
                continue
            }

            let version = try? await run(
                session,
                executable: executablePath,
                arguments: ["--version"]
            )
            agents.append(
                DiscoveredAgent(
                    agent: agent,
                    availability: .available,
                    executablePath: executablePath,
                    version: version?.value
                )
            )
        }

        return agents
    }

    private func run(
        _ session: any HostSession,
        executable: String,
        arguments: [String] = []
    ) async throws -> ProbeResult {
        let result = try await session.execute(
            CommandRequest(
                executable: executable,
                arguments: arguments,
                environment: session.host.connection == .local
                    ? targetEnvironment
                    : [:],
                timeout: .seconds(10),
                maximumOutputBytes: 262_144
            )
        )

        guard result.succeeded else {
            return .failure(
                "Exit \(result.exitCode.map(String.init) ?? "signal"); "
                    + bounded(result.standardError)
            )
        }

        return .success(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func runSafely(
        _ session: any HostSession,
        executable: String,
        arguments: [String] = []
    ) async -> ProbeResult {
        do {
            return try await run(
                session,
                executable: executable,
                arguments: arguments
            )
        } catch {
            return .failure(bounded(error.localizedDescription))
        }
    }

    private func partialSnapshot(
        host: ManagedHost,
        attemptedAt: Date,
        resolvedHost: String?,
        startedAt: ContinuousClock.Instant,
        timer: ContinuousClock,
        issue: InventoryIssue?
    ) -> HostDiscoverySnapshot {
        HostDiscoverySnapshot(
            hostID: host.id,
            attemptedAt: attemptedAt,
            completedAt: clock.now,
            connectionState: .partialDiscovery,
            resolvedHost: resolvedHost,
            latencyMilliseconds: milliseconds(startedAt.duration(to: timer.now)),
            issues: issue.map { [$0] } ?? []
        )
    }

    private func unavailableSnapshot(
        host: ManagedHost,
        attemptedAt: Date,
        resolvedHost: String?,
        startedAt: ContinuousClock.Instant,
        timer: ContinuousClock,
        error: HostSessionError
    ) -> HostDiscoverySnapshot {
        let state: HostConnectionState
        switch error {
        case .authenticationRequired:
            state = .authenticationRequired
        case .hostIdentityChanged:
            state = .hostIdentityChanged
        case .cancelled:
            state = .cancelled
        default:
            state = .unreachable
        }

        return HostDiscoverySnapshot(
            hostID: host.id,
            attemptedAt: attemptedAt,
            completedAt: clock.now,
            connectionState: state,
            resolvedHost: resolvedHost,
            latencyMilliseconds: milliseconds(startedAt.duration(to: timer.now)),
            issues: [
                InventoryIssue(
                    summary: "Host discovery failed",
                    detail: error.localizedDescription
                )
            ]
        )
    }

    private func platformUUID(from output: String) -> String? {
        output
            .split(whereSeparator: { $0 == "\"" || $0.isWhitespace })
            .map(String.init)
            .first {
                $0.count == 36
                    && $0.filter { $0 == "-" }.count == 4
            }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return (Double(components.seconds) * 1_000)
            + (Double(components.attoseconds) / 1_000_000_000_000_000)
    }

    private func bounded(_ value: String) -> String {
        String(
            value
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .prefix(500)
        )
    }
}

private enum ProbeResult: Sendable {
    case success(String)
    case failure(String)

    var value: String? {
        if case let .success(value) = self {
            value
        } else {
            nil
        }
    }

    var succeeded: Bool {
        if case .success = self {
            true
        } else {
            false
        }
    }

    func issue(summary: String) -> InventoryIssue? {
        if case let .failure(detail) = self {
            InventoryIssue(summary: summary, detail: detail)
        } else {
            nil
        }
    }
}
