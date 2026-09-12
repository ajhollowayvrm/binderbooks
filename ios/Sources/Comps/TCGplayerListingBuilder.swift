import Foundation
import Observation

/// Prices each line of a listing plan against TCGplayer, one line at a time.
///
/// One call per line finds the cheapest listing and its SKU id. A line that
/// nobody sells costs a second call, for the product's SKU list, and that list
/// is kept for the other lines of the same product. The pause is courtesy to
/// an endpoint that has no published rate limit.
@MainActor
@Observable
final class TCGplayerListingBuilder {
    struct Outcome: Equatable {
        var rows: [TCGplayerListingExport.Priced] = []
        var report = TCGplayerListingExport.Report()
    }

    private(set) var isRunning = false
    private(set) var done = 0
    private(set) var total = 0

    func build(
        _ plan: TCGplayerListingExport.Plan,
        shippingChargedCents: Int,
        market: some TCGplayerMarket,
        pause: Duration = .milliseconds(200)
    ) async -> Outcome {
        var outcome = Outcome()
        outcome.report.skipped = plan.skipped
        isRunning = true
        total = plan.lines.count
        done = 0
        defer { isRunning = false }
        var skuLists: [Int: [TCGplayerMarketClient.Sku]] = [:]

        for line in plan.lines {
            if Task.isCancelled {
                outcome.report.stoppedBy = "cancelled"
                break
            }
            defer { done += 1 }
            let key = line.key
            do {
                let lowest = try await market.cheapestListing(productId: key.productId, condition: key.condition, printing: key.printing, language: key.language)
                var skuId = lowest?.skuId
                if skuId == nil {
                    let skus: [TCGplayerMarketClient.Sku]
                    if let known = skuLists[key.productId] {
                        skus = known
                    } else {
                        skus = try await market.skus(productId: key.productId)
                        skuLists[key.productId] = skus
                    }
                    skuId = TCGplayerListingExport.sku(in: skus, for: key)?.skuId
                }
                guard let skuId else {
                    outcome.report.noSku += 1
                    continue
                }
                guard let price = TCGplayerListingExport.price(lowest: lowest, marketCents: line.marketCents, shippingChargedCents: shippingChargedCents) else {
                    outcome.report.unpriced += 1
                    continue
                }
                outcome.rows.append(.init(line: line, skuId: skuId, priceCents: price.cents, source: price.source, lowest: lowest))
                switch price.source {
                case .liveLow: outcome.report.liveLow += 1
                case .market: outcome.report.market += 1
                }
            } catch TCGplayerMarketClient.Failure.http(let code) where code == 403 || code == 429 {
                // A refusal applies to every later call too.
                outcome.report.stoppedBy = "TCGplayer answered \(code)"
                break
            } catch {
                outcome.report.failed += 1
            }
            if done + 1 < total { try? await Task.sleep(for: pause) }
        }
        return outcome
    }
}
