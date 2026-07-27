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
        let argus = ManagedHost(
            name: "Argus",
            connection: .ssh(alias: "argus")
        )

        hosts = [local, argus]
        selectedHostID = local.id
    }

    var selectedHost: ManagedHost? {
        hosts.first { $0.id == selectedHostID }
    }
}

