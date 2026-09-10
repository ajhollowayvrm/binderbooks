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
  fees / ship / consign    $629.49
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
- **Rip pulls** — allocate for tax purposes, but **report at the rip level**. Mark
  per-card figures as allocated, not as truth. Never show an allocated basis next to a
  market value as though the difference were a real gain or loss.

`OwnedCard` needs a `basisIsAllocated: Bool`. The inventory view must not render a
red loss number for a card whose basis is an artifact.

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
   submission, never from a scan.

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

rips                        ->  RipEvent
                                  sealedItem  <- PurchaseItem from buyId
                                  pulls       <- hits[] -> OwnedCard

inventory                   ->  OwnedCard
                                  productId          <- productId (may be null)
                                  acquisitionBasisCents <- cost
                                  basisIsAllocated   <- costAuto
                                  tags               <- status, as a reserved label (see #6)
                                  gradingBasisCents  <- gradingCost + gradingShip
                                  gradedComps        <- gradeEst

sales                       ->  Sale
                                  grossCents  <- price
                                  marketplaceFeesCents <- fees + consign
                                  shippingCostCents <- shipping
                                  salesTaxCents <- tax
                                  card        <- cards[].invId (may be absent)
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
