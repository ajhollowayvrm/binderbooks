import Foundation

/// What an order's fees and postage probably were, for an order that arrived
/// with neither.
///
/// The sold-orders CSV has no fee column, and he cannot get the fees. A rate
/// alone gets a small order wrong: a $1.56 TCGplayer order paid $0.51, because
/// part of the fee is fixed per order. So the fee is a fixed amount plus a
/// rate, fitted by least squares to his own orders on the same channel.
/// Postage is the median of what he recorded paying on the channel, because a
/// stamp costs the same on a $1 card as on a $20 card.
///
/// `Decimal` does the fit, and each figure rounds to cents once.
struct FeeEstimate: Equatable {
    struct Fit: Equatable {
        /// Cents. Not rounded, so a fee rounds once.
        var fixedCents: Decimal
        var rate: Decimal
        var postageCents: Int
        var orderCount: Int

        /// The fee on what the buyer paid: item and shipping together, which
        /// is what the marketplaces charge on. Never below zero, never above
        /// the total.
        func feeCents(onCents total: Int) -> Int {
            guard total > 0 else { return 0 }
            var value = fixedCents + rate * Decimal(total)
            var rounded = Decimal()
            NSDecimalRound(&rounded, &value, 0, .plain)
            return min(max(0, NSDecimalNumber(decimal: rounded).intValue), total)
        }
    }

    /// The fewest orders a fit may stand on. A channel with fewer borrows the
    /// fit over every channel.
    static let minimumOrders = 5

    var byChannel: [String: Fit] = [:]
    var overall: Fit?

    /// Nil when he has too few orders with real fees to fit anything.
    func fit(for channelRaw: String) -> Fit? {
        byChannel[channelRaw] ?? overall
    }

    /// `channel` reads a sale's channel. The import passes its own reading, so
    /// a sale it is about to move to another channel counts there already.
    static func derived(from sales: [Sale], channel: (Sale) -> String = { $0.channelRaw }) -> FeeEstimate {
        var points: [String: [(total: Int, fee: Int)]] = [:]
        var postage: [String: [Int]] = [:]
        for sale in sales where !sale.costsEstimated {
            let total = sale.grossCents + sale.shippingChargedCents
            guard total > 0 else { continue }
            let key = channel(sale)
            if sale.marketplaceFeesCents > 0 {
                points[key, default: []].append((total, sale.marketplaceFeesCents))
            }
            if sale.shippingCostCents > 0 {
                postage[key, default: []].append(sale.shippingCostCents)
            }
        }

        var out = FeeEstimate()
        for (key, rows) in points {
            if let fit = fit(rows, postage: postage[key] ?? []) { out.byChannel[key] = fit }
        }
        out.overall = fit(points.values.flatMap { $0 }, postage: postage.values.flatMap { $0 })
        return out
    }

    static func fit(_ rows: [(total: Int, fee: Int)], postage: [Int]) -> Fit? {
        guard rows.count >= minimumOrders else { return nil }
        let n = Decimal(rows.count)
        var sx = Decimal(), sy = Decimal(), sxx = Decimal(), sxy = Decimal()
        for row in rows {
            let x = Decimal(row.total), y = Decimal(row.fee)
            sx += x
            sy += y
            sxx += x * x
            sxy += x * y
        }
        let sorted = postage.sorted()
        let median = sorted.isEmpty ? 0 : sorted[(sorted.count - 1) / 2]

        // A plain rate when the line cannot be fitted, or when the fit says a
        // marketplace pays him to sell. Both are small or odd samples.
        let ratio = Fit(fixedCents: 0, rate: sx > 0 ? sy / sx : 0, postageCents: median, orderCount: rows.count)
        let denominator = n * sxx - sx * sx
        guard denominator > 0 else { return ratio }
        let rate = (n * sxy - sx * sy) / denominator
        let fixed = (sy - rate * sx) / n
        guard rate >= 0, fixed >= 0 else { return ratio }
        return Fit(fixedCents: fixed, rate: rate, postageCents: median, orderCount: rows.count)
    }
}
