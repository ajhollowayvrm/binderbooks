# 03 — Phase 1: Search and Scan

This is the build. Everything else in `02` waits.

**Acceptance test:** he can sit down with 40 freshly pulled hits and have them all in
inventory, correctly identified, in a few minutes, without the app fighting him. His
last app died because search was rigid and slow. If this build has that problem, it
has failed regardless of what else works.

---

## Scope

1. Catalog download, verification, atomic swap (`01`)
2. Search: FTS index, ranking, the persistent field
3. Scan: continuous session, matching, confidence, review, commit
4. Minimal inventory: `Purchase`, `PurchaseItem`, `OwnedCard`, `ScanSession`, allocation
5. JSON export/import

Out of scope: rips, grading, sales, calculators, P&L, imports, everything in `02`'s
later sections.

---

## Search

### The field

**Persistent, at the top of the app, above the tab content.** Not a search tab.

`.searchable()` gets native behavior cheaply but hides on scroll, which is wrong when
search is the primary action rather than a filter over a list. If it should be
genuinely always visible, that's a custom header — decide before building, since it's
unpleasant to retrofit.

A **camera button sits beside the field**, Collectr-style. Not camera-first: he types
"legendary warriors" while standing in a store, and a viewfinder pointed at a box it
can't read is the wrong default.

**Empty state is the home screen.** With no query, the results area shows recent
purchases, unripped sealed sitting in inventory, and cards flagged uncertain from
recent scans. All the things that would otherwise justify a dashboard, in the space
the results will occupy anyway.

### The query

One index over **sealed and singles together**. Never separate pickers.

Two paths:

1. **`product_fts`** — token and prefix. Run first.
2. **`product_trigram`** — typo tolerance. Run when path A returns fewer than ~5 hits.
   Guard queries under 3 characters, since the trigram tokenizer needs three.

Merge, dedupe by `productId`, rank.

### Ranking

In priority order:

1. Exact `number` match, when the query parses as one
2. Exact `cleanName` match
3. FTS5 `bm25()`, weighting `name` above `setName`
4. **Context boost** — the caller passes a context, and the same index is reranked:
   - `.buying` → boost `isSealed = 1`
   - `.intake` / `.scanning` → boost `isSealed = 0`
   - `.browsing` → neutral
5. Recency — newer `cardSet.publishedOn` breaks ties, since new sets dominate his volume

Context is **never a mode the user picks**. Where he already is supplies it.

### Performance

Search runs against ~150k local rows. Target **sub-50ms**, debounce input by ~150ms,
run off the main thread, cancel superseded queries. If a query ever takes long enough
to need a spinner, something is wrong — investigate rather than adding the spinner.

---

## Scanning

### Recognition

`DataScannerViewController` (VisionKit) for live text. Declare recognition languages
explicitly: **`en` and `ja`**.

Two strings matter:

- **Card name**
- **Collector number** — `114/084`, `BT26-001`, `031/071`

Do not attempt artwork recognition, embeddings, or any ML model. No third-party
dependency.

**Japanese cards print collector numbers in Arabic numerals**, so number-based
matching works on them without recognizing a single kanji. Name OCR in Japanese is a
bonus, not a requirement.

### Matching

The **denominator carries the set**. In `114/084`, `084` is the set's printed total,
and very few sets share a total. So `name + numberNum + setTotal` is close to a unique
key across the whole catalog — no set symbol, no set selection.

```
1. Parse the number.
     x/y      -> numberNum = x, setTotal = y
     ABC-nnn  -> setCode = ABC, numberNum = nnn   (Union Arena, Digimon — easier)

2. Candidates:
     setCode present  -> WHERE setCode = ? AND numberNum = ?
     setTotal present -> WHERE setTotal = ? AND numberNum = ?
     neither          -> fall back to name search only

3. Narrow by OCR'd name against cleanName (fuzzy — OCR misreads).

4. Apply session bias (below).

5. Resolve:
     one candidate            -> .certain
     one clear winner         -> .likely
     several                  -> .uncertain, attach candidates for the chip
```

Note that secret rares exceed the printed total — `114/084` is valid and common. The
denominator still identifies the set; don't reject numbers where `x > y`.

**Session bias, learned not configured.** `ScanSession.observedGroupIds` tracks which
sets have resolved. Once several cards land in one set, boost that set for later
ambiguous matches. It self-corrects when he moves to the next pack, because new cards
pull the bias with them. He should never see a "choose your sets" step.

Vintage and Japanese are the weak spots — older sets reuse totals, and Japanese
numbering can collide with English. Those land in `.uncertain` and get the
disambiguation chip, which is the right outcome since they're the cards most worth
eyeballing.

### Printing, without AI

`product.printingCount` comes from the catalog build, so:

