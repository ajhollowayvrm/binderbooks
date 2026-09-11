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

    /// The row's id in the BinderBooks ledger it was imported from. Empty for
    /// anything he entered in this app. See docs/04-seed-import.md.
    var sourceRef: String = ""

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
    /// The grade as printed on the label: "10", "9.5", "Pristine 10". Nil
    /// until the submission returns, or for a slab the barcode alone read.
    var gradeLabel: String?

    /// What he believes the card sells for at each grade, in cents, keyed by
    /// the grade as printed: "10", "9.5", "9". He enters these by hand from
    /// Card Ladder, so they are expensive to recreate and must never be dropped.
    var gradedCompCents: [String: Int] = [:]

    /// The same, as PPT last reported them. Kept apart from what he typed, so
    /// a fetch never overwrites his number and a cleared field falls back to
    /// PPT's. Empty when PPT had nothing or was never asked.
    var fetchedCompCents: [String: Int] = [:]
    var compsFetchedAt: Date?

    /// What the app reads: his figures over PPT's.
    var effectiveCompCents: [String: Int] {
        fetchedCompCents.merging(gradedCompCents) { _, his in his }
    }

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

    /// The row's id in the BinderBooks ledger it was imported from.
    var sourceRef: String = ""

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

    /// A card in a slab, and so drawn as one. A cert number is not required:
    /// the imported ledger recorded the grade and never a cert, and a slab
    /// with a grade on its label is still a slab.
    var isSlabbed: Bool { certNumber != nil || (graderRaw != nil && gradeLabel != nil) }

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

// MARK: - Grading and sales
//
// Shapes follow docs/02-data-model.md, with two amendments: a sale holds lines,
// and there is no rip. See `SaleLine`, and `docs/04-seed-import.md`.
//
// **There is no `RipEvent`.** Opening a pack is an intake path, not a record:
// he rips from the purchase, the cards land in inventory with their share of
// what the purchase cost, and nothing writes a row for the opening itself. The
// sealed `PurchaseItem` is the pack, and it already carries both the cost and
// the cards.

@Model
final class GradingSubmission {
    #Unique<GradingSubmission>([\.id])

    var id: UUID = UUID()
    /// psa / cgc / bgs / tag. Free text, like `Purchase.vendor`.
    var graderRaw: String = ""
    var submissionNumber: String = ""
    var serviceLevel: String = ""
    var declaredValueCents: Int = 0

    var shippedAt: Date?
    var returnedAt: Date?

    var gradingFeesCents: Int = 0
    var shipToGraderCents: Int = 0
    var shipReturnCents: Int = 0
    var insuranceCents: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \GradingEntry.submission)
    var entries: [GradingEntry] = []

    var sourceRef: String = ""

    init(graderRaw: String, shippedAt: Date? = nil, gradingFeesCents: Int = 0) {
        self.id = UUID()
        self.graderRaw = graderRaw
        self.shippedAt = shippedAt
        self.gradingFeesCents = gradingFeesCents
    }

    var totalCostCents: Int {
        gradingFeesCents + shipToGraderCents + shipReturnCents + insuranceCents
    }
}

/// One card inside a submission. The fee splits equally across entries, which
/// is correct here because the grader charged per card.
@Model
final class GradingEntry {
    #Unique<GradingEntry>([\.id])

    var id: UUID = UUID()
    var submission: GradingSubmission?
    var card: OwnedCard?

    /// 10, 9.5. Nil until the submission returns.
    var grade: Double?
    var certNumber: String = ""
    var allocatedFeeCents: Int = 0
    /// N0, altered, or rejected. A card can come back ungraded.
    var noGrade: Bool = false

    init(submission: GradingSubmission? = nil, card: OwnedCard? = nil) {
        self.id = UUID()
        self.submission = submission
        self.card = card
    }
}

/// One order. Money in, and nothing about which cards left: that is `SaleLine`.
///
/// docs/02 gave a sale a single card. His real ledger disproves that. Thirty of
/// his 131 orders carry more than one card and one carries 18, because a
/// TCGplayer order is one payment over several cards. So a sale holds the money
/// and its lines hold the cards, the way a purchase holds its items.
@Model
final class Sale {
    #Unique<Sale>([\.id])

