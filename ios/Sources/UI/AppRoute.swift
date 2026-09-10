import Foundation

/// Every push in the app. Declared once at the root `NavigationStack`, so a
/// destination never depends on a pushed view staying alive. Inventory is the
/// root, not a push.
enum AppRoute: Hashable {
    case settings
    case catalogStatus
    case ownedCard(UUID)
    case ledger
}
