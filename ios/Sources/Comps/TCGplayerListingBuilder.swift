import Foundation
import Observation

/// Prices each line of a listing plan against TCGplayer, one line at a time.
///
/// One call per line finds the cheapest listing and its SKU id. One call per
/// product reads TCGplayer's exact name and its SKU list, and both are kept for
/// the other lines of the same product. Every product needs that call, because
/// Seller Portal rejects a row whose name is not TCGplayer's exact name, and a
/// line that nobody sells takes its SKU id from the list. The pause is courtesy
/// to an endpoint that has no published rate limit.
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
        floorCents: Int = TCGplayerListingExport.defaultFloorCents,
        pause: Duration = .milliseconds(200)
    ) async -> Outcome {
        var outcome = Outcome()
        outcome.report.skipped = plan.skipped
        outcome.report.floorCents = floorCents
        isRunning = true
        total = plan.lines.count
        done = 0
        defer { isRunning = false }
        var productDetails: [Int: TCGplayerMarketClient.Details] = [:]

        for line in plan.lines {
            if Task.isCancelled {
                outcome.report.stoppedBy = "cancelled"
                break
            }
            defer { done += 1 }
            let key = line.key
            do {
                let lowest = try await market.cheapestListing(productId: key.productId, condition: key.condition, printing: key.printing, language: key.language)
                // Checked before the details call, which such a card does not
                // need. A SKU TCGplayer lists keeps its row, so its stock
                // still comes out right.
                if line.listed == 0,
                   TCGplayerListingExport.isBelowFloor(lowest: lowest, marketCents: line.marketCents, floorCents: floorCents) {
                    outcome.report.belowFloor += 1
                    continue
                }
                let skuId: Int
                let productName: String?
                if let stock = line.stock {
                    // The pricing export already names the SKU with
                    // TCGplayer's exact name.
                    skuId = stock.skuId
                    productName = stock.line.productName
                } else {
                    let details: TCGplayerMarketClient.Details
                    if let known = productDetails[key.productId] {
                        details = known
                    } else {
                        details = try await market.details(productId: key.productId)
                        productDetails[key.productId] = details
                    }
                    guard let found = lowest?.skuId ?? TCGplayerListingExport.sku(in: details.skus, for: key)?.skuId else {
                        outcome.report.noSku += 1
                        continue
                    }
                    skuId = found
                    productName = details.productName
                }
                guard let price = TCGplayerListingExport.price(lowest: lowest, marketCents: line.marketCents, shippingChargedCents: shippingChargedCents) else {
                    outcome.report.unpriced += 1
                    continue
                }
                outcome.rows.append(.init(
                    line: line, skuId: skuId, priceCents: price.cents, source: price.source, lowest: lowest,
                    productName: productName
                ))
                switch price.source {
                case .liveLow: outcome.report.liveLow += 1
                case .market: outcome.report.market += 1
                case .atMarket: outcome.report.atMarket += 1
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
