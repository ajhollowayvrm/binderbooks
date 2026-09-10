import Foundation

/// Every push in the app. Declared once at the root `NavigationStack`, so a
/// destination never depends on a pushed view staying alive.
enum AppRoute: Hashable {
    case inventory
    case settings
    case catalogStatus
    case ownedCard(UUID)
}
