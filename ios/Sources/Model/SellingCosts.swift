import Foundation

/// What it costs him to turn a card into money.
///
/// A projection that ignores fees answers the wrong question. On his real books
/// the at-grader pile grosses $8,192.27 at top grades, which clears break-even
/// by $308, and nets $7,075.66, which misses it by $808. The fee is the whole
/// answer, so it has to be in the arithmetic.
///
/// The rate is derived from the orders already in the store rather than typed.
/// He has 131 of them; that is a better number than one he would guess, and it
/// corrects itself as he sells. Settings can override it.
///
/// Rates are basis points, `Int`. A rate is not money, so brief decision 2 does
/// not apply, but keeping it integral means the projection never picks up float
/// drift on its way to a cents figure.
struct SellingCosts: Equatable {
    /// 1363 is 13.63%.
    var rateBasisPoints: Int

    static let hundredPercent = 10_000

    /// What he keeps after selling costs.
    func net(_ cents: Int) -> Int {
        cents * (Self.hundredPercent - rateBasisPoints) / Self.hundredPercent
    }

    /// What the sale takes. `net` plus this is the gross, with the rounding
    /// difference landing here rather than going missing.
    func fee(_ cents: Int) -> Int { cents - net(cents) }

    var percentText: String {
        let whole = rateBasisPoints / 100
        let fraction = abs(rateBasisPoints % 100)
        return "\(whole).\(String(format: "%02d", fraction))%"
    }
}

/// The rates his own orders imply, per channel and over everything.
struct ChannelRates: Equatable {
    struct Row: Equatable, Identifiable {
        var channelRaw: String
        var orderCount: Int
        var grossCents: Int
        var feeBasisPoints: Int
        var id: String { channelRaw }

        var name: String { LedgerEntry.channelName(channelRaw) }
    }

    var rows: [Row] = []
    /// Marketplace fees over every order.
    var blendedFeeBasisPoints: Int = 0
    /// What he pays to ship an order, as a share of gross. He pays it on a slab
    /// the same as on a single, so a projection that leaves it out reads high.
    var shippingBasisPoints: Int = 0
    var orderCount: Int = 0

    /// Fees and shipping together: the whole cost of turning a card into money.
    var totalBasisPoints: Int { blendedFeeBasisPoints + shippingBasisPoints }

    /// Nil when he has sold nothing, because then there is no rate to derive
    /// and a zero would read as "selling is free".
    var isEmpty: Bool { orderCount == 0 || rows.isEmpty }

    static func derived(from sales: [Sale]) -> ChannelRates {
        var out = ChannelRates()
        var byChannel: [String: (count: Int, gross: Int, fees: Int)] = [:]
        var gross = 0
        var fees = 0
        var shipping = 0

        for sale in sales {
            guard sale.grossCents > 0 else { continue }
            let key = sale.channelRaw.isEmpty ? "unknown" : sale.channelRaw
            var row = byChannel[key] ?? (0, 0, 0)
            row.count += 1
            row.gross += sale.grossCents
            row.fees += sale.marketplaceFeesCents + sale.otherFeesCents
            byChannel[key] = row

            gross += sale.grossCents
            fees += sale.marketplaceFeesCents + sale.otherFeesCents
            shipping += sale.shippingCostCents
            out.orderCount += 1
        }

        guard gross > 0 else { return out }
        out.blendedFeeBasisPoints = basisPoints(fees, of: gross)
        out.shippingBasisPoints = basisPoints(shipping, of: gross)
        out.rows = byChannel
            .map { Row(channelRaw: $0.key, orderCount: $0.value.count, grossCents: $0.value.gross,
                       feeBasisPoints: basisPoints($0.value.fees, of: $0.value.gross)) }
            .sorted { $0.grossCents > $1.grossCents }
        return out
    }

    /// Rounded to nearest, not truncated. 14.45% reading as 14.44% is the kind
    /// of small lie that makes someone check the arithmetic by hand.
    static func basisPoints(_ part: Int, of whole: Int) -> Int {
        guard whole > 0 else { return 0 }
        return (part * hundredPercentInt + whole / 2) / whole
    }

    private static let hundredPercentInt = SellingCosts.hundredPercent
}

/// Where the override lives. Empty means "use what his orders imply".
enum SellingCostsKey {
    static let defaultsKey = "sellingCostBasisPoints"

    /// The rate a projection should use: his override, or the derived figure.
    static func effective(override: Int?, derived: ChannelRates) -> SellingCosts {
        if let override, override >= 0, override < SellingCosts.hundredPercent {
            return SellingCosts(rateBasisPoints: override)
        }
        return SellingCosts(rateBasisPoints: derived.totalBasisPoints)
    }

    /// "13.63" for the field. Basis points are hundredths of a percent, so this
    /// is the same shape as `Money.fieldText` one scale down.
    static func fieldText(_ basisPoints: Int) -> String {
        "\(basisPoints / 100)." + String(format: "%02d", abs(basisPoints % 100))
    }

    /// Parses "13.63" into 1363. Rejects anything at or above 100%.
    static func basisPoints(from text: String) -> Int? {
        let filtered = text.filter { $0.isNumber || $0 == "." }
        guard !filtered.isEmpty, filtered.filter({ $0 == "." }).count <= 1 else { return nil }
        guard let value = Decimal(string: filtered) else { return nil }
        let points = NSDecimalNumber(decimal: value * 100).rounding(accordingToBehavior: nil).intValue
        guard points >= 0, points < SellingCosts.hundredPercent else { return nil }
        return points
    }
}
