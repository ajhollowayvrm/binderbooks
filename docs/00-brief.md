# Card Tracker — Build Brief

Read this file first. `01` is the catalog pipeline, `02` is the data model, `03` is
the Phase 1 build spec, `04` covers importing his existing ledger from
`seed/binderbooks-export.json`. Everything in `02` and `03` assumes the decisions
recorded here.

**`04` amends `02`.** Real data showed that per-card cost basis on rip pulls is
arbitrary regardless of allocation method. Where the two documents disagree about
rip basis, `04` wins.

---

## Who this is for

A single user, AJ, who runs a card reselling operation:

- Sells singles on **TCGplayer** (store: IBuyTooManyCards) and **eBay**
- Buys inventory at **Walmart**, on **Whatnot** (including graded slab lots), and at
  local shops
- Primarily **Pokémon**, expanding into **Digimon** (BT-26 Timeless Bonds) and
  **Union Arena** (UE10 Attack on Titan)
- Grades with **PSA** and **CGC**; pre-screens with SnapGradeAI; prices with
  Card Ladder
- Buys sealed, rips it, sells the hits, dumps the bulk

This app replaces **Collectr**, which he currently uses and finds inadequate. He
previously built his own tracker and sunset it because search was rigid, slow, and
unreliable no matter which API backed it, graded comps were bad, and there was no
photo search. Those three failures are the reason this project exists — treat them
as acceptance criteria, not background.

**Single user, personal device, not a product.** No auth, no multi-user, no
onboarding flow, no marketing surface. Build accordingly.

---

## The one-sentence goal

Make intake fast enough that logging 100 singles at 11pm is tolerable, and make the
resulting numbers good enough to answer "how am I actually doing."

If the scan loop is slow, nothing else in this app matters, because he won't use it.

---

## Hard constraints

### Free Apple developer account

This is the constraint that shapes storage. He has a Mac and Xcode but an **unpaid**
developer account.

- **No CloudKit.** iCloud entitlements require a paid account. Do not design for it.
- Sideloading via Xcode, **7-day signing**, needs re-signing weekly
- Max 3 sideloaded apps
- No push notifications, no app groups

**Consequence:** storage is **local-only** on device. Provide a clean JSON export/import
so data is never trapped. Structure the persistence layer so a sync backend could be
added later without reshaping the models — but do not build it, do not stub it, and
do not add CloudKit-compatible compromises (optional-everything, no unique
constraints) that only exist to serve a sync layer that isn't coming.

### Platform

- SwiftUI, iOS 17+ (confirm his actual iOS version before setting the deployment target)
- iPhone is the primary target. A Mac target is optional and low priority; if built,
  gate the scanner behind `#if os(iOS)` since VisionKit's scanner is iOS-only.

### No backend

The daily catalog job runs in **GitHub Actions** and publishes to a **public**
release asset. He has an AWS account but it should not be used — it adds a bill and
an ops surface for capability this app doesn't need. S3 as a mirror for the catalog
artifact is acceptable; nothing may depend on it.

---

## Decisions already made

Do not relitigate these. They came out of a long design conversation and each has a
reason attached.

### Data and money

1. **Two separate stores.** A read-only catalog (~150k rows, downloaded, disposable)
   and a collection store (small, his data, irreplaceable). The collection references
   catalog rows by integer `productId` only — never embeds names or prices.
2. **All money is `Int` cents.** Everywhere, both stores. Rounded once at ingest in
   the Python job, formatted for display through one helper. No `Double` touches a
   monetary value at any point. This is how "always two decimal places" is guaranteed.
3. **TCGCSV is the catalog source.** TCGplayer stopped granting new API access, so
   the official API is not an option. TCGCSV publishes daily dumps in TCGplayer's own
   JSON shape, plus a price archive back to 2024-02-08.

### Search

4. **Search is the entire app.** Buying, ripping, intake, and purchase decisions are
   all thin wrappers around one search component. Build it first and build it properly.
5. **One index over sealed and singles together.** Not separate pickers. Recording a
   buy should be "search legendary warriors, tap it, done" — that single interaction
   is what replaces the quantity/item/product-type menu cascade that made his old app
   painful.
6. **Contextual ranking, not modes.** Same index and same query path everywhere; the
   surrounding context adjusts weights. Buy flow boosts sealed, intake boosts singles.
   The user never picks a mode.
7. **Persistent search field at the top of the app**, with a camera button beside it,
   Collectr-style. Not a search tab. With an empty query the results area shows
   recent buys, unripped sealed, cards at grading, and anything flagged from a scan.

### Scanning

8. **OCR, not image recognition.** Read the card name and collector number with
   Vision. No ML model, no embeddings, no third-party dependency.
9. **The set is inferred, never pre-selected.** The denominator in "114/084" is the
   set's printed total and is a strong discriminator; name + full number string is
   close to a unique key. Union Arena and Digimon encode the set in the number
   directly (BT26-001).
10. **Session bias is learned, not configured.** After several cards in a session
    resolve to one set, bias later ambiguous matches toward it. Self-corrects when he
    moves to the next pack. No setup step.
11. **Printing is derived from rarity rules, not AI.** If the catalog shows one
    printing for a product, don't ask. If several, apply a rarity heuristic and mark
    the result low-confidence. Bulk-fix in review.
