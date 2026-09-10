import SwiftUI

/// One search result. Dense on purpose: thumbnail, name, set, number, price.
struct ProductRow: View {
    var hit: SearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProductThumbnail(urlString: hit.imageUrl, isSealed: hit.isSealed)
                .frame(width: 44, height: 62)

            VStack(alignment: .leading, spacing: 3) {
                Text(hit.name)
                    .font(.body)
                    .lineLimit(2)
                Text(hit.setName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let number = hit.number {
                        Text(number)
                            .monospacedDigit()
                    }
                    if let rarity = hit.rarity, rarity != "None" {
                        Text(rarity)
                    }
                    if hit.isSealed {
                        Text("Sealed")
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.fill.tertiary, in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                if let price = hit.priceLabel {
                    Text(price)
                        .font(.body.monospacedDigit())
                } else {
                    Text("No price")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if hit.printingCount > 1 {
                    Text("\(hit.printingCount) printings")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ProductThumbnail: View {
    var urlString: String?
    var isSealed: Bool

    var body: some View {
        AsyncImage(url: urlString.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFit()
            case .failure:
                placeholder
            case .empty:
                Rectangle().fill(.fill.quaternary)
            @unknown default:
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.fill.quaternary)
            .overlay {
                Image(systemName: isSealed ? "shippingbox" : "rectangle.portrait")
                    .foregroundStyle(.tertiary)
            }
    }
}
