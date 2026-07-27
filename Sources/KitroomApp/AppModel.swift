import Foundation
import KitroomCore

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedSection: AppSection? = .hosts
    @Published var selectedHostID: ManagedHost.ID?

    let hosts: [ManagedHost]

    init(hosts: [ManagedHost] = [ManagedHost(name: "This Mac", connection: .local)]) {
        self.hosts = hosts
        selectedHostID = hosts.first?.id
    }

    var selectedHost: ManagedHost? {
        hosts.first { $0.id == selectedHostID }
    }

    var remoteHostCount: Int {
        hosts.filter(\.connection.isRemote).count
    }
}
