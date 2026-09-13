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

    /// True when he priced the card himself at review. A purchase total never
    /// overwrites it, and it leaves the total before the split.
    var basisIsManual: Bool

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
    var scanSession: ScanSession?

    /// What he believes the card sells for at each grade, in cents, keyed by
    /// the grade as printed: "10", "9.5". Entered by hand from Card Ladder.
    var gradedCompCents: [String: Int]

    /// The row's id in the BinderBooks ledger it was imported from. Empty for
    /// anything entered in this app. Also on `Purchase`, `Sale`, `SaleLine`,
    /// and `GradingSubmission`. See `04`.
    var sourceRef: String

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

### Pricing at review

He prices a batch by **total**, not per card: he knows what the lot cost. The
Cost button on the review screen splits one total evenly over the selected
cards and sets `basisIsManual`.

The purchase total then covers everything else. What he priced leaves the total
first, and the remainder splits over the rest. A split over several cards stays
`basisIsAllocated`, because a per-card figure derived from a lot price is the
artifact `04` describes. A split cost still shows a gain, because that is the figure
he sells against; the flag reports how the cost was reached, and hides nothing.

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

Specified so Phase 1 doesn't require migrations later. `GradingSubmission`,
`GradingEntry`, `Sale`, and `SaleLine` were **built on 2026-09-10**, ahead of
their phase, because the seed import in `04` carries those rows and holding them
back would have lost the history.

### There is no RipEvent

**Removed 2026-09-10.** This section specified a `RipEvent` model, and the seed
import wrote 58 of them. AJ overruled it: *"We don't really need to record a rip.
The Rip can be a temporary screen that just adds stuff to the inventory with the
right cost basis."*

Opening a pack is an **intake path, not a record**. He opens a purchase, taps
Open it, scans what came out, and the cards land in inventory carrying their
share of what the purchase cost. Nothing writes a row for the opening.

Nothing was lost with the model. The sealed `PurchaseItem` **is** the pack: it
holds the cost, its `childItems` hold nested packs, and its `cards` hold the
pulls. `RipEvent` only added a date and a second pointer at that item.

Rip performance is therefore read on the purchase:
`sum(market value of the sealed item's cards) − sealedItem.allocatedCostCents`.
Read it there rather than per card. Under any allocation the hit shows a large
gain and the filler shows small losses, and that is an artifact of the method.
The per-card figure still shows, because it is what he compares a sale against
(see the amendment in `04`).

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

### Sale and SaleLine

**Amended 2026-09-10.** This section gave `Sale` a single `card`. His real
ledger disproves it: 30 of his 131 orders carry more than one card and one
carries 18, because a TCGplayer order is one payment over several cards. So the
sale holds the money and its lines hold the cards, the way a purchase holds its
items. A line points at an owned card **or** a sealed item, because a premium
collection sometimes holds more value unopened than ripped.

```swift
@Model final class Sale {
    var id: UUID = UUID()
    var soldAt: Date
    var channelRaw: String           // tcgplayer / ebay / whatnot / local

    var grossCents: Int
    var marketplaceFeesCents: Int
    var salesTaxCents: Int
    var shippingChargedCents: Int
    var shippingCostCents: Int
    var otherFeesCents: Int

    /// eBay orderId / TCGplayer order number. Dedupe key for later import.
    /// Empty on every imported row — see `04`.
    var externalOrderId: String
    /// True when the fees and the postage are estimates. The sold-orders
    /// import sets it. See "Sold-orders import" below.
    var costsEstimated: Bool

    @Relationship(deleteRule: .cascade, inverse: \SaleLine.sale)
    var lines: [SaleLine]

    var netCents: Int {
        grossCents + shippingChargedCents
            - marketplaceFeesCents - salesTaxCents - shippingCostCents - otherFeesCents
    }
}

@Model final class SaleLine {
    var id: UUID = UUID()
    var sale: Sale?
    var card: OwnedCard?
    var sealedItem: PurchaseItem?    // one of these two, or neither

    var basisCents: Int
    /// True when the cost of what sold is unknown.
    var basisIncomplete: Bool
    /// The card's name as the order recorded it. The store holds no card name,
    /// but a line whose card is unknown has nothing else to show.
    var describedAs: String
}
```

`realizedGainCents = sale.netCents − Σ line.basisCents`, and it is **nil when
any line has no basis**. Many of his older orders record a price and no card at
all. A sale with an unknown cost must not report a gain, because the gain would
be the whole price.

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

### TCGplayer listing export

**Built 2026-09-11.** The app writes the CSV that TCGplayer's Seller Portal imports
(Inventory → Import Inventory, Level 4 sellers only). Open it from Settings, or from
the `…` menu in inventory selection. Nothing is stored: the export reads the cards and
writes a file.

The import matches each row on its SKU. The catalog has no SKUs, because TCGCSV has no
SKU endpoint. So at export time the app asks TCGplayer's storefront endpoints, which
need no key, for each SKU (`ios/Sources/Comps/TCGplayerMarketClient.swift`). This is
the one place the app reads TCGplayer directly. TCGplayer does not document these
endpoints. If they change, the export stops and the rest of the app is not affected.

AJ's rules:

- **Price:** the cheapest live listing of the same SKU, by price plus shipping, less
  the shipping he charges. A SKU with no live listing takes the catalog market price.
- **Skipped:** graded slabs, sealed products, personal collection, cards at a grader,
  and sold cards. A card with no printing, on a product with several, is skipped too.
- **He picks** which of the rest go in the file. A card tagged `listed` starts unticked.
  The import adds quantity, so a second upload of the same card lists it twice.

### Sold-orders import

