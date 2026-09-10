import Foundation

/// Where a search runs from. The same index answers every query; the context
/// only adjusts ranking. The user never picks a mode.
enum SearchContext: Equatable, Sendable {
    /// The persistent field with no task in mind. Neutral.
    case browsing
    /// Recording a purchase. Sealed products rank higher.
    case buying
    /// Assigning identities to cards. Singles rank higher.
    case intake
    /// Resolving a scanned card. Singles rank higher.
    case scanning
}

/// Narrowing the user applies through the chips. Not a mode either.
struct SearchFilter: Equatable, Sendable {
    enum Kind: Equatable, Sendable, CaseIterable {
        case all, singles, sealed

        var title: String {
            switch self {
            case .all: return "All"
            case .singles: return "Singles"
            case .sealed: return "Sealed"
            }
        }
    }

    var kind: Kind = .all
    var categoryIds: Set<Int> = []
    var groupId: Int?

    var isActive: Bool { kind != .all || !categoryIds.isEmpty || groupId != nil }
}

/// What the result order optimises for.
enum SearchRanking: Equatable, Sendable {
    /// Market value first, under the exact-match tiers. What a person reading a
    /// result list wants.
    case byValue
    /// Text relevance first. What a machine matching an OCR name needs: the
    /// closest name must survive the candidate cap, however cheap the card is.
    case byRelevance
}

struct SearchRequest: Equatable, Sendable {
    var text: String
    var context: SearchContext
    var filter: SearchFilter
    var ranking: SearchRanking = .byValue

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// One search result. Enough to draw a row without a second query.
struct SearchHit: Identifiable, Hashable, Sendable {
    var productId: Int
    var groupId: Int
    var categoryId: Int
    var name: String
    var cleanName: String
    var setName: String
    var number: String?
    var numberNum: Int?
    var setTotal: Int?
    var setCode: String?
    var rarity: String?
    var isSealed: Bool
    var printingCount: Int
    var imageUrl: String?
    var publishedOn: String?
    var minMarketCents: Int?
    var maxMarketCents: Int?

    var id: Int { productId }

    /// The catalog stores the 200 px thumbnail. TCGplayer serves larger widths
    /// under the same path. The grid and the detail header use this one.
    var largeImageURL: URL? {
        imageUrl.flatMap { URL(string: $0.replacingOccurrences(of: "_200w", with: "_400w")) }
    }

    /// The market price of the product's top printing. The list orders by this
    /// number, so the row must show this number. `printingCount` on the row
    /// says the other printings are cheaper.
    var topMarketCents: Int? { maxMarketCents ?? minMarketCents }

    /// "$3.21". Nil when TCGplayer has no market price for the product.
    var priceLabel: String? { topMarketCents?.asCurrency }
}

struct SetSummary: Identifiable, Hashable, Sendable {
    var groupId: Int
    var categoryId: Int
    var categoryName: String
    var name: String
    var abbreviation: String?
    var publishedOn: String?
    var productCount: Int

    var id: Int { groupId }
}

struct CategorySummary: Identifiable, Hashable, Sendable {
    var categoryId: Int
    var name: String
    var displayName: String

    var id: Int { categoryId }

    /// Short chip titles. The catalog names are TCGplayer's.
    var chipTitle: String {
        switch name {
        case "Pokemon": return "Pokémon"
        case "Pokemon Japan": return "Japan"
        case "Digimon Card Game": return "Digimon"
        default: return displayName
        }
    }
}

/// One printing's price. The market price is the only number the app keeps.
/// TCGplayer's low, mid, high, and direct-low columns stay in the catalog and
/// out of the app, because AJ values a card at market.
struct ProductPrice: Identifiable, Hashable, Sendable {
    var subTypeName: String
    var marketCents: Int?
    var asOf: String

    var id: String { subTypeName }
}

struct ProductDetail: Sendable {
    var hit: SearchHit
    var categoryName: String
    var cardType: String?
    var setAbbreviation: String?
    var prices: [ProductPrice]

    /// TCGplayer's product page. The catalog does not store the slug URL; the
    /// short form redirects to it.
    var tcgplayerURL: URL {
        URL(string: "https://www.tcgplayer.com/product/\(hit.productId)")!
    }

    var largeImageURL: URL? { hit.largeImageURL }
}
