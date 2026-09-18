import Foundation
import SwiftData

/// Deletes the Simplified Chinese cards, once.
///
/// AJ dropped Simplified Chinese on 2026-09-17. PikaQian had too few prices to
/// decide which cards to list on eBay, because these cards rarely sell. Their
/// catalog went with it, so the cards could never show a name or a price
/// again. He records a Chinese sale with no card and types the price. See
/// "Simplified Chinese removed" in docs/02.
///
/// A Chinese card's `productId` was in the range the Chinese catalog builder
/// gave it, from 1,000,000,000 up to 2,000,000,000. No TCGplayer id comes near
/// it. A purchase keeps its cost, the same as any card delete.
enum ChineseRemoval {
    static let key = "chineseCardsRemoved.v1"
    static let ids = 1_000_000_000 ..< 2_000_000_000

    @MainActor
    static func run(_ context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: key) else { return }
        let low = ids.lowerBound
        let high = ids.upperBound
        let descriptor = FetchDescriptor<OwnedCard>(predicate: #Predicate { $0.productId >= low && $0.productId < high })
        guard let cards = try? context.fetch(descriptor) else { return }
        for card in cards { context.delete(card) }
        // Only a save that worked marks it done, so a failure runs again at
        // the next launch.
        do {
            try context.save()
            defaults.set(true, forKey: key)
        } catch {}
    }
}
