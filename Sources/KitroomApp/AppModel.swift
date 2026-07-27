import Foundation
import KitroomCore

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedHostID: ManagedHost.ID?

    let hosts: [ManagedHost]

    init() {
        let local = ManagedHost(
            name: "This Mac",
            connection: .local
        )
        let remote = ManagedHost(
            name: "Build Server",
            connection: .ssh(alias: "build-server")
        )

        hosts = [local, remote]
        selectedHostID = local.id
    }

    var selectedHost: ManagedHost? {
        hosts.first { $0.id == selectedHostID }
    }
}