12. **Confidence is visible.** Every scanned card gets a small square showing the
    match; certain matches stay quiet, uncertain ones are visibly marked. The review
    screen defaults to filtering to uncertain matches only.
13. **The loop never blocks.** Continuous scanning; correction happens either in-flight
    by tapping a square or in bulk at end of session. Confirming a match returns
    straight to the scanner.
14. **Slabs are read by barcode**, not OCR. PSA and CGC barcode their labels;
    `VNDetectBarcodesRequest` is deterministic and yields the cert number directly.

### Workflow model

15. **Buying and identifying are separate events.** A buy records vendor, date, total,
    a free-text note, and optionally a receipt photo. Nothing else. Identification is
    a later, separate step. This decoupling is the fix for his old app's worst flow.
16. **Rip and singles-intake are the same operation.** Both are "assign identities to
    cards from a buy." Don't build two paths.
17. **Sealed nests.** Opening a Legendary Warriors Premium Collection yields 5 promo
    cards *and* 14 sealed booster packs, each separately rippable. Rip output is
    polymorphic: cards and child sealed items. Cost flows down the tree.
18. **Sealed is sellable without ripping.** Premium collections often hold value
    unopened. A `Sale` must be able to reference either an owned card or a sealed item.
19. **Bulk gets identity but not accounting.** He normally dumps bulk to his LGS for
    about $5, but wants to test listing bulk on TCGplayer. So bulk cards may need
    catalog identity, condition, and quantity — but never individual cost basis.
20. **Cost allocation is equal split, across hits only.** Bulk is excluded from the
    denominator. Store the method per-purchase so `byMarketValue` is available
    without a migration. **But see `04`:** his real data shows this only behaves for
    small buys. A $193 box yielding three recorded hits produces a $72 basis on a
    $1.97 card under any formula. Rip-pull basis is allocated, not real — flag it as
    such and report rip performance at the rip level.
21. **Grading fees split equally across submission entries.** Correct here — the
    grader charged per card.
22. **No trades.** His loop is buy / rip / sell. Do not model trades.
23. **No performance analytics.** He explicitly does not want per-vendor, per-set, or
    per-product performance breakdowns. `vendor` is a plain string for bookkeeping,
    not a dimension. Don't build a reporting layer.

### Things that stay manual

24. **Graded comps are entered by hand.** There is no good automated source. eBay's
    Marketplace Insights API is limited-release and rarely approved, and since
    2026-07-22 eBay redirects signed-out visitors to a login on any sold or completed
    search. He has a Card Ladder subscription and will enter comps himself.
25. **The purchase-decision tool leads with discount to market, not EV.** He rips
    because he enjoys ripping and buys on "good deal" more than expected value. Show
    the numbers; never render a verdict telling him not to rip something.

---

## Catalog scope

Include these TCGplayer categories:

- Pokémon (English)
- Pokémon Japan
- Digimon
- Union Arena

**Check `https://tcgcsv.com/tcgplayer/categories` before building the filter list** —
category IDs must come from the live endpoint, not from this document. He also asked
about Chinese-language cards; TCGplayer likely does not carry them, so confirm from
that endpoint rather than assuming, and report back rather than silently omitting.

Vision text recognition must declare its languages explicitly. Include `en` and `ja`.
Note that Japanese Pokémon cards print collector numbers in Arabic numerals, so
number-based matching works on them without recognizing any kanji.

---

## Phase plan

**Phase 1 — the only phase in scope right now.** Detailed in `03`.

1. Catalog pipeline: GitHub Action, TCGCSV ingest, prepared SQLite, public release
2. On-device catalog download, verification, and swap
3. Search: FTS index, contextual ranking, the persistent field
4. Scan: continuous session, matching, confidence, review, commit
5. Minimal real inventory: `Purchase`, `PurchaseItem`, `OwnedCard`, allocation

He wants Phase 1 to write **real inventory**, not throwaway sessions — cards scanned
in the first build should not need re-entering later.

**Later phases, specified in `02` and `04` but not built yet:** seed import, rips and nested sealed,
grading submissions and returns, sales, bulk disposition, business expenses, returns
and refunds, personal-collection transfers, corrections, listing status, loss and
damage, the purchase-decision calculator, the grade-or-not calculator, TCGplayer and
eBay order import, and period P&L.

Build the Phase 1 models to the shapes in `02` even where Phase 1 doesn't use every
field, so later phases don't require migrations.

---

## Known open work, not part of this build

- **Historical baseline — largely solved.** `seed/binderbooks-export.json` covers
  2026-04-20 to 2026-09-05: 101 buys, 58 rips, 285 inventory rows, 131 sales. His
  first purchase is 2026-04-20, so the books start there with $0 beginning inventory,
  a fact rather than an estimate. Bank-statement triage is now optional gap-filling
  rather than the primary reconstruction. See `04`.
- **43 cards are at a grader**, including an outstanding May 2026 PSA submission
  (Psyduck ×2, Erika's Tangela, Banette, Teal Mask Ogerpon ex, Iron Valiant ex).
  Inventory he doesn't physically hold. `CardStatus.atGrader` covers it; they get
  entered from the submission, never from a scan.
- **Visual direction is undecided.** No palette or type direction has been chosen.
  Default to native iOS idioms and data density over styling; the scan and review
  screens are the only places worth spending design effort in Phase 1.
