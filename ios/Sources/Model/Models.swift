import Foundation
import SwiftData

// The collection store. His data, irreplaceable. Shapes follow docs/02-data-model.md,
// with the `basisIsAllocated` flag from docs/04. The store references the catalog
// by integer productId only and never embeds a name or a price.
//
// All money is Int cents.

enum AllocationMethod: String, Codable, CaseIterable {
    case equal
    case byMarketValue
    case manual
}

enum CardStatus: String, Codable, CaseIterable {
    case owned, atGrader, gradedReturned, listed, sold, lost
}

enum MatchConfidence: String, Codable, CaseIterable, Comparable {
    /// He picked it by hand.
    case manual
    /// Unique match on name, number, and set total.
    case certain
    /// One strong candidate, some ambiguity.
    case likely
    /// Several candidates, or a guessed printing.
    case uncertain

    private var order: Int {
        switch self {
        case .manual: return 0
        case .certain: return 1
        case .likely: return 2
        case .uncertain: return 3
        }
    }

    static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool { lhs.order < rhs.order }

    var needsReview: Bool { self == .uncertain }
}

/// TCGplayer's condition names, in order.
enum CardCondition: String, CaseIterable {
    case nearMint = "Near Mint"
    case lightlyPlayed = "Lightly Played"
    case moderatelyPlayed = "Moderately Played"
    case heavilyPlayed = "Heavily Played"
    case damaged = "Damaged"

    var short: String {
        switch self {
        case .nearMint: return "NM"
        case .lightlyPlayed: return "LP"
        case .moderatelyPlayed: return "MP"
        case .heavilyPlayed: return "HP"
        case .damaged: return "DMG"
        }
    }
}

/// Money left his account. Says nothing about what was bought.
@Model
final class Purchase {
    #Unique<Purchase>([\.id])

    var id: UUID = UUID()
    var date: Date = Date()
    /// Free text: "Walmart", "Whatnot", "Fuzzy's". Not a dimension.
    var vendor: String = ""
    /// What he would write on a receipt.
    var note: String = ""
    @Attribute(.externalStorage) var receiptImageData: Data?

    var itemCostCents: Int = 0
    var shippingCents: Int = 0
    var taxCents: Int = 0
    var feesCents: Int = 0

    var allocationMethodRaw: String = AllocationMethod.equal.rawValue

    @Relationship(deleteRule: .cascade, inverse: \PurchaseItem.purchase)
    var items: [PurchaseItem] = []

    init(date: Date = Date(), vendor: String, note: String = "", itemCostCents: Int, shippingCents: Int = 0, taxCents: Int = 0, feesCents: Int = 0) {
        self.id = UUID()
        self.date = date
        self.vendor = vendor
        self.note = note
        self.itemCostCents = itemCostCents
        self.shippingCents = shippingCents
        self.taxCents = taxCents
        self.feesCents = feesCents
    }

    var landedCostCents: Int { itemCostCents + shippingCents + taxCents + feesCents }

    var allocationMethod: AllocationMethod {
        get { AllocationMethod(rawValue: allocationMethodRaw) ?? .equal }
        set { allocationMethodRaw = newValue.rawValue }
    }
}

/// One line of a purchase: a sealed product, or cards. Sealed items nest.
@Model
final class PurchaseItem {
    #Unique<PurchaseItem>([\.id])

    var id: UUID = UUID()
    var productId: Int = 0
    var quantity: Int = 1
    var isSealed: Bool = false
    /// Written by the allocator, not by hand.
    var allocatedCostCents: Int = 0

    var purchase: Purchase?

    /// Set when this item came out of ripping a larger sealed item.
    var parentItem: PurchaseItem?

    @Relationship(deleteRule: .cascade, inverse: \PurchaseItem.parentItem)
    var childItems: [PurchaseItem] = []

    @Relationship(deleteRule: .cascade, inverse: \OwnedCard.sourceItem)
    var cards: [OwnedCard] = []

    /// Set on a pack once its wrapper has been read. Nil until then.
    var identifiedGroupId: Int?

    var isRipped: Bool = false

    init(productId: Int, quantity: Int = 1, isSealed: Bool = false) {
        self.id = UUID()
        self.productId = productId
        self.quantity = quantity
        self.isSealed = isSealed
    }

    /// True when every card on this line is bulk. Excluded from allocation.
    var isBulkOnly: Bool {
        !cards.isEmpty && cards.allSatisfy(\.isBulk)
    }

    /// True when he priced every card on this line himself. The line then takes
    /// its own money out of the purchase total instead of a share of it.
    var isManualOnly: Bool {
        !cards.isEmpty && cards.allSatisfy(\.basisIsManual)
    }
}

