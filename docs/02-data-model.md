# 02 — Data Model

Supersedes any earlier schema draft. The significant change from that draft: **there
is no CloudKit**, because the free developer account can't have it. Models are
therefore written naturally — non-optional properties, unique constraints where they
belong — rather than contorted to satisfy a sync layer that isn't shipping.

Phase 1 builds `Purchase`, `PurchaseItem`, `OwnedCard`, and `ScanSession`. Everything
else is specified so Phase 1 doesn't paint itself into a migration, but is not built
yet. Build the Phase 1 models to these shapes even where fields go unused.

---

## Two stores

| | Catalog | Collection |
|---|---|---|
| Contents | Every product in the configured categories | His purchases, cards, submissions, sales |
| Size | ~150k rows | Hundreds to low thousands |
| Source | Downloaded (see `01`) | Created by him |
| Tech | SQLite via GRDB, read-only | SwiftData, local |
| Rebuildable | Yes, disposable | **No — irreplaceable** |

The collection store references the catalog by integer `productId` only. It never
embeds a card name or a price. If TCGplayer renames a product or the catalog is
rebuilt from scratch, nothing in his data breaks.

**Backups matter more than usual here** because there's no sync. Ship JSON
export/import in Phase 1, and make export trivially reachable — one tap from settings.
A full export of the collection store is small enough to be a single file.

---

## Money

`Int` cents, everywhere, in both stores. No `Double` ever touches a monetary value.

Display goes through one helper and nothing else:

```swift
extension Int {
    /// Cents -> "$1,234.56". Always two decimals.
    var asCurrency: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(value: self).dividing(by: 100)) ?? "$0.00"
    }
}
```

`NSDecimalNumber`, not `Double`. Dividing cents by 100 in `Double` reintroduces
exactly the artifact that was removed at ingest.

Input parses through `Decimal`, with a `.decimalPad` keyboard and a third decimal
digit rejected at the field level so bad input never reaches a model:

```swift
func centsFrom(_ text: String) -> Int? {
    let filtered = text.filter { $0.isNumber || $0 == "." }
    guard let d = Decimal(string: filtered) else { return nil }
    return NSDecimalNumber(decimal: d * 100).rounding(accordingToBehavior: nil).intValue
}
```

---

## Phase 1 models

### Purchase

Money left his account. Deliberately says nothing about what was bought — that's
`Intake`. Decoupling these two is the fix for the flow that made his old app painful.

```swift
@Model final class Purchase {
    #Unique<Purchase>([\.id])

    var id: UUID = UUID()
    var date: Date
    var vendor: String              // free text: "Walmart", "Whatnot", "Fuzzy's". Not a dimension.
    var note: String                // what he'd write on a receipt
    var receiptImageData: Data?

    var itemCostCents: Int
    var shippingCents: Int
    var taxCents: Int
    var feesCents: Int

    var allocationMethodRaw: String

    @Relationship(deleteRule: .cascade, inverse: \PurchaseItem.purchase)
    var items: [PurchaseItem]

    var landedCostCents: Int { itemCostCents + shippingCents + taxCents + feesCents }

    var allocationMethod: AllocationMethod {
        get { AllocationMethod(rawValue: allocationMethodRaw) ?? .equal }
        set { allocationMethodRaw = newValue.rawValue }
    }
}

enum AllocationMethod: String, Codable, CaseIterable {
    case equal            // default
    case byMarketValue    // available per-purchase, no migration needed
    case manual
}
```

`vendor` exists for bookkeeping — he wants to know where something came from. It is
**not** a reporting dimension. Do not normalize it, do not build a vendor entity, do
not fuzzy-match "WAL-MART #1234" against "Walmart". He explicitly does not want
per-vendor performance analysis.

### PurchaseItem

One line of a purchase: a sealed product, or cards. Sealed items nest.

```swift
@Model final class PurchaseItem {
    #Unique<PurchaseItem>([\.id])

    var id: UUID = UUID()
    var productId: Int              // -> catalog product
    var quantity: Int
    var isSealed: Bool
    var allocatedCostCents: Int     // written by the allocator, not by hand

    var purchase: Purchase?

    /// Set when this item came out of ripping a larger sealed item.
    /// A premium collection yields 14 pack items, each with this pointing at the box.
    var parentItem: PurchaseItem?

    @Relationship(deleteRule: .cascade, inverse: \PurchaseItem.parentItem)
    var childItems: [PurchaseItem]

    @Relationship(deleteRule: .cascade, inverse: \OwnedCard.sourceItem)
    var cards: [OwnedCard]

    /// Set on a pack once its wrapper has been read. Nil until then.
    var identifiedGroupId: Int?

    var isRipped: Bool
}
```

