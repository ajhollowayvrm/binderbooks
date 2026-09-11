import SwiftUI

/// The rows of cards on their own. It carries no scroll view, so it also
/// works inside one row of the home list.
struct ProductCardGrid: View {
    var hits: [SearchHit]
    var columns = 3

    private var gridItems: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
    }

    var body: some View {
        LazyVGrid(columns: gridItems, spacing: 14) {
            ForEach(hits) { hit in
                NavigationLink(value: hit) {
                    ProductCard(hit: hit)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// One grid cell. The art identifies the card, so the text under it carries
/// the price, the set, and the number, and never repeats the name.
struct ProductCard: View {
    var hit: SearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            art
            if let price = hit.priceLabel {
                Text(price)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("No price")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            Text(hit.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(hit.setName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // The printing count lives in the list layout. At grid width it
            // truncated the collector number, which matters more.
            if let number = hit.number {
                Text(number)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A card is 5:7. Sealed art is not, so it fits inside the same box and
    /// the rows stay aligned.
    private var art: some View {
        AsyncImage(url: hit.largeImageURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            case .empty:
                Rectangle().fill(.fill.quaternary)
            default:
                Rectangle()
                    .fill(.fill.quaternary)
                    .overlay {
                        Image(systemName: hit.isSealed ? "shippingbox" : "rectangle.portrait")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(5.0 / 7.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
