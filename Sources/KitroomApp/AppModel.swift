import Foundation
import KitroomCore

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection? = .hosts
    @Published var selectedHostID: ManagedHost.ID?

    @Published private(set) var hosts: [ManagedHost]

    let dependencies: AppDependencies

    private var hasStarted = false

    init(
        hosts: [ManagedHost] = [ManagedHost(name: "This Mac", connection: .local)],
        dependencies: AppDependencies = .live()
    ) {
        self.hosts = hosts
        self.dependencies = dependencies
        selectedHostID = hosts.first?.id
    }

    var selectedHost: ManagedHost? {
        hosts.first { $0.id == selectedHostID }
    }

    var remoteHostCount: Int {
        hosts.filter(\.connection.isRemote).count
    }

    func start() async {
        guard !hasStarted else {
            return
        }

        hasStarted = true
        dependencies.logger.record(
            KitroomLogEvent(
                level: .info,
                category: "lifecycle",
                name: "app-started",
                publicMetadata: ["hostCount": String(hosts.count)]
            )
        )

        do {
            let persistedHosts = try await dependencies.persistence.loadHosts()

            if persistedHosts.isEmpty {
                try await dependencies.persistence.saveHosts(hosts)
            } else {
                hosts = persistedHosts
                selectedHostID = persistedHosts.first?.id
            }
        } catch {
            dependencies.logger.record(
                KitroomLogEvent(
                    level: .error,
                    category: "persistence",
                    name: "host-load-failed",
                    privateContext: String(describing: error)
                )
            )
        }
    }
}
