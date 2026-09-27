import Foundation
import Observation

/// TCGplayer's prices for one SKU: a product in one printing, condition, and
/// language.
///
/// AJ asked on 2026-09-27 for prices that follow the condition: a card set to
/// Damaged must show what a Damaged copy sells for. The catalog cannot answer
/// that. TCGCSV has one row for each printing, and its low price is the
/// cheapest listing in any condition. So the app asks TCGplayer for each SKU
/// it holds, and keeps the answer here for a day.
///
/// The prices are a cache, not his data. They live in a file in Application
/// Support, apart from the collection store and the export. A lost file costs
/// one fetch.
@MainActor
@Observable
final class ConditionPrices {
    typealias Key = TCGplayerListingExport.SkuKey

    struct Entry: Codable, Equatable, Sendable {
        /// Nil when TCGplayer has no SKU for the key, for example a condition
        /// it does not sell.
        var skuId: Int?
        var marketCents: Int?
        var lowCents: Int?
        var fetchedAt: Date

        var hasPrice: Bool { marketCents != nil || lowCents != nil }
    }

    /// A day, the same as TCGCSV's update.
    static let maxAge: TimeInterval = 24 * 60 * 60

    private(set) var entries: [String: Entry] = [:]
    /// Runs can overlap: the inventory page fetches every card while the
    /// card screen fetches the one whose condition just changed.
    private(set) var runs = 0
    var isFetching: Bool { runs > 0 }
    private let fileURL: URL?

    /// `fileURL` nil keeps the prices in memory only, for the tests.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    static var defaultFileURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "ConditionPrices.json")
    }

    static func id(_ key: Key) -> String {
        "\(key.productId)|\(key.printing)|\(key.condition)|\(key.language)".lowercased()
    }

    func entry(for key: Key) -> Entry? { entries[Self.id(key)] }

    func isFresh(_ key: Key, now: Date = Date()) -> Bool {
        guard let entry = entry(for: key) else { return false }
        return now.timeIntervalSince(entry.fetchedAt) < Self.maxAge
    }

    /// Asks TCGplayer for each key with no fresh entry. One details call for
    /// each product finds the SKU ids, one call finds every market price, and
    /// one call for each SKU finds its cheapest listing. Returns the number of
    /// keys it priced.
    ///
    /// A 403 or 429 stops the run, because it applies to every later call. A
    /// cancel stops it too. Both keep what the run fetched so far.
    @discardableResult
    func fetch(_ keys: [Key], client: some TCGplayerSkuPricing, now: Date = Date(), pause: Duration = .milliseconds(100)) async -> Int {
        let wanted = Array(Set(keys.filter { !isFresh($0, now: now) }))
            .sorted { Self.id($0) < Self.id($1) }
        guard !wanted.isEmpty else { return 0 }
        runs += 1
        defer {
            runs -= 1
            save()
        }

        var skuIds: [Key: Int] = [:]
        var known: Set<Key> = []
        for productId in Set(wanted.map(\.productId)).sorted() {
            if Task.isCancelled { return 0 }
            do {
                let skus = try await client.details(productId: productId).skus
                for key in wanted where key.productId == productId {
                    known.insert(key)
                    skuIds[key] = TCGplayerListingExport.sku(in: skus, for: key)?.skuId
                }
            } catch {
                // Retried on the next run. A refusal stops this run.
                if Self.isRefusal(error) { return 0 }
            }
            try? await Task.sleep(for: pause)
        }

        var markets: [Int: Int] = [:]
        let ids = Array(Set(skuIds.values)).sorted()
        for start in stride(from: 0, to: ids.count, by: 100) {
            do {
                markets.merge(try await client.marketPrices(skuIds: Array(ids[start ..< min(start + 100, ids.count)]))) { $1 }
            } catch {
                return 0
            }
        }

        var priced = 0
        for key in wanted where known.contains(key) {
            if Task.isCancelled { break }
            guard let skuId = skuIds[key] else {
                entries[Self.id(key)] = Entry(skuId: nil, fetchedAt: now)
                continue
            }
            do {
                let low = try await client.lowestPrice(productId: key.productId, condition: key.condition, printing: key.printing, language: key.language)
                entries[Self.id(key)] = Entry(skuId: skuId, marketCents: markets[skuId], lowCents: low, fetchedAt: now)
                priced += 1
            } catch {
                if Self.isRefusal(error) { break }
            }
            try? await Task.sleep(for: pause)
        }
        return priced
    }

    private static func isRefusal(_ error: Error) -> Bool {
        if case TCGplayerMarketClient.Failure.http(let code) = error { return code == 403 || code == 429 }
        return false
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
