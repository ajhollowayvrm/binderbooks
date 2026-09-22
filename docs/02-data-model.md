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

**Amended 2026-09-22: no link between cards and purchases, and no per-card cost.**
AJ's decision. This amendment overrides every section below that allocates cost or
reads a basis.

- **No schema change.** No stored property is added or removed, and
  `CollectionExport.version` stays 9. These fields are dormant: no behavior reads or
  writes them. `CollectionExport` still exports and imports them, so an old file
  imports and his data round-trips.
  - `OwnedCard`: `acquisitionBasisCents`, `gradingBasisCents`, `basisIsAllocated`,
    `basisIsManual`, `sourceItem`.
  - `PurchaseItem`: `allocatedCostCents`, `isRipped`, `ripGroupId`, `parentItem`,
    `childItems`, `identifiedGroupId`, and the `cards` inverse.
  - `Purchase.allocationMethodRaw`, `ScanSession.purchase`, `ScanSession.ripTarget`.
  - `SaleLine.basisCents`, `SaleLine.basisIncomplete`, `GradingEntry.allocatedFeeCents`.
- **Deleting a purchase.** `PurchaseItem.cards` is still a cascade relationship, and
  an old import can bring the links back. So the app deletes a purchase only through
  `PurchaseEditor.delete`. It sets each linked card's `sourceItem` to nil first. No
  card is lost.
- **Purchases.** A purchase keeps its `PurchaseItem` lines as the record of what he
  bought. `PurchaseIntake` still adds each copy to inventory as a card, with
  `acquiredAt` at the purchase date, and with no link and no cost. A scan commits
  with no purchase.
- **Rips.** A rip remembers its packs in `UserDefaults`, one key for each scan
  session (`Rip`). The commit deletes the packs. A discarded scan leaves them sealed.
- **Grading.** A submission is one charge. No fee goes on a card.
- **Sales.** A line names the card that sold. It holds no cost, and an order has no
  gain.
- **Summary.** `profit = revenue − purchases − grading − expenses`, which equals
  money in less money out. "If you sold today" adds the market value of the held
  cards, less selling costs, with the personal collection left out. The grading
  outlook is gone: the Summary answers AJ's questions (what he has, spent, earned,
  and the potential). The potential counts a returned slab at its grade's comp,
  and adds a low and a best figure from the comps of the cards at a grader.

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

**Amended 2026-09-13.** The Add sheet can name what came in a purchase while he
records it. He searches the catalog and taps each product. Each product becomes one
`PurchaseItem` with one `OwnedCard` for each copy, the same shape
`AddToInventorySheet` writes, and a sealed product's cards carry `isSealedSelf`. The
landed total then splits over every copy. The list is optional: a note alone still
saves a purchase with no items, so the decoupling above holds. A blank note takes the
product names, for example "2x Chaos Rising Booster Pack, Charizard ex". The code is
`PurchaseIntake`.

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

### Rip groups

**Added 2026-09-17.** He opens a whole order in one sitting and records what came
out afterwards: *"I rip all the cards and then record what was ripped from that
total order."* So several packs rip as one rip, from the purchase page or from a
selection in inventory. The packs can come from different purchases.

- `PurchaseItem.ripGroupId: UUID?`. Lines ripped together share one value. Nil for
  a line ripped alone. It records no date and is not a `RipEvent`: it only says
  which lines' cost the pulls share.
- `RipPool.prepare` carves one line for each set of chosen packs on a line
  (`Allocation.carve`). Each line keeps its own purchase and its share of that
  purchase. **A pack's cost never moves to another purchase.**