**On nesting.** A Legendary Warriors Premium Collection contains 2 foil Zacian V and
Zamazenta V, 2 foil Zacian and Zamazenta, 1 oversize foil Zacian V, 14 booster packs,
and a code card. Opening it produces 5 identified cards plus 14 sealed children, each
separately rippable and from mixed Sword & Shield sets. Cost flows down the tree: box
cost splits across contents, each pack carries its share, ripping a pack splits that
share among its hits. This is recursive, not two-level.

Booster wrappers print the expansion, so the packs can be identified at box-open time
by reading them — `identifiedGroupId` is set then, not deferred to rip time. What
can't be known before purchase is which sets a given box will contain.

### OwnedCard

```swift
@Model final class OwnedCard {
    #Unique<OwnedCard>([\.id])

    var id: UUID = UUID()
    var productId: Int
    var skuId: Int?
    var printing: String            // Normal / Holofoil / Reverse Holofoil
    var condition: String
    var language: String
    var quantity: Int               // >1 only for undifferentiated bulk

    var acquiredAt: Date
    /// Superseded by `tags`. Kept for one release, because a dropped field
    /// cannot be read back and his backups still carry it.
    var statusRaw: String

    /// Free-form labels he typed. Replaced the status picker.
    var tags: [String]

    /// Allocated at intake. Not mutated afterward.
    var acquisitionBasisCents: Int
    /// Added when a grading submission returns. Zero for raw cards.
    var gradingBasisCents: Int

    /// True for cards not individually accounted. Excluded from allocation
    /// denominators. May still carry identity for listing purposes.
    var isBulk: Bool

    /// Cards he's keeping. Not inventory; excluded from COGS.
    var isPersonalCollection: Bool

    var sourceItem: PurchaseItem?
    var sourceRip: RipEvent?
    var scanSession: ScanSession?

    /// How sure the scanner was. Drives review filtering; survives commit so a
    /// shaky match stays visible later.
    var matchConfidenceRaw: String

    var totalBasisCents: Int { acquisitionBasisCents + gradingBasisCents }
}

enum CardStatus: String, Codable {
    case owned, atGrader, gradedReturned, listed, sold, lost
}

enum MatchConfidence: String, Codable {
    case manual      // he picked it by hand
    case certain     // unique match on name + number + setTotal
    case likely      // one strong candidate, some ambiguity
    case uncertain   // several candidates, or a guessed printing
}
```

### Tags

**Free-form labels, and they replaced `CardStatus`.** He types any label: "binder 3",
"for sale", "PSA queue". A card holds several. `TagKey` folds case and inner space
but never punctuation, because a label is his own text and `NameCleaner` would merge
"PSA-queue" into "PSA queue". The suggestion list is derived from the cards on every
read, never stored, so a deleted card drops out at once.

The reserved labels `sold`, `listed`, `at grader`, `graded`, and `lost` carry what
the status field carried. The later sale and grading flows write those labels.
`StatusTagBackfill` copies each card's old status into its label once.

**A tag is a note, not a dimension.** Nothing aggregates money by tag. A "market
value by tag" tile would cross decision 23 in `00-brief.md`, which forbids a
reporting layer.

`acquisitionBasisCents` and `gradingBasisCents` are separate and neither overwrites
the other, so a card's raw cost and its slab cost stay legible forever.

### ScanSession

A scanning run. Commits as a batch.

```swift
@Model final class ScanSession {
    #Unique<ScanSession>([\.id])

    var id: UUID = UUID()
    var startedAt: Date
    var committedAt: Date?
    var defaultCondition: String
    var defaultPrinting: String?
    var purchase: Purchase?          // what these cards came from

    @Relationship(deleteRule: .cascade, inverse: \OwnedCard.scanSession)
    var cards: [OwnedCard]

    /// Set IDs that have resolved during this session, most recent first.
    /// Drives the learned session bias. Not user-configured.
    var observedGroupIds: [Int]
}
```

**Persist every match to disk as it lands.** Three hundred cards deep is the wrong
moment to find out the session lived in memory.

---

## Allocation

### Penny-safe equal split