    var id: UUID = UUID()
    var soldAt: Date = Date()
    /// tcgplayer / ebay / whatnot / local. Free text.
    var channelRaw: String = ""

    var grossCents: Int = 0
    var marketplaceFeesCents: Int = 0
    var salesTaxCents: Int = 0
    var shippingChargedCents: Int = 0
    var shippingCostCents: Int = 0
    var otherFeesCents: Int = 0

    /// eBay orderId, or the TCGplayer order number. The dedupe key for a later
    /// order import. Empty on every imported row, because the BinderBooks
    /// export dropped it. See docs/04-seed-import.md.
    var externalOrderId: String = ""

    @Relationship(deleteRule: .cascade, inverse: \SaleLine.sale)
    var lines: [SaleLine] = []

    var sourceRef: String = ""

    init(soldAt: Date = Date(), channelRaw: String, grossCents: Int = 0) {
        self.id = UUID()
        self.soldAt = soldAt
        self.channelRaw = channelRaw
        self.grossCents = grossCents
    }

    var netCents: Int {
        grossCents + shippingChargedCents
            - marketplaceFeesCents - salesTaxCents - shippingCostCents - otherFeesCents
    }

    /// Nil when any line has no basis. A sale with an unknown cost must not
    /// report a gain, because the gain would be the whole price.
    var realizedGainCents: Int? {
        guard !lines.isEmpty, lines.allSatisfy({ !$0.basisIncomplete }) else { return nil }
        return netCents - lines.reduce(0) { $0 + $1.basisCents }
    }
}

/// One card, or one sealed item, inside an order. A premium collection is worth
/// selling unopened, so a line points at a card or at a sealed item.
@Model
final class SaleLine {
    #Unique<SaleLine>([\.id])

    var id: UUID = UUID()
    var sale: Sale?
    var card: OwnedCard?
    var sealedItem: PurchaseItem?

    var basisCents: Int = 0
    /// True when the cost of what sold is unknown. His older orders record a
    /// price and no card, so the revenue is real and the cost is not there.
    var basisIncomplete: Bool = false

    /// The card's name as the order recorded it. The store holds no card name,
    /// but a line whose card is unknown has nothing else to show.
    var describedAs: String = ""

    var sourceRef: String = ""

    init(sale: Sale? = nil, card: OwnedCard? = nil, basisCents: Int = 0, basisIncomplete: Bool = false) {
        self.id = UUID()
        self.sale = sale
        self.card = card
        self.basisCents = basisCents
        self.basisIncomplete = basisIncomplete
    }
}

/// A cost that hits the books and attaches to no card: mailers, toploaders,
/// team bags, postage, the Card Ladder subscription.
///
/// Not trivial at his volume, and until now the app had nowhere to put one. The
/// periodic P&L subtracts these, so money spent on supplies stops reading as
/// profit. `category` and `vendor` are free text for bookkeeping, the way
/// `Purchase.vendor` is. Neither is a dimension: see decision 23 in
/// docs/00-brief.md.
@Model
final class BusinessExpense {
    #Unique<BusinessExpense>([\.id])

    var id: UUID = UUID()
    var date: Date = Date()
    var category: String = ""
    var vendor: String = ""
    var amountCents: Int = 0
    var note: String = ""

    var sourceRef: String = ""

    init(date: Date = Date(), category: String = "", vendor: String = "", amountCents: Int = 0, note: String = "") {
        self.id = UUID()
        self.date = date
        self.category = category
        self.vendor = vendor
        self.amountCents = amountCents
        self.note = note
    }
}

enum CollectionStore {
    static let models: [any PersistentModel.Type] = [
        Purchase.self, PurchaseItem.self, OwnedCard.self, ScanSession.self,
        GradingSubmission.self, GradingEntry.self, Sale.self, SaleLine.self,
        BusinessExpense.self,
    ]

    static func container(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
