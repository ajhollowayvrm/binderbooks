import Foundation
import SwiftData

/// Every change to an order that is on the books: its details, its money, and
/// the cards on it. The rules live here and not in the views, so the tests
/// reach them.
@MainActor
enum SaleEditor {
    /// What the edit sheet changes. Every field of the order except its lines.
    struct Details: Equatable {
        var soldAt: Date
        var channelRaw: String
        var externalOrderId: String
        var grossCents: Int
        var marketplaceFeesCents: Int
        var salesTaxCents: Int
        var shippingChargedCents: Int
        var shippingCostCents: Int
        var otherFeesCents: Int
        var costsEstimated: Bool

        init(_ sale: Sale) {
            soldAt = sale.soldAt
            channelRaw = sale.channelRaw
            externalOrderId = sale.externalOrderId
            grossCents = sale.grossCents
            marketplaceFeesCents = sale.marketplaceFeesCents
            salesTaxCents = sale.salesTaxCents
            shippingChargedCents = sale.shippingChargedCents
            shippingCostCents = sale.shippingCostCents
            otherFeesCents = sale.otherFeesCents
            costsEstimated = sale.costsEstimated
        }

        /// The same sum as `Sale.netCents`, before the edit is saved.
        var netCents: Int {
            grossCents + shippingChargedCents
                - marketplaceFeesCents - salesTaxCents - shippingCostCents - otherFeesCents
        }
    }

    /// A card to put on an order, and the name the line shows for it.
    struct Attachment {
        var card: OwnedCard
        var describedAs: String
    }

    /// A typed fee or postage is not an estimate. The flag goes off when
    /// either figure changes, so `FeeEstimate` starts to read the order.
    static func apply(_ details: Details, to sale: Sale, context: ModelContext) throws {
        let costsTyped = details.marketplaceFeesCents != sale.marketplaceFeesCents
            || details.shippingCostCents != sale.shippingCostCents
        sale.soldAt = details.soldAt
        sale.channelRaw = details.channelRaw
        sale.externalOrderId = details.externalOrderId.trimmingCharacters(in: .whitespaces)
        sale.grossCents = details.grossCents
        sale.marketplaceFeesCents = details.marketplaceFeesCents
        sale.salesTaxCents = details.salesTaxCents
        sale.shippingChargedCents = details.shippingChargedCents
        sale.shippingCostCents = details.shippingCostCents
        sale.otherFeesCents = details.otherFeesCents
        sale.costsEstimated = details.costsEstimated && !costsTyped
        try context.save()
    }

    /// Adds one line for each card, and tags each card sold. A card that is
    /// sold already stays off, because two orders cannot sell one card.
    /// Returns the number of cards attached.
    @discardableResult
    static func attach(_ attachments: [Attachment], to sale: Sale, context: ModelContext) throws -> Int {
        var sold: [OwnedCard] = []
        for item in attachments where !CardTagIndex.isSold(item.card) && !sold.contains(where: { $0.id == item.card.id }) {
            let line = SaleLine(sale: sale, card: item.card)
            line.describedAs = item.describedAs
            context.insert(line)
            sold.append(item.card)
        }
        CardTagEditor(context: context).add(ReservedTag.sold, to: sold)
        try context.save()
        return sold.count
    }

    /// Links a card to a line that names a card and links none. The import
    /// writes these lines. A new line would count the same card twice. The
    /// line keeps the name the order recorded.
    @discardableResult
    static func link(_ line: SaleLine, to item: Attachment, context: ModelContext) throws -> Bool {
        guard line.card == nil, !CardTagIndex.isSold(item.card) else { return false }
        line.card = item.card
        if line.describedAs.isEmpty { line.describedAs = item.describedAs }
        CardTagEditor(context: context).add(ReservedTag.sold, to: [item.card])
        try context.save()
        return true
    }
}
