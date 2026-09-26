import Foundation
import SwiftData

// The collection store. His data, irreplaceable. Shapes follow docs/02-data-model.md.
// The store references the catalog by integer productId only and never embeds a
// name or a price.
//
// All money is Int cents.
//
// From 2026-09-22 to 2026-09-25 a card had no cost. Since 2026-09-25 it has
// a cost again, from the day the books start. See `CostBasis` and `Books`.
// The fields still marked dormant stay so old stores open and old exports
// import. Only `CollectionExport` reads and writes them.

/// Kept only because the default value of the dormant
/// `Purchase.allocationMethodRaw` uses it.
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

/// The languages a hand-entered card can have. The store keeps a BCP 47 code.
/// A catalog card keeps "en", also a Japanese product: its category gives its
/// language.
enum CardLanguage {
    static let codes = ["en", "ja", "zh-Hans", "zh-Hant", "ko", "it", "fr", "de", "es", "pt"]

    /// "Italian", "Chinese (Simplified)". In English, like the rest of the app.
    static func name(_ code: String) -> String {
        Locale(identifier: "en_US").localizedString(forIdentifier: code) ?? code
    }

    /// A short mark for a row: "IT", "ZH-S". Nil for English, the default.
    static func badge(_ code: String) -> String? {
        switch code {
        case "", "en": return nil
        case "zh-Hans": return "ZH-S"
        case "zh-Hant": return "ZH-T"
        default: return code.uppercased()
        }
    }
}

extension OwnedCard {
    /// The purchase the card came from. A pull from a ripped pack has no
    /// purchase of its own, so this walks up to the pack's line.
    var purchase: Purchase? {
        var item = sourceItem
        while let current = item {
            if let purchase = current.purchase { return purchase }
            item = current.parentItem
        }
        return nil
    }
}

/// Money left his account. Its landed cost splits over the cards on its lines.
@Model
final class Purchase {
    #Unique<Purchase>([\.id])

    var id: UUID = UUID()
    var date: Date = Date()
    /// Free text: "Walmart", "Whatnot", "Fuzzy's". Not a dimension.
    var vendor: String = ""
    /// What he would write on a receipt.
    var note: String = ""
    /// Dormant: no screen ever wrote it. A receipt is a `Receipt` now. Kept
    /// for old stores and exports.
    @Attribute(.externalStorage) var receiptImageData: Data?

    var itemCostCents: Int = 0
    var shippingCents: Int = 0
    var taxCents: Int = 0
    var feesCents: Int = 0

    /// Dormant since 2026-09-22. No behavior reads or writes it. Kept for old stores and exports.
    var allocationMethodRaw: String = AllocationMethod.equal.rawValue

    /// The row's id in the BinderBooks ledger it was imported from. Empty for
    /// anything he entered in this app. See docs/04-seed-import.md.
    var sourceRef: String = ""

    @Relationship(deleteRule: .cascade, inverse: \PurchaseItem.purchase)
    var items: [PurchaseItem] = []

    @Relationship(deleteRule: .cascade, inverse: \Receipt.purchase)
    var receipts: [Receipt] = []

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
}

/// One line of a purchase: a sealed product, or cards. The record of what he
/// bought, linked to the cards it put in inventory.
@Model
final class PurchaseItem {
    #Unique<PurchaseItem>([\.id])

    var id: UUID = UUID()
    var productId: Int = 0
    var quantity: Int = 1
    var isSealed: Bool = false
    /// What this line's cards cost, from the last split. Fixed once the line
    /// is ripped. See `CostBasis.split`.
    var allocatedCostCents: Int = 0

    var purchase: Purchase?

    /// Dormant since 2026-09-22. No behavior reads or writes it. Kept for old stores and exports.
    var parentItem: PurchaseItem?

    /// Dormant since 2026-09-22. No behavior reads or writes it. Kept for old stores and exports.
    @Relationship(deleteRule: .cascade, inverse: \PurchaseItem.parentItem)
    var childItems: [PurchaseItem] = []

    /// The cards this line put in inventory. They share its cost. The delete
    /// rule is cascade, so delete a purchase only with `PurchaseEditor.delete`.
    @Relationship(deleteRule: .cascade, inverse: \OwnedCard.sourceItem)
    var cards: [OwnedCard] = []

    /// Dormant since 2026-09-22. No behavior reads or writes it. Kept for old stores and exports.
    var identifiedGroupId: Int?

    /// True once a card on this line was ripped. The line then keeps its
    /// cost: that money moved on to the pulls. See `CostBasis.moveRipCost`.
    var isRipped: Bool = false

