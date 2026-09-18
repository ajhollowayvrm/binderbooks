import Foundation

/// Every push in the app. Declared once at the root `NavigationStack`, so a
/// destination never depends on a pushed view staying alive. Inventory is the
/// root, not a push.
enum AppRoute: Hashable {
    case settings
    case catalogStatus
    case ownedCard(UUID)
    /// The copies of one card, keyed by the copy the cell drew. The view
    /// derives the rest from the live inventory, so a copy sold or deleted
    /// while the screen is open drops out of it.
    case cardStack(UUID)
    case ledger
}

import SwiftUI

extension EnvironmentValues {
    /// Pushes a route onto the root stack. For a cell that a long press also
    /// acts on: a `NavigationLink` there takes the lift that ends the long
    /// press as a tap, and opens the card he meant to select.
    @Entry var pushRoute: (AppRoute) -> Void = { _ in }
}