```swift
/// Splits `totalCents` into `count` shares that sum back to exactly `totalCents`.
func splitEqually(_ totalCents: Int, into count: Int) -> [Int] {
    guard count > 0 else { return [] }
    let base = totalCents / count
    let remainder = totalCents % count
    return (0..<count).map { $0 < remainder ? base + 1 : base }
}
```

`splitEqually(100000, into: 3)` → `[33334, 33333, 33333]`.

### Across a purchase

Expand by quantity — a line of 4 copies is 4 shares, not 1. **Exclude bulk.**

```swift
func allocate(_ purchase: Purchase) {
    let billable = purchase.items.filter { !$0.isBulkOnly }
    guard !billable.isEmpty else { return }

    let unitCount = billable.reduce(0) { $0 + $1.quantity }
    let shares = splitEqually(purchase.landedCostCents, into: unitCount)

    var cursor = 0
    for item in billable {
        item.allocatedCostCents = shares[cursor ..< cursor + item.quantity].reduce(0, +)
        cursor += item.quantity
    }
}
```

**Why bulk is excluded.** A $4.97 pack yielding 3 hits and 7 commons gives each hit
~$1.66 rather than spreading ~$0.50 across ten cards, seven of which are worth
nothing and will be sold to his LGS for a few dollars as part of a pile. Excluding
bulk from the denominator is what makes equal split — his stated preference — behave
sensibly. Bulk technically retains a cost claim, but at roughly $5 per thousands of
cards it rounds to nothing.

For `byMarketValue`, weight by each item's current market price from the catalog and
give any rounding remainder to the highest-value item.

---

## Later-phase models

Not built in Phase 1. Specified so Phase 1 doesn't require migrations later.

### RipEvent

Consumes a sealed `PurchaseItem`. Output is **polymorphic**: cards and/or child
sealed items.

```swift
@Model final class RipEvent {
    var id: UUID = UUID()
    var rippedAt: Date
    var sealedItem: PurchaseItem?

    @Relationship(deleteRule: .nullify, inverse: \OwnedCard.sourceRip)
    var pulls: [OwnedCard]

    /// Count of cards not individually tracked. No rows created for these.
    var bulkCount: Int
}
```

Rip performance = `sum(market value of pulls) − sealedItem.allocatedCostCents`.

Read rip performance at the **pack** level, not per card. Under equal split the hit
shows a large gain and any tracked filler shows small losses; that's an artifact of
the method, not a signal.

### Grading

```swift
@Model final class GradingSubmission {
    var id: UUID = UUID()
    var graderRaw: String            // psa / cgc / bgs / tag
    var submissionNumber: String
    var serviceLevel: String
    var declaredValueCents: Int

    var shippedAt: Date?
    var returnedAt: Date?

    var gradingFeesCents: Int
    var shipToGraderCents: Int
    var shipReturnCents: Int
    var insuranceCents: Int

    @Relationship(deleteRule: .cascade, inverse: \GradingEntry.submission)
    var entries: [GradingEntry]

    var totalCostCents: Int {
        gradingFeesCents + shipToGraderCents + shipReturnCents + insuranceCents
    }
}

@Model final class GradingEntry {
    var id: UUID = UUID()
    var submission: GradingSubmission?
    var card: OwnedCard?

    var grade: Double?               // 10, 9.5 — nil until returned
    var certNumber: String
    var allocatedFeeCents: Int
    var noGrade: Bool                // N0 / altered / rejected
}
```

Two flows, not one. **Send** marks cards `.atGrader` and records fees. **Return**
applies grades, cert numbers, and fee basis. Returns are messier than they sound:
cards come back ungradeable, and occasionally the count differs from what was sent.

Fee allocation is equal across entries — correct here, since the grader charged per
card.

**A PSA submission from May 2026 is still outstanding.** Those cards get entered from
the submission form rather than scanned; they're inventory he doesn't physically hold.

**Slab display.** He wants graded cards rendered in inventory as a small slab
representation showing the cert number. Read certs from the label **barcode** via
`VNDetectBarcodesRequest` — deterministic, and far more reliable than OCR on label
text.

**Graded values are manual.** No automated comp source exists: eBay's Marketplace
Insights API is limited-release and rarely granted, and as of 2026-07-22 eBay
redirects signed-out visitors to a login on any sold or completed search. He has a
Card Ladder subscription and will enter comps by hand.

### Sale

Must reference **either** an owned card or a sealed item — premium collections
sometimes hold more value unopened than ripped.