- The pulls hang on one line, the **home line**: the line with the most packs.
  Each pull's basis is `(sum of the group's allocatedCostCents − pulls he priced) /
  tracked pulls`. Bulk takes none.
- The packs leave inventory when the scan commits (`RipPool.finish`). A discarded
  scan leaves them sealed (`RipPool.release`).
- A ripped line is always billable in `Allocation.allocate`. Its cost is what the
  packs cost, and bulk pulls do not take it away.
- A card already recorded as part of a buy can move into a rip
  (`RipPool.addPulls`). Its own line goes, and the purchase splits again.

Rip performance is read over the group:
`sum(market value of the pulls) − sum(allocatedCostCents of the group's lines)`.

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
  Amended 2026-09-15: a card worth $5 or more lists at its market price. On one
  upload the cheapest-listing rule put 9 such cards $19 under market.
- **Floor:** amended 2026-09-15. A card whose cheapest listing is under $0.20, not
  counting shipping, stays out of the file and takes no `listed` tag.
- **Value in the app:** amended 2026-09-15. Every screen shows a card's value by the
  same rule: market at $5 and up, the catalog's TCGplayer low price under $5, and the
  market price when there is no low price. `ProductPrice.valueCents` holds the rule.
- **Skipped:** graded slabs, sealed products, personal collection, cards at a grader,
  and sold cards. A card with no printing, on a product with several, is skipped too.
- **He picks** which of the rest go in the file. A card tagged `listed` starts unticked.
  The import adds quantity, so a second upload of the same card lists it twice.
- **Tagged on export.** Amended 2026-09-15: the cards in the file take the `listed` tag
  when the file is made. Undo takes the tag off again.

**Check against TCGplayer.** Built 2026-09-15. TCGplayer takes a copy off its stock when
a buyer pays, so its pricing export counts what is still for sale, open orders
included. AJ lists some cards by hand, and he often has open orders that the app has
not imported. Before an export he picks the pricing export in the sheet. For each SKU:

| Copies in the app | Meaning | What the check does |
|---|---|---|
| More tagged `listed` than TCGplayer's stock | Sold on TCGplayer, order maybe not imported | Counts them. The export already leaves them unticked. |
| Untagged, while TCGplayer has stock left over | Listed by hand | Tags them `listed`. |
| The other untagged copies of a SKU in the file | Probably a hand listing that sold | Unticks them and marks them "Was on TCGplayer". |
| Untagged, SKU not in the file | New | No change. |

The check is `TCGplayerStockCheck` in `ios/Sources/Model/TCGplayerListingImport.swift`.
It needs no sold-orders import first.

### Sold-orders import

**Built 2026-09-12.** Settings → Orders → Import sold orders reads TCGplayer's Sold
Items CSV. It also reads the same file with eBay rows added. The code is in
`ios/Sources/Model/SalesOrderCSV.swift` and `SalesOrderImport.swift`. See "Three
files, any combination" below for what it takes now.

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

**Order list and pull sheet.** Amended 2026-09-15: AJ cannot get the Sold Items CSV by
himself. TCGplayer's Orders page exports an order list and a pull sheet, and he picks
both files together. `TCGplayerOrderExports` in `SalesOrderCSV.swift` joins them into
the same orders:

- The order list has one row per order: number, date, status, product amount, and
  shipping. It has no cards.
- The pull sheet has one row per SKU. "Order Quantity" names each order that holds
  the SKU, with its count: `62955D06-A:1 | 62955D06-B:2`. Each order's count is the
  line's quantity, because "Quantity" can be less than the counts add up to.
- The pull sheet ends with an "Orders Contained in Pull Sheet:" row. It is not a card.
- A custom listing puts its title after the name: "Team Rocket's Wobbuffet: Team
  Rocket's Wobbuffet #203 SV Promo Destined Rivals". The import keeps the name before
  ": " when the title repeats it.
- On 2026-09-15 the pull sheet held 100 of the 149 orders in the list. The other 49
  (46 older orders and 3 canceled) came through with no cards.

**Three files, any combination.** Amended 2026-09-20: eBay's All Orders Report joins
the two TCGplayer exports, and the picker takes any number and combination of them.
`SalesOrderSources` in `SalesOrderSources.swift` decides what each file is from its
own columns, not from how many he picked, and reads them into one set of orders.
`EbayOrdersCSV.swift` reads the eBay report.

- **Order list** alone: the orders and their money, no cards on any of them.
- **Pull sheet** alone is refused. It holds no money, no date and no status.
- **eBay report**, alone or beside the others. Several are allowed: the report
  reaches about three months back, so a year of selling is four files.
- The **Sold Items CSV** is gone. He cannot export it himself, and mixed in with
  these it quietly lost its cards to the one-order-per-number rule below.
- One order per number across every file picked, first file read wins. Everything
  downstream keys on the number alone, so a repeat would otherwise be created twice.
- A row that will not read says which file to look in: "eBay orders line 7".

What eBay's report holds, verified on his export of 2026-09-20 (45 records):

- The first line is bare commas and the header is the second line, so the header is
  found by looking for it. A padding row follows it, and the file ends with
  "45,record(s) downloaded," and "Seller ID : …". A row with no date, no title and
  no price is the report's own furniture, not a row that would not read.
- A multi-item order is a summary row, blank in "Item Title", carrying the order's
  money, then one row per item. Record 119 sold for $28.00, its two items at $13.00
  and $15.00. The summary row is the money; its items are the lines, and their
  prices are not added on top. Without a summary row the rows add up.
- "Sold For" and "Shipping And Handling" are the money, not "Total Price", which
  adds the tax that `SalesOrderImport.ebayAllowanceCents` already allows for.
- Two rows carry no "Order Number". Their "Sales Record Number" is the order id.
  If eBay later gives one a real number, a re-import creates that sale a second time.
- There is no Status column, so no eBay order is ever canceled and a refund is not
  spotted.
- There is no Condition column either. `EbayOrdersCSV.grade(inTitle:)` takes the
  grade out of the listing title — "… CGC Pristine 10" — anchored on the grader
  word, because a title is full of other numbers. On all 45 records it reads every
  graded title right and nothing out of an ungraded one.
- The report carries buyer names, emails, phones and addresses. None is read, and
  the test fixture is redacted.

Each order goes to one of five places:

| Place | Rule | What changes |
|---|---|---|
| Already on the books | A sale has the order number, and records its cards. | Nothing. |
| Cards to add | A sale has the order number and records no cards, and the file names them. | The cards only. Each links to his oldest unsold copy that fits and gets the `sold` tag. The sale's money, fees and postage do not change. |
| Matched | A sale with no order number, dated 3 days before to 10 days after the order. TCGplayer: the same total to the cent; across channels the card names must also agree. eBay: the card names agree, and the amount is the item price or up to $6 more. | The sale takes the order number and the file's channel. Its money does not change. A sale with no cards gets the file's cards, with no link. |
| New | No sale matches. | A new sale with `costsEstimated`. Each card links to his oldest unsold copy that fits the condition and printing, or the grader and grade, and gets the `sold` tag. |
| To remove | A canceled order on the books, or a second sale with the same money on the same days as a settled order. | Nothing, unless he switches it on. A card on a removed sale goes back to inventory. |

A slab takes an eBay sale before a copy that still carries "at CGC". A match to a
sale with no cards adds lines with no link, because a link would take a copy he
still holds — unlike "Cards to add", where the order is his own and the copies
really are the ones that sold.

"Cards to add" exists because the order number alone used to settle an order.
The pull sheet reaches back only so far — on 2026-09-15 it held 100 of the 149
orders — and an order list imported on its own has no cards at all, so those
sales could never be filled in afterwards. A new order and a backfill draw from
the same copies, so they are walked together, oldest order first, and neither
takes a copy twice.

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

### Simplified Chinese removed

**Removed 2026-09-17.** From 2026-09-14 a Simplified Chinese card was a catalog card,
from a second catalog that the Mac built from PikaQian. The app merged it into the
live catalog, gave it a `productId` from 1,000,000,000 to 1,999,999,999, and kept a
listing photo for each card. AJ dropped all of it: Simplified Chinese cards rarely
sell, so PikaQian had too few prices to decide which cards to list on eBay.

- `ChineseRemoval` deleted the 43 cards in that id range, once, at launch. Their
  purchases keep their cost, as with any card delete.
- A Chinese sale is a sale with no card: he records the order and types the price.
  Its line has `basisIncomplete`, so the sale reports no gain.
- The language list for a hand-entered card still offers `zh-Hans` and `zh-Hant`.

### Choosing a purchase

**Built 2026-09-13.** Many cards reached inventory with no purchase: a scan
committed with no purchase, a card added by hand, a row from the old ledger. The
reconciliation of 2026-09-13 found 112 held cards with no cost and 79 purchases
with no cards. The money and the cards were both on the books, but not joined.
The code is `PurchaseLink`.

Where he joins them:

| Place | What it does |
|---|---|
| Card screen, Source | "Choose a purchase…", or "Change purchase…" |
| Inventory selection, `…` menu | "Choose a purchase…" for every selected card |
| Purchase screen | "Add cards from inventory…" |
| Inventory chips | "No purchase" shows only the cards with none |
| Ledger row | "no cards yet", "1 card", or "4 cards" before the note |

The rules:

- A card alone on its line moves with the line. A scan session can rip from
  that line (`ScanSession.ripTarget`), so the line is never left behind or
  deleted.
- A card that shares a line, such as two pulls from one pack, gets its own new
  line on the purchase, the way a scan commit does.
- An unopened box bought several at a time is isolated first, so only that box
  moves.
- A card with no cost takes its share and gets `basisIsAllocated`. A card with a
  cost the split did not write keeps it as his price and gets `basisIsManual`.
  That cost comes out of the purchase total first.
- The card takes the purchase's date.
- The purchase splits again, and so does every purchase the cards left, when
  `PurchaseEditor.canResplit` allows it. When it does not, the sheet says so.
- A sold card whose order line has no known cost takes the card's new cost. A
  known cost on an order line never changes.

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
