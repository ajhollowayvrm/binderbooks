import Testing
@testable import BinderBooks

/// Every price shows TCGplayer's market and low. The row a card reads is its
/// printing's, else the printing with the lowest value.
@Suite struct TCGPriceTests {
    private let rows = [
        ProductPrice(subTypeName: "Normal", marketCents: 320, asOf: "2026-09-27", lowCents: 105),
        ProductPrice(subTypeName: "Reverse Holofoil", marketCents: 900, asOf: "2026-09-27", lowCents: 650),
        ProductPrice(subTypeName: "Holofoil", marketCents: nil, asOf: "2026-09-27", lowCents: nil),
    ]

    @Test func theCardsPrintingWins() {
        let row = rows.row(for: "Reverse Holofoil")
        #expect(row?.marketCents == 900)
        #expect(row?.lowCents == 650)
    }

    @Test func anUnknownOrUnpricedPrintingFallsBackToTheLowestValue() {
        #expect(rows.row(for: "")?.subTypeName == "Normal")
        #expect(rows.row(for: "Holofoil")?.subTypeName == "Normal")
        #expect([ProductPrice]().row(for: "Normal") == nil)
    }

    @Test func underFiveDollarsBothPricesStillShow() {
        // The $5 rule picks the low for the value, and the display keeps both.
        let row = rows.row(for: "Normal")
        #expect(row?.valueCents == 105)
        #expect(TCGPriceText.inline(marketCents: row?.marketCents, lowCents: row?.lowCents) == "$3.20 · low $1.05")
        #expect(TCGPriceText.inline(marketCents: nil, lowCents: nil) == nil)
    }
}