- **One printing** → assign it. Don't ask.
- **Several** → apply a rarity heuristic, mark `.uncertain`, fix in bulk at review.

Rough heuristic for modern Pokémon: commons and uncommons exist as Normal + Reverse
Holofoil; rares are Holofoil; ex / SIR / UR / IR are typically single-printing. Put
this in one table that's easy to tune rather than scattering conditionals.

For his actual hits this mostly evaporates — high-rarity cards are usually
single-printing. It's a bulk problem, and bulk takes the session default.

### Slabs

Graded cards go through `VNDetectBarcodesRequest`, not text OCR. PSA and CGC barcode
their labels; reading the barcode is deterministic and yields the cert number
directly. Worth checking whether PSA's cert lookup returns label data from a cert
number — if it does, one scan populates the whole record.

---

## The scan session UI

### Layout

Viewfinder, with a running list beside or below it, newest first, and a live session
total.

Each recognized card produces a **small square** showing what the app thinks it is.
Tapping a square opens a correction sheet **without stopping the scanner**.

### Confidence must be visible

If every square looks identical, a shaky guess is indistinguishable from a certain
one, and he either reviews all 300 or trusts matches he shouldn't.

- `.certain` — quiet, no marker
- `.likely` — subtle marker
- `.uncertain` — clearly marked, with the candidate chip

Review then defaults to filtering to uncertain matches. Six cards to check instead of
three hundred, with the full list still reachable.

### Never block

Continuous scanning at whatever speed his hands go. Confirming a correction returns
straight to the scanner. He may well never use in-flight correction at all and do
everything at review — that's fine, and the square is then a confidence readout.

### Duplicate suppression

Same card in frame for two seconds must not log four copies. But he genuinely owns
four copies of some cards.

**Require the card to leave the frame before accepting a new match.** More reliable
than a time-based cooldown. Provide an explicit "same card again" affordance for
deliberate duplicates.

### Session defaults

Condition is set **once per session**, not per card. Optional printing default too,
for bulk runs.

### Persistence

**Write every match to disk as it lands.** Not on commit, not on background. Three
hundred cards deep is the wrong time to discover the session was in memory.

---

## Review

Opens at end of session, defaulting to uncertain matches, with a toggle for all.

This is a **different editor** from the in-scan square. That one fixes one card; this
one fixes patterns. Multi-select, then:

- Set condition across a selection
- Set printing across a selection
- Reassign a run to a different set (scanner locked onto the wrong printing or set)
- Mark a selection as bulk
- Delete a stretch of accidental duplicates

### Commit

On commit:

1. Attach the session to a `Purchase` — pick an existing one or create it inline
   (vendor, date, total, note; that's the whole form)
2. Create `OwnedCard` rows, carrying `matchConfidence` through so shaky matches stay
   visible later
3. Run allocation across non-bulk cards
4. Mark the session committed

A session must be resumable if he backgrounds the app or the phone dies.

---

## Inventory view

Minimal in Phase 1, but real.

- List of owned cards, current market value from the catalog, total basis, unrealized
  difference
- Filter by set, status, confidence
- **Graded cards render as a small slab representation showing the cert number**
- Tap through to a detail view: catalog data, basis breakdown (acquisition vs
  grading), source purchase

---

## Export

JSON export and import of the entire collection store, one tap from settings.

There is no sync and no cloud backup. Export is the only thing standing between him
and total loss, so it must be obvious, fast, and complete. Import must round-trip its
own output exactly.

The catalog is excluded — it's re-downloadable and would bloat the file pointlessly.

---

## Build order within Phase 1

1. **Catalog pipeline and download.** Nothing works without it.
2. **Search, and prove it's fast.** Test against the real ~150k-row catalog, not a
   fixture. This is the thing that killed the last app.
3. **Models and allocation.** Pure logic, unit-testable with no UI. Test
   `splitEqually` for exact sums across awkward counts.
4. **Scan session.** The hard part. Matching first with a debug list, then the UI.
5. **Review and commit.**
6. **Inventory view and export.**

Steps 1 and 2 are independently useful — he can look up prices with them before any
of the rest exists.

---

## Notes for whoever builds this

- Do not add analytics, charts, or reporting. He explicitly rejected per-vendor,
  per-set, and per-product performance breakdowns.
- Do not add CloudKit, accounts, or sync. Free developer account; it isn't available.
- Do not add AWS or any server. GitHub Actions and a public release asset cover it.
- Do not bundle a catalog in the binary.
- Do not use `Double` for money, anywhere, at any point.
- Do not make him choose a set before scanning.
- Do not build a separate sealed picker.
- Ask before adding a dependency. The whole design is deliberately dependency-light —
  GRDB is the only one currently justified.