```swift
@Model final class Sale {
    var id: UUID = UUID()
    var card: OwnedCard?
    var sealedItem: PurchaseItem?    // exactly one of these two is set

    var soldAt: Date
    var channelRaw: String           // tcgplayer / ebay / whatnot / local

    var grossCents: Int
    var marketplaceFeesCents: Int
    var salesTaxCents: Int
    var shippingChargedCents: Int
    var shippingCostCents: Int
    var otherFeesCents: Int

    /// eBay orderId / TCGplayer order number. Dedupe key for later import.
    var externalOrderId: String

    var netCents: Int {
        grossCents + shippingChargedCents
            - marketplaceFeesCents - shippingCostCents - otherFeesCents
    }
}
```

`realizedGainCents = sale.netCents − card.totalBasisCents`

### BulkDisposition

Selling a pile as one transaction — his LGS pays about $5 for a large quantity.

```swift
@Model final class BulkDisposition {
    var id: UUID = UUID()
    var date: Date
    var destination: String
    var approximateCount: Int
    var proceedsCents: Int
}
```

### BusinessExpense

Costs that hit P&L but attach to no card: mailers, Breaale rigid protectors, ding
defenders, team bags, toploaders, sleeves, postage, Card Ladder subscription. Not
trivial at his volume, and none of his named flows had anywhere to put them.

```swift
@Model final class BusinessExpense {
    var id: UUID = UUID()
    var date: Date
    var category: String
    var vendor: String
    var amountCents: Int
    var note: String
}
```

### PeriodSummary

Supports P&L over a period without pretending every card has a known basis:

```
COGS = beginningInventory + purchases − endingInventory
P&L  = revenue − COGS − expenses
```

He wants P&L reaching back to his first card purchase. Starting the books there makes
beginning inventory `$0` — a fact rather than an estimate — and removes the only soft
number from the calculation.

```swift
@Model final class PeriodSummary {
    var id: UUID = UUID()
    var startsOn: Date
    var endsOn: Date
    var beginningInventoryCents: Int
    var endingInventoryCents: Int
    var purchasesCents: Int
    var revenueCents: Int
    var expensesCents: Int
}
```

### Also later

- **Returns and refunds** — a buy refunded or a sale returned. Both reverse, and both
  double-count easily against bank rows.
- **Personal collection transfer** — moving a card in or out of inventory. Changes COGS.
- **Corrections** — fixing a misidentified card; splitting a stack of 4 to grade one.
- **Listing status** — `listed` with a listing price, if he wants to see what's sitting.
- **Loss and damage** — write-offs.
- **No trades.** His loop is buy / rip / sell.

---

## Calculators

Read-only, no models of their own.

### Purchase decision

Answers "Legendary Warriors or the Moltres UPC?" using only catalog data. Sealed
products, promos, and loose packs are all in the catalog already.

```
A  price he'd pay
B  Σ promo market values           (low variance, recoverable)
C  packCount × loose pack price    (packs' unopened worth)
D  the sealed product's own market price

part it out:  B + C − A
flip sealed:  D − A
effective per-pack cost after promos:  (A − B) ÷ packCount
```

That last number is what makes two dissimilar boxes comparable.

**Lead with discount to market (`D − A`), not EV.** He rips because he enjoys ripping
and buys on "good deal" more than expected value. Show EV as context. **Never render
a verdict** telling him not to rip something — a tool that does that is one he stops
opening.

Deliberately does not model pull EV. That needs pull rates and full set pricing, and
it's where these calculators manufacture false precision. Loose pack market price
already embeds the market's collective estimate.

### Grade or not

```
rawValue       = catalog market price for productId + printing
gradingCost    = per-card fee + share of shipping both ways + insurance
expectedGraded = Σ (P(grade g) × his entered comp for grade g)
expectedNet    = expectedGraded × (1 − feeRate) − gradingCost
verdict        = expectedNet − rawValue × (1 − feeRate)
```

Seed grade probabilities from his SnapGradeAI pre-grade, then correct against his own
returns over time.

### Bulk listing floor

He wants to test listing bulk on TCGplayer. Given his actual fee rates and roughly
what handling a card costs him in time, compute the minimum card value where listing
individually beats adding it to the LGS pile. Everything under that line goes to the
pile without further thought.

Use **his** fee numbers, entered in settings — he knows his TCGplayer rates better
than any hardcoded assumption, and they change.
