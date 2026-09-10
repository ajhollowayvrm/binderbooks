import SwiftUI

/// Catalog data for one product: image, identity, every printing's prices.
struct ProductDetailView: View {
    var productId: Int

    @Environment(CatalogController.self) private var catalog
    @Environment(RecentlyViewed.self) private var recents
    @State private var detail: ProductDetail?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let detail {
                content(detail)
            } else if let errorMessage {
                ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: productId) {
            await load()
        }
    }

    private func load() async {
        guard let db = catalog.database else { return }
        do {
            detail = try await CatalogSearch(database: db).detail(productId: productId)
            if detail == nil {
                errorMessage = "Product \(productId) is not in the installed catalog."
            } else {
                recents.record(productId)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func content(_ detail: ProductDetail) -> some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    AsyncImage(url: detail.largeImageURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            RoundedRectangle(cornerRadius: 6).fill(.fill.quaternary)
                        }
                    }
                    .frame(width: 120, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(detail.hit.name)
                            .font(.title3.weight(.semibold))
                        Text(detail.hit.setName)
                            .foregroundStyle(.secondary)
                        if let number = detail.hit.number {
                            Text(number)
                                .font(.body.monospacedDigit())
                        }
                        if let rarity = detail.hit.rarity, rarity != "None" {
                            Text(rarity)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if detail.hit.isSealed {
                            Text("Sealed product")
                                .font(.footnote)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.fill.tertiary, in: Capsule())
                        }
                    }
                }
                .listRowSeparator(.hidden)
            }

            Section("Market price") {
                if detail.prices.isEmpty {
                    Text("No TCGplayer price yet.")
                        .foregroundStyle(.secondary)
                } else {
                    // Market price only. The low, mid, and high columns are
                    // noise for a collection he values at market.
                    ForEach(detail.prices) { price in
                        HStack {
                            Text(price.subTypeName)
                            Spacer()
                            Text(price.marketCents?.asCurrency ?? "—")
                                .font(.body.monospacedDigit().weight(.semibold))
                        }
                    }
                    if let asOf = detail.prices.first?.asOf {
                        Text("Prices as of \(asOf).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Catalog") {
                LabeledContent("Category", value: detail.categoryName)
                if let abbreviation = detail.setAbbreviation, !abbreviation.isEmpty {
                    LabeledContent("Set code", value: abbreviation)
                }
                if let cardType = detail.cardType {
                    LabeledContent("Type", value: cardType)
                }
                if let setTotal = detail.hit.setTotal {
                    LabeledContent("Printed total", value: "\(setTotal)")
                }
                LabeledContent("Printings", value: "\(detail.hit.printingCount)")
                LabeledContent("Product ID", value: "\(detail.hit.productId)")
                Link(destination: detail.tcgplayerURL) {
                    Label("Open on TCGplayer", systemImage: "arrow.up.right.square")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}
