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

struct SearchRequest: Equatable, Sendable {
    var text: String
    var context: SearchContext
    var filter: SearchFilter

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

    /// "$3.21" for one printing, "from $0.05" when printings differ.
    var priceLabel: String? {
        guard let min = minMarketCents else { return nil }
        if let max = maxMarketCents, max != min {
            return "from \(min.asCurrency)"
        }
        return min.asCurrency
    }
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

struct ProductPrice: Identifiable, Hashable, Sendable {
    var subTypeName: String
    var marketCents: Int?
    var lowCents: Int?
    var midCents: Int?
    var highCents: Int?
    var directLowCents: Int?
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

    /// The catalog stores the 200 px thumbnail. TCGplayer serves larger widths
    /// under the same path.
    var largeImageURL: URL? {
        hit.imageUrl.flatMap { URL(string: $0.replacingOccurrences(of: "_200w", with: "_400w")) }
    }
}