**Built 2026-09-12.** Settings → Orders → Import sold orders reads TCGplayer's Sold
Items CSV. It also reads the same file with eBay rows added. The code is in
`ios/Sources/Model/SalesOrderCSV.swift` and `SalesOrderImport.swift`.

The import works on the live store, not through a collection file.
`CollectionExport.apply` cannot delete a row, and it overwrites every card that he
edited on the phone. He reviews the plan first. The app saves nothing until he taps
Import.

What the file holds:

- One row is one line of an order. The money columns belong to the order and repeat
  on every line. The import reads them one time for each order.
- The file has no fee columns.
- An eBay row has no set, number, or SKU. The card is in the listing title, and the
  grade is in "Condition".
- The import never reads "Buyer Name".

Each order goes to one of four places:

| Place | Rule | What changes |
|---|---|---|
| Already on the books | A sale has the order number. | Nothing. |
| Matched | A sale with no order number, dated 3 days before to 10 days after the order. TCGplayer: the same total to the cent; across channels the card names must also agree. eBay: the card names agree, and the amount is the item price or up to $6 more. | The sale takes the order number and the file's channel. Its money does not change. A sale with no cards gets the file's cards, with no link. |
| New | No sale matches. | A new sale with `costsEstimated`. Each card links to his oldest unsold copy that fits the condition and printing, or the grader and grade, and gets the `sold` tag. |
| To remove | A canceled order on the books, or a second sale with the same money on the same days as a settled order. | Nothing, unless he switches it on. A card on a removed sale goes back to inventory. |

A slab takes an eBay sale before a copy that still carries "at CGC". A match to a
sale with no cards adds lines with no link, because a link would take a copy he
still holds.

**Estimated costs.** `FeeEstimate` fits a fixed fee plus a rate for each channel, by
least squares over his orders with real fees. Part of each fee is fixed: a $1.56
TCGplayer order paid $0.51, and a rate alone gets that wrong. Postage is the median
postage he recorded on the channel. A channel with fewer than 5 orders uses the fit
over all channels. `ChannelRates` and `FeeEstimate` skip estimated sales, so an
estimate never feeds itself. Export format version 7 carries the flag.

**On his seed books, 2026-09-12:** 122 orders. 87 matched, and 2 of them moved from
TCGplayer to eBay. 33 are new. The plan offers 1 canceled sale and 2 duplicates for
removal. `RealSalesOrderImportTests` checks these numbers when
`build/sales/sold-orders.csv` and `scripts/catalog.sqlite` are present. The CSV is
his export with the buyer names removed. `build/` is never committed.

### TCGplayer listings import

**Built 2026-09-13.** Settings → TCGplayer → Import TCGplayer listings reads Seller
Portal's pricing export. It also reads two exports joined into one file, such as the
English export and the Japanese export. The code is in
`ios/Sources/Model/TCGplayerListingImport.swift`.

AJ asked for this so that he can mass upload cards to TCGplayer from the app. The
listing export uploads only the cards in inventory without the `listed` tag. Stock
that he listed before the app existed was not in inventory, or it had no tag. This
import puts that stock into inventory with the tag, so the next export uploads only
new cards.

What the file holds:

- One row is one SKU. "Total Quantity" is the copies the store lists now. Most rows
  say 0, because the file holds every SKU the store ever listed. The import reads
  only the rows with stock.
- Some ids are not numbers: "C-4505111". His export of 2026-09-13 holds 24 of them,
  and all 24 have no stock. The import reads the stock before the id. A row with
  such an id and stock is reported as not read.
- The file names the set, the number, and the product name the way a sold-orders row
  does. `SalesOrderCatalog.tcgplayerProduct` finds the product for both files.
- The file has no cost and no purchase date. The import creates no purchase.

Each copy goes to one of three places. Held copies count first, so a card that is on
the books and on TCGplayer is never added twice:

| Place | Rule | What changes |
|---|---|---|
| Already listed | A held copy of the product, condition, and printing has the `listed` tag. | Nothing. |
| To tag | A held copy has no `listed` tag. A copy with no printing fits any printing. | The card takes the tag, the SKU id, and the file's printing when it had none. |
| To add | No held copy is left. | A new card with the tag and the SKU id. |

A held copy is a card that the sold-orders import could sell: identified, committed,
not sold, not personal, and not a sealed item. A slab or a card at a grader never
fits a raw SKU. The import never removes a tag or a card. He can type a total cost
for the new cards, and it splits evenly with `basisIsManual`, the same as a cost in
`AddToInventorySheet`. A row that the catalog cannot name imports nothing, and the
review sheet lists it.

`RealTCGplayerListingImportTests` runs when `build/listings/pricing-export.csv` and
`scripts/catalog.sqlite` are present. It requires every row with stock to find its
product.

### Hand-entered cards

**Built 2026-09-12.** AJ owns Chinese and Italian Pokémon cards. TCGplayer carries
neither language, so no `productId` exists for them. He enters them by hand: search
for the card, then tap "Not in the catalog? Add it by hand". The search text fills
the name.

This is the one exception to "the store never embeds a card name". The card keeps
`productId` 0 and these fields on `OwnedCard`:

| Field | Holds |
|---|---|
| `manualName` | The name as he types it, in any script. |
| `manualSetName`, `manualNumber` | Optional. The number answers a number search. |
| `language` | A BCP 47 code: `zh-Hans`, `it`. A catalog card keeps `en`. |
| `manualMarketCents` | Optional. His value. The inventory uses it as the market value. |

`isIdentified` still means "has a catalog product". The scan review, the comps fetch,
the TCGplayer listing export, and the sold-orders import need a `productId`, so they
skip a hand-entered card. `hasIdentity` is true for both kinds, and the confidence
marker reads it. The card detail screen edits these fields on any card with
`productId` 0, which includes imported rows that never had a product. Export format
version 8 carries the fields.

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
