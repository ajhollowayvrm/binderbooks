import Foundation
import SwiftData

/// Marks `isSealedSelf` on every sealed box already in inventory, once.
///
/// The flag arrived after boxes were already in his store: `AddToInventorySheet`
/// wrote them with no way to say "this card is the box itself." Without this,
/// an unopened box he added before the rip feature shipped shows no Rip option,
/// even though the code is live and the box is sitting right there.
///
/// A card counts as a box's self-card when it never came from a scan and its
/// line's product matches its own: exactly the shape `AddToInventorySheet`
/// writes for a sealed product, and never the shape a rip's pulled cards take
/// (a different product, on the same line, with a `scanSession`). A line
/// already marked ripped is skipped on purpose — his imported ledger records an
/// opened box with no self-card at all, so one somehow present there is stale
/// data, not a box waiting to be opened.
enum SealedSelfBackfill {
    static let key = "sealedSelfBackfilled.v1"

    @MainActor
    static func run(_ context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: key) else { return }
        let cards = (try? context.fetch(FetchDescriptor<OwnedCard>())) ?? []
        for card in cards {
            guard let item = card.sourceItem, item.isSealed, !item.isRipped else { continue }
            guard card.scanSession == nil, card.productId == item.productId else { continue }
            card.isSealedSelf = true
        }
        try? context.save()
        defaults.set(true, forKey: key)
    }
}
