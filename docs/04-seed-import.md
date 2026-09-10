# 04 — Seed Import

Source file: **`seed/binderbooks-export.json`**

This is AJ's real ledger from BinderBooks, the app this one replaces. It covers
**2026-04-20 through 2026-09-05** and it means the new app does not start empty and
does not need a reconstructed baseline.

Import is a **later phase**, not Phase 1. But read this before designing the models,
because the data contradicts one thing `02` originally assumed.

---

## Provenance and caveats

This file was reconstructed from a `localStorage` dump AJ pasted into a conversation,
then normalized. It is faithful on every field that matters for accounting, but it is
**not a byte-identical export**. Specifically:

- **Dropped:** `trend` price-history arrays, cached `grading` comp blobs, empty
  `tcgplayerId` fields, and all-zero `gradeEst` objects. All re-derivable or noise.
- **Dropped:** the per-line `lines[]` breakdown on `buys`. The composition survives in
  each buy's `item` string (e.g. `"6x Chaos Rising Booster Pack + 2x Perfect Order
  Booster Pack"`), which needs parsing rather than reading.
- **Fixed:** UTF-8 double-encoding in older records (`5Ã—` → `5x`). The original had
  mojibake; this file does not.
- **Kept:** every non-empty `gradeEst`. Those are AJ's hand-entered graded comps from
  Card Ladder and are expensive to recreate.

Before relying on this for anything with tax consequences, re-export from the live
BinderBooks site and diff against it.

---

## What's in it

| Array | Rows | Contents |
|---|---:|---|
| `buys` | 101 | Purchases and grading charges, with dates, vendors, totals |
| `rips` | 58 | Rip events with pulled hits, linked to buys by `buyId` |
| `inventory` | 285 | Cards with status, cost basis, market value, grading state |
| `sales` | 131 | Orders with price, fees, shipping, and per-card basis |

### Computed totals

```
Date range              2026-04-20 to 2026-09-05

Money out
  inventory purchases   $11,283.02   (93 buys)
  grading charges        $1,752.88   (8 charges)
  total                 $13,035.90

Money in
  gross sales            $3,551.59   (131 orders)
  fees / ship / consign / tax  $629.49
  net proceeds           $2,922.10

Held inventory
  market value           $3,107.74
  recorded basis         $3,865.11

Status counts
  Sold 152 · Kept 80 · At grading 43 · Listed 10
```

Monthly:

| Month | Buys | Grading | Net sales |
|---|---:|---:|---:|
| 2026-04 | $169.72 | $0.00 | $0.00 |
| 2026-05 | $2,911.72 | $73.98 | $1,329.57 |
| 2026-06 | $1,138.08 | $0.00 | $894.63 |
| 2026-07 | $686.45 | $0.00 | $386.71 |
| 2026-08 | $4,916.84 | $1,678.90 | $215.36 |
| 2026-09 | $1,460.21 | $0.00 | $95.83 |

The `$629.49` includes the `$0.98` of sales tax on four orders. `saleNet` in the
old app deducted tax with the fees, so the net figure above is right and only
the label was short.

**Read these as cash flows, not as profit.** August's $4,916.84 of buying is largely
still sitting in inventory or at a grader, and 43 cards are out for grading with their
upside unrealized. A periodic-inventory P&L over the period is
`revenue − (purchases − ending inventory) − expenses`, and ending inventory here is
understated because bulk was never recorded.

---

## The finding that changes the spec

**BinderBooks allocated rip cost by market value, and the results are unusable.**

`fn0g1g4b` — Crobat VMAX, market value **$1.97**, recorded cost basis **$72.29**.
Its two siblings from the same $193.39 buy carry $65.32 and $55.78. Three hits worth
$5.27 combined absorbed the entire purchase.

Equal split would not have fixed it: $193.39 ÷ 3 is $64.46 a card. The problem isn't
the allocation formula. It's that a $193 buy produced three recorded hits and nothing
else, so 100% of the cost had nowhere to go but three near-worthless cards.

`02` says excluding bulk from the denominator makes equal split behave sensibly. That
holds for a $4.97 pack with three hits (~$1.66 each). It fails completely at $193.
**Per-card cost basis on rip pulls is arbitrary at any allocation method.**

### Required change

Split behavior by acquisition type:

- **Purchased singles and slabs** — real per-card basis. AJ paid a specific price for
  a specific card. The Whatnot slab rows in this file (`costAuto: false`) show this
  working correctly: Groudon at $41 against $81.03 market, Chansey at $16 against $27.