@Model
final class OwnedCard {
    #Unique<OwnedCard>([\.id])

    var id: UUID = UUID()
    /// Catalog product. 0 until the card is identified; a slab read by barcode
    /// starts that way.
    var productId: Int = 0
    var skuId: Int?
    /// Normal / Holofoil / Reverse Holofoil. Empty until chosen.
    var printing: String = ""
    var condition: String = CardCondition.nearMint.rawValue
    var language: String = "en"
    /// Greater than 1 only for undifferentiated bulk.
    var quantity: Int = 1

    var acquiredAt: Date = Date()
    var statusRaw: String = CardStatus.owned.rawValue

    /// Allocated at intake.
    var acquisitionBasisCents: Int = 0
    /// Added when a grading submission returns. Zero for raw cards.
    var gradingBasisCents: Int = 0
    /// True when the allocator wrote the basis. A rip pull's per-card basis is
    /// an artifact. Never show it next to a market value as a gain or loss.
    var basisIsAllocated: Bool = false
    /// True when he priced the card himself, at review. A purchase total never
    /// overwrites it, and it comes out of the total before the split.
    var basisIsManual: Bool = false

    /// Not individually accounted. Excluded from allocation denominators.
    var isBulk: Bool = false
    /// Cards he is keeping. Not inventory; excluded from COGS.
    var isPersonalCollection: Bool = false

    var sourceItem: PurchaseItem?
    var scanSession: ScanSession?

    var matchConfidenceRaw: String = MatchConfidence.manual.rawValue

    /// A slab read by barcode. The grader's cert number.
    var certNumber: String?
    var graderRaw: String?

    /// What the scanner read. Kept for review and for correcting the matcher.
    var ocrName: String?
    var ocrNumber: String?
    /// Other products the matcher considered. Drives the disambiguation chip.
    var candidateProductIds: [Int] = []
    var scannedAt: Date = Date()

    /// Free-form labels he typed: "binder 3", "for sale", "PSA queue". Tags
    /// replace the old status picker; `CardStatus` values live here now as
    /// reserved labels. Stored as typed, compared by `TagKey`, sorted by key.
    var tags: [String] = []

    init(productId: Int, printing: String, condition: String, confidence: MatchConfidence) {
        self.id = UUID()
        self.productId = productId
        self.printing = printing
        self.condition = condition
        self.matchConfidenceRaw = confidence.rawValue
        self.acquiredAt = Date()
        self.scannedAt = Date()
    }

    var totalBasisCents: Int { acquisitionBasisCents + gradingBasisCents }

    var status: CardStatus {
        get { CardStatus(rawValue: statusRaw) ?? .owned }
        set { statusRaw = newValue.rawValue }
    }

    var matchConfidence: MatchConfidence {
        get { MatchConfidence(rawValue: matchConfidenceRaw) ?? .uncertain }
        set { matchConfidenceRaw = newValue.rawValue }
    }

    var isIdentified: Bool { productId > 0 }

    /// A card is inventory once its session commits, or when it never came from a scan.
    var isCommitted: Bool { scanSession?.committedAt != nil || scanSession == nil }
}

/// A scanning run. Every match persists as it lands. Commits as a batch.
@Model
final class ScanSession {
    #Unique<ScanSession>([\.id])

    var id: UUID = UUID()
    var startedAt: Date = Date()
    var committedAt: Date?
    var defaultCondition: String = CardCondition.nearMint.rawValue
    var defaultPrinting: String?
    var purchase: Purchase?

    @Relationship(deleteRule: .cascade, inverse: \OwnedCard.scanSession)
    var cards: [OwnedCard] = []

    /// Set IDs that have resolved during this session, most recent first.
    /// Drives the learned session bias. Not user-configured.
    var observedGroupIds: [Int] = []

    init(defaultCondition: String = CardCondition.nearMint.rawValue, defaultPrinting: String? = nil) {
        self.id = UUID()
        self.startedAt = Date()
        self.defaultCondition = defaultCondition
        self.defaultPrinting = defaultPrinting
    }

    var isCommitted: Bool { committedAt != nil }

    var cardsNewestFirst: [OwnedCard] {
        cards.sorted { $0.scannedAt > $1.scannedAt }
    }

    static let biasWindow = 20

    func observe(groupId: Int) {
        observedGroupIds.removeAll { $0 == groupId }
        observedGroupIds.insert(groupId, at: 0)
        if observedGroupIds.count > Self.biasWindow {
            observedGroupIds.removeLast(observedGroupIds.count - Self.biasWindow)
        }
    }
}

enum CollectionStore {
    static let models: [any PersistentModel.Type] = [Purchase.self, PurchaseItem.self, OwnedCard.self, ScanSession.self]

    static func container(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
