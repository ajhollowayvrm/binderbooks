import SwiftUI

/// TCGplayer's market price and its lowest listing, one above the other, each
/// with its label.
///
/// AJ asked for both on 2026-09-27, at every price. Before that a card showed
/// one figure: the market price at $5 and up, the low price under $5. That
/// rule still sets the totals and the value sort. See `ProductPrice.valueCents`.
struct TCGPriceText: View {
    var marketCents: Int?
    var lowCents: Int?
    /// The font of the market line. The low line is always a caption.
    var font: Font = .subheadline
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            line("Mkt", marketCents, font: font.monospacedDigit().weight(.semibold))
            line("Low", lowCents, font: .caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    /// One line for a small space: "$3.20 · low $1.05". Nil with neither price.
    static func inline(marketCents: Int?, lowCents: Int?) -> String? {
        guard marketCents != nil || lowCents != nil else { return nil }
        return "\(marketCents?.asCurrency ?? "—") · low \(lowCents?.asCurrency ?? "—")"
    }

    private func line(_ label: String, _ cents: Int?, font: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(cents?.asCurrency ?? "—")
                .font(font)
        }
    }
}