- **Rip pulls** — allocate for tax purposes, and **report at the rip level too**.
  Mark per-card figures as allocated, so he can see which costs were derived.

`OwnedCard` needs a `basisIsAllocated: Bool`.

A sale needs lines. See the amendment in `02`: 30 of the 131 orders carry more
than one card, so `Sale` holds the money and `SaleLine` holds the cards.

**Amended 2026-09-10.** The rule used to end "never show an allocated basis next to a
market value as though the difference were a real gain or loss", and the inventory
hid the figure. AJ overruled it: "I just want to be able to calculate the cost of
each card based on the price of the item bought and then use that a gain or loss
reference when I sell the card." So the difference now shows on every card that has
both a cost and a market price. `basisIsAllocated` still marks a derived cost, and
the card detail still says the pack result is the truer read, but the app no longer
withholds the number he sells against.

The `costAuto` flag in this file is exactly that signal, already present: `true` means
BinderBooks computed it, `false` means AJ entered a real price. Map it directly.

---

## Data quality issues an importer must handle

1. **Missing `productId` on older rows.** Roughly the first third of `inventory` and
   many `rips` hits have no product ID — only name, set, and number. These need
   matching against the catalog, which is precisely what the Phase 1 search exists to
   do. Match on `number` + `setTotal` first, fall back to name, flag the rest for
   review rather than guessing.
2. **Zero-basis sold cards.** Many `sales[].cards[]` entries have `basis: 0` and no
   `invId`. Revenue is real; cost is unknown. Import the revenue, leave basis null,
   and mark the sale `basisIncomplete` rather than recording a fictitious 100% margin.
3. **Empty `cards[]` arrays.** About 30 May–June TCGplayer orders have price only and
   no line items. Same treatment: revenue counts, per-card attribution doesn't exist.
4. **Rip dates preceding their buy dates.** `s913sco5` is dated 2026-05-07 against buy
   `jf7ziut4` dated 2026-05-19. Don't assume rip date ≥ buy date.
5. **`seed: true` records.** Manually entered catch-up rows from initial setup, mostly
   vendor-name-only buys and eBay sales with no fees. Lower confidence; import but
   flag.
6. **`status: "Kept"` is the default**, applied to everything not sold or listed. It
   does **not** mean personal collection. Do not map it to `isPersonalCollection`.
7. **Grading charges live in `buys`** with `category: "Grading"`, not in a grading
   model. Six itemized submissions (Aug 17–31) plus two May charges. They carry a card
   count in the `item` string but no link to which cards. Reconcile against
   `inventory` rows with `status: "At grading"`.
8. **43 cards are currently at a grader**, including the outstanding May PSA
   submission: Psyduck ×2, Erika's Tangela, Banette (5/20), Teal Mask Ogerpon ex and
   Iron Valiant ex (5/13). These are inventory not physically in hand — enter from the
   submission, never from a scan. Ten of the 43 carry no per-card grading cost,
   because the two May charges were never spread over them.

Four more came out of profiling the file on 2026-09-10. The importer reports each
one rather than dropping the row:

9. **25 inventory rows carry a `hitId` that matches no hit.**
10. **28 hits have no inventory row.**
11. **53 `sales[].cards[].invId` values match no inventory row.**
12. **63 rows with `status: "Sold"` appear in no sale.**

And one field is simply gone. `sales` carries no `item`. The old app kept the
TCGplayer order number there (`src/App.jsx`, before the `Reset` commit) and the
normalisation dropped it, so **every imported `Sale` has an empty
`externalOrderId`**. A later TCGplayer or eBay order import has no dedupe key
against these rows and will double-count. Fix that before building it.

---

## Mapping to the new model

```
buys (category != Grading)  ->  Purchase
                                  vendor      <- source
                                  date        <- date
                                  itemCostCents <- cost
                                  note        <- item / name
                                  allocationMethod = .byMarketValue (historical)

buys (category == Grading)  ->  GradingSubmission
                                  grader      <- source
                                  date        <- date
                                  gradingFeesCents <- cost

rips                        ->  PurchaseItem (sealed, isRipped)
                                  purchase    <- buyId
                                  allocatedCostCents <- the buy's cost
                                  cards       <- hits[] -> OwnedCard

inventory                   ->  OwnedCard
                                  gradedCompCents    <- gradeEst
                                  productId          <- productId (may be null)
                                  acquisitionBasisCents <- cost
                                  basisIsAllocated   <- costAuto
                                  tags               <- status, as a reserved label (see #6)
                                  gradingBasisCents  <- gradingCost + gradingShip

sales                       ->  Sale
                                  grossCents  <- price
                                  marketplaceFeesCents <- fees + consign
                                  shippingCostCents <- shipping
                                  salesTaxCents <- tax

sales[].cards               ->  SaleLine
                                  card        <- invId (may be absent)
                                  basisCents  <- basis
                                  basisIncomplete <- basis == 0
                                  describedAs <- name
```

