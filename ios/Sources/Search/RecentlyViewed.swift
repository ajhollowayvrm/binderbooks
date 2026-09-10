import Foundation
import Observation

/// Products opened from search, newest first. Fills the empty-query home until
/// the inventory sections from docs/03 exist. Small, local, disposable.
@MainActor
@Observable
final class RecentlyViewed {
    private(set) var productIds: [Int]
    private let key = "recentlyViewedProductIds"
    static let limit = 30

    init() {
        productIds = UserDefaults.standard.array(forKey: key) as? [Int] ?? []
    }

    func record(_ productId: Int) {
        productIds.removeAll { $0 == productId }
        productIds.insert(productId, at: 0)
        if productIds.count > Self.limit {
            productIds.removeLast(productIds.count - Self.limit)
        }
        UserDefaults.standard.set(productIds, forKey: key)
    }

    func clear() {
        productIds = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