    /// Dormant since 2026-09-22. No behavior reads or writes it. Kept for old stores and exports.
    var ripGroupId: UUID?

    init(productId: Int, quantity: Int = 1, isSealed: Bool = false) {
        self.id = UUID()
        self.productId = productId
        self.quantity = quantity
        self.isSealed = isSealed
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

    /// What the card came in at, in cents: its share of a purchase or of
    /// the packs it came from, or a cost he typed. Grading is not in it. See
    /// `CostBasis`.
    var acquisitionBasisCents: Int = 0
    /// Dormant. The grading share is read from the charges, not stored. See
    /// `CostBasis.gradingShares`. Kept for old stores and exports.
    var gradingBasisCents: Int = 0
    /// True when a split wrote `acquisitionBasisCents`.
    var basisIsAllocated: Bool = false
    /// True when he typed `acquisitionBasisCents`. A split does not change it.
    var basisIsManual: Bool = false

    /// Not individually accounted: one card with a count.
    var isBulk: Bool = false
    /// Cards he is keeping. Not inventory, and not counted in what he could
    /// sell today.
    var isPersonalCollection: Bool = false

    /// True while this card stands for an unopened sealed item itself, not a
    /// card pulled from one. Set on the cards `AddToInventorySheet` and
    /// `PurchaseIntake` write for a sealed product. Ripping the item deletes
    /// this card.
    var isSealedSelf: Bool = false

    /// The purchase line the card came in on. Nil for a card he scanned,
    /// pulled, or added by hand.
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

    /// A card that is not in the catalog, which he entered by hand. TCGplayer
    /// does not carry Italian or Korean prints, so these cards have no
    /// `productId`. These fields are the only card name the store holds. They
    /// stay empty on every catalog card. See docs/02-data-model.md.
    var manualName: String = ""
    var manualSetName: String = ""
    /// The number as printed: "025/165".
    var manualNumber: String = ""
    /// What he believes the card is worth, in cents. The catalog has no price
    /// for the card, so this value is its market value. Nil until he types one.
    var manualMarketCents: Int?

    /// True for a card he entered by hand: a name and no catalog product.
    var isHandEntered: Bool { productId == 0 && !manualName.isEmpty }

    /// A card marked untracked: no catalog product, no TCGCSV price, and no
    /// grading. His own price and, maybe, his own photo instead.
    var isSChinese: Bool { language == "zh-Hans" }

    /// The saved photo, if one exists. Precedence lives in the callers that
    /// build a `ProductThumbnail`, not here.
    var photoURLString: String? { CardPhotoStore.existingURL(for: id)?.absoluteString }

    /// True when the app knows the card, from the catalog or from his entry.
    /// `isIdentified` stays catalog-only, because the scan review, the comps
    /// fetch, the listing export, and the order import all need a `productId`.
    var hasIdentity: Bool { isIdentified || isHandEntered }

    /// The name to show: the catalog name, then his name, then the scanner text.
    func displayName(_ hit: SearchHit?) -> String? {
        if let hit { return hit.name }
        if !manualName.isEmpty { return manualName }
        return ocrName
    }

    func setName(_ hit: SearchHit?) -> String? {
        hit?.setName ?? (manualSetName.isEmpty ? nil : manualSetName)
    }

    func number(_ hit: SearchHit?) -> String? {
        hit?.number ?? (manualNumber.isEmpty ? nil : manualNumber)
    }

    init(productId: Int, printing: String, condition: String, confidence: MatchConfidence) {
        self.id = UUID()
        self.productId = productId
        self.printing = printing
        self.condition = condition
        self.matchConfidenceRaw = confidence.rawValue
        self.acquiredAt = Date()
        self.scannedAt = Date()
    }

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
    /// The catalogue the cards in this run come from, `ScanLanguage.rawValue`.
    ///
    /// He sets it before he scans. Nothing on the card says it reliably: Vision
    /// reads kana out of an English card's foil, and one invented kana used to
    /// send the whole match into the Japanese catalogue.
    var language: String = ScanLanguage.english.rawValue
    /// Dormant since 2026-09-22. No behavior reads or writes it. Kept for old stores and exports.
    var purchase: Purchase?
    /// Dormant since 2026-09-22. No behavior reads or writes it. Kept for old
    /// stores and exports. A rip keeps its packs in `UserDefaults`. See `Rip`.
    var ripTarget: PurchaseItem?

    @Relationship(deleteRule: .cascade, inverse: \OwnedCard.scanSession)
    var cards: [OwnedCard] = []

    /// Set IDs that have resolved during this session, most recent first.
    /// Drives the learned session bias. Not user-configured.
    var observedGroupIds: [Int] = []

    /// The sets this run is expected to be in.
    ///
    /// **Soft.** It adds a bonus to a candidate's score and never removes a
    /// candidate, so a card filed somewhere else — a Stellar Crown stamped
    /// print, a promo — still wins on the strength of its own number and name.
    ///
    /// Derived from the sealed products he is ripping, not asked for: the brief
    /// forbids a "choose your sets" step and is right to, because it would be a
    /// setup screen in front of the one action he does three hundred times a
    /// night. The chip in the scan screen lets him set or clear it when he
    /// knows better, and it is never required.
    var preferredGroupIds: [Int] = []

    init(defaultCondition: String = CardCondition.nearMint.rawValue, defaultPrinting: String? = nil) {
        self.id = UUID()
        self.startedAt = Date()
        self.defaultCondition = defaultCondition
        self.defaultPrinting = defaultPrinting
    }

    var isCommitted: Bool { committedAt != nil }

    /// English unless he said otherwise, including for a session written before
    /// the setting existed.
    var scanLanguage: ScanLanguage {
        ScanLanguage(rawValue: language) ?? .english
    }

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
// the sealed card leaves inventory, the pulls come in through a scan, and
// nothing writes a row for the opening itself. See `Rip`.

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

    @Relationship(deleteRule: .cascade, inverse: \Receipt.grading)
    var receipts: [Receipt] = []

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

/// One card inside a submission. The charge splits equally over the cards on
/// it, and each share counts in the card's cost.
@Model
final class GradingEntry {
    #Unique<GradingEntry>([\.id])

    var id: UUID = UUID()
    var submission: GradingSubmission?
    var card: OwnedCard?

    /// 10, 9.5. Nil until the submission returns.
    var grade: Double?
    var certNumber: String = ""
    /// Dormant since 2026-09-22. No behavior reads or writes it. Kept for old stores and exports.
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

    /// True when the fees and the postage are the app's estimate, not what the
    /// marketplace charged. The order import sets it: the sold-orders CSV has
    /// no fee column, and he cannot get the fees. `ChannelRates` and
    /// `FeeEstimate` leave these orders out, so an estimate never feeds the
    /// figure it came from.
    var costsEstimated: Bool = false

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

    /// Dormant since 2026-09-22. No behavior reads or writes it. Kept for old stores and exports.
    var basisCents: Int = 0
    /// Dormant since 2026-09-22. No behavior reads or writes it. Kept for old stores and exports.
    var basisIncomplete: Bool = false

    /// The card's name as the order recorded it. The store holds no card name,
    /// but a line whose card is unknown has nothing else to show.
    var describedAs: String = ""

    var sourceRef: String = ""

    init(sale: Sale? = nil, card: OwnedCard? = nil) {
        self.id = UUID()
        self.sale = sale
        self.card = card
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

    @Relationship(deleteRule: .cascade, inverse: \Receipt.expense)
    var receipts: [Receipt] = []

    init(date: Date = Date(), category: String = "", vendor: String = "", amountCents: Int = 0, note: String = "") {
        self.id = UUID()
        self.date = date
        self.category = category
        self.vendor = vendor
        self.amountCents = amountCents
        self.note = note
    }
}

/// The record of money out: a photo of a paper receipt, a screenshot of an
/// order page, or a PDF invoice.
///
/// A receipt belongs to one purchase, one grading charge, or one expense. An
/// entry can have many: a long receipt takes two photos. The receipt is the
/// fact. When the entry disagrees with it, the entry is wrong.
@Model
final class Receipt {
    #Unique<Receipt>([\.id])

    enum Kind: String {
        case image
        case pdf
    }

    var id: UUID = UUID()
    var addedAt: Date = Date()
    var kindRaw: String = Kind.image.rawValue
    /// A JPEG for an image, the file itself for a PDF.
    @Attribute(.externalStorage) var data: Data = Data()
    /// The name of a picked file. Empty for a photo or a scan.
    var fileName: String = ""
    /// The text the app read off it, for search later.
    var text: String = ""

    var purchase: Purchase?
    var grading: GradingSubmission?
    var expense: BusinessExpense?

    init(kind: Kind, data: Data, fileName: String = "", text: String = "") {
        self.id = UUID()
        self.addedAt = Date()
        self.kindRaw = kind.rawValue
        self.data = data
        self.fileName = fileName
        self.text = text
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .image }
}

enum CollectionStore {
    static let models: [any PersistentModel.Type] = [
        Purchase.self, PurchaseItem.self, OwnedCard.self, ScanSession.self,
        GradingSubmission.self, GradingEntry.self, Sale.self, SaleLine.self,
        BusinessExpense.self, Receipt.self,
    ]

    static func container(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
