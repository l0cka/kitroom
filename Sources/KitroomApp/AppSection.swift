import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case hosts
    case inventory
    case catalogue
    case activity
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .hosts:
            "Hosts"
        case .inventory:
            "Inventory"
        case .catalogue:
            "Catalogue"
        case .activity:
            "Activity"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .hosts:
            "server.rack"
        case .inventory:
            "shippingbox"
        case .catalogue:
            "books.vertical"
        case .activity:
            "clock.arrow.circlepath"
        case .settings:
            "gear"
        }
    }
}