**Set `allocationMethod` to `.byMarketValue` on imported purchases.** That's what
actually happened. Don't retroactively re-allocate to equal split — it would change
historical basis on cards that have already sold, and the old numbers, distorted as
they are, are what was on the books at the time.

---

## Import behavior

- Idempotent, keyed on BinderBooks IDs, so re-running never duplicates.
- Import in dependency order: buys → rips → inventory → sales.
- Emit a report: rows imported, rows needing catalog matching, rows with incomplete
  basis. AJ should see what didn't come through cleanly rather than discovering it
  later in a P&L that doesn't reconcile.
- Never silently drop a row. If it can't be mapped, import what's mappable and flag it.

---

## How it runs

**Built 2026-09-10.** The import is a one-off, so the app holds no
BinderBooks-specific code. The file is format version 4, which carries no rips:
a rip becomes one sealed `PurchaseItem` on its purchase. See the amendment in
`02`. `scripts/import_binderbooks.py` converts the ledger
into a `cardtracker-collection` file and the app's own importer
(`ios/Sources/Model/CollectionExport.swift`, Settings → Import collection) loads
it. The converter writes `Int` cents, so no float ever reaches Swift.

```sh
gh release download catalog-latest -R ajhollowayvrm/binderbooks -p catalog.sqlite.gz
gunzip catalog.sqlite.gz
python3 scripts/import_binderbooks.py --catalog catalog.sqlite
python3 -m unittest discover -s scripts -v
```

It writes `seed/binderbooks-collection.json` and `seed/import-report.json`, and
both are committed: the first is what actually went onto his books, and the
second is the list of what did not.

**Every id is derived**, as `uuid5` over the BinderBooks id, so a second run
produces the same ids and the app's merge upserts instead of duplicating.

### Two rules

**Money always imports.** A purchase, a grading charge, a rip and a sale record
real money and do not need a catalog identity.

**A card the catalog cannot identify is held back.** The collection store
references the catalog by `productId` alone, so a card without one is not a
card. A sale line whose card is held back still imports, with no card link and
`basisIncomplete`. Put the real product ids in an overrides file
(`{"<binderbooks id>": <productId>}`), pass `--overrides`, and run again; the
derived ids make the second import add the cards and link the waiting lines.

### What came through, 2026-09-10

| | Rows |
|---|---:|
| Purchases | 93 |
| Grading submissions | 8 |
| Sealed lines, one per rip | 58 |
| Cards | 279 of 285 |
| Sales | 131 |
| Sale lines | 210 |

Money out and money in reconcile exactly with the totals above: `$11,283.02` of
purchases, `$1,752.88` of grading, `$3,551.59` gross and `$2,922.10` net.
`ios/Tests/InventoryAndExportTests.swift` asserts each of them against the real
file, and `scripts/test_import_binderbooks.py` asserts them against the source.

Held inventory reads `$3,830.96` rather than `$3,865.11`, and the `$34.15`
difference is the two held-back cards that are not sold.

### The six cards held back

Five are **First Partner Collection 2026** singles (Treecko, Torchic, Chespin,
Fennekin, Froakie). The catalog has that set, but it holds only sealed products
and code cards — TCGplayer has not listed the singles. The sixth is a
**Yu-Gi-Oh Blue-Eyes White Dragon**, which no configured category covers at all
(`00` lists Pokémon, Pokémon Japan, Digimon, Union Arena).

Neither is a matcher fault. Re-run with `--overrides` once TCGplayer lists the
First Partner singles.

### What still needs a hand

- **The 8 grading charges have no entries.** They name a card count and no
  cards, and joining them by grader and date would be a guess. Each card carries
  its own `gradingBasisCents` instead, and 9 of the 40 at-grader cards carry
  none, because the two May charges were never spread over them.
- **The 58 sealed lines carry `productId` 0.** A rip records a typed product
  name, not a catalog id.
- **124 of the 210 sale lines have no card**, and 70 have no basis.
