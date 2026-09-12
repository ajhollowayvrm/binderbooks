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

**Persistent, at the top of the app, above the content.** Not a search tab. There are
no tabs. The field shows on the root; a pushed screen covers it.

`.searchable()` gets native behavior cheaply but hides on scroll, which is wrong when
search is the primary action rather than a filter over a list. If it should be
genuinely always visible, that's a custom header — decide before building, since it's
unpleasant to retrofit.

A **camera button sits beside the field**, Collectr-style. Not camera-first: he types
"legendary warriors" while standing in a store, and a viewfinder pointed at a box it
can't read is the wrong default.

**Empty state is the inventory page.** With no query, the area under the field shows
his owned cards, with the summary tiles, the filter chips, and a "Recently viewed"
section at the end. Inventory is the landing screen and is never pushed. Flagged
cards are reachable from the "Uncertain" chip, so the home does not repeat them.

**A query fills the same area with one list of two sections.** "In your collection"
first, then "Catalog". One field, no scope control. The collection section matches in
memory over the owned cards, so it answers with no debounce; the catalog section
keeps the 150 ms debounce and lands second.

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
3. **Context boost** — the caller passes a context, and the same index is reranked:
   - `.buying` → boost `isSealed = 1`
   - `.intake` / `.scanning` → boost `isSealed = 0`
   - `.browsing` → neutral
4. **Market value, descending** — the top printing's market price
5. FTS5 `bm25()`, weighting `name` above `setName`
6. Recency — newer `cardSet.publishedOn` breaks ties, since new sets dominate his volume

Context is **never a mode the user picks**. Where he already is supplies it.

Value outranks `bm25` because he reads a result list by price. Nine Charizards
match "charizard", and the $3,000 one must lead. The three keys above value stay
above it, because a query that names one product must return that product first:
type `004/102` and you get that card, not the most expensive card that matched.
A product with no market price sorts last.

Browsing a set with an empty query uses the same order.

### Price

**Market price only.** TCGplayer's low, mid, high, and direct-low columns stay in
the catalog file and never reach the screen. He values a card at market, so a
second number beside it is noise.

A product with several printings shows its **top** printing's market price, and
the printing count under it. The row must show the number the list sorted by.

### Layouts

Two, and the choice persists in `cardLayout`. **Grid is the default.** One key rules
three surfaces: the inventory page, the collection section, and the catalog section.
One toggle sits beside the chips.

- **Grid** — three large arts per row, market price under each, then the set name
  and the number. The default, because the art identifies a card faster than the
  name does.
- **List** — the dense row. Thumbnail, name, set, number, price. An owned row also
  carries the basis and the gain, which a grid cell cannot hold. Read profit in list
  layout, in the summary tiles, or on the card detail.

### Searching his own cards

`OwnedCardMatcher` answers the collection section. The store holds no card name
(`02`), so a name match reads the `SearchHit` that `InventoryModel` caches per
`productId`. One cleaned haystack per card covers the name, the set name, the
number, the set code, the rarity, the printing, the condition code, the scanner's
name and number, the cert number, the grader, and the tags. Two extra rules: a
parsed collector number, and a partial cert number, because he reads the last
digits off a slab label.

**No fuzzy score here.** Typo tolerance belongs to the catalog trigram path. He
knows what is in his own collection, and a fuzzy match would put cards he did not
ask for above the cards he did.

### Performance

Search runs against ~150k local rows. Target **sub-50ms**, debounce input by ~150ms,
run off the main thread, cancel superseded queries. If a query ever takes long enough
to need a spinner, something is wrong — investigate rather than adding the spinner.

---

## Scanning

### Recognition

**Manual mode logs what the last second of frames agreed on.** Added
2026-09-10. A shutter tap does not read one frame; it reads the window.
`ObservationAccumulator` keeps about 1.2 seconds of readings and takes the value
most frames agree on, with the most recent breaking a tie. The collector number
only has to land in one frame, the name and the number need not arrive in the
same frame, and a single stray reading loses the vote.

That replaced a still photo, which read the card better and cost too much. The
history is worth keeping, because both failures it fixed are now regression
tests:

- The live frame read the attack name `Scratch` instead of `Sableye`, which
  matched a Japanese Scramble Switch.
- The live frame read a set total of `195` off a card printed `196`, which
  matched a Mawile V in another set.

The name rule (tallest line, not topmost) and the matcher's name-only bar fixed
the wrong-card half. The accumulator fixes the missed-read half without a still.

**The scanner owns an `AVCaptureSession`.** Changed 2026-09-11. This section
used to say `DataScannerViewController`, and to predict this exact move: "if
manual mode ever needs a still on every tap, run an `AVCaptureSession` … it owns
the session so a photo cannot kill it." What forced it was not the still. It was
artwork.

`DataScannerViewController` hands back recognised text and a `capturePhoto()`
that tears down the preview, and **no frames at all**. Artwork matching needs a
picture of every card, not of the rare one whose text failed, so there was no
version of it that worked on VisionKit. What owning the session bought:

- **One Vision pass over one buffer.** Text and pixels used to come from two
  different captures at two different moments and exposures. A signature from
  one and a number from the other describe different looks at the card.
- **The sharpest frame of the last second**, rather than whichever arrived.
  Blur is the only degradation that measurably costs artwork accuracy — 95% to
  82% — so `FrameSharpness` scores every frame and the accumulator keeps the
  signature from the best one. Frames taken while the lens is moving are never
  signed.
- **The lens held where a card is.** `.near` focus range, because a card sits at
  about a hand's width and an unrestricted lens racks past it to the desk.
  Exposure biased −0.3, because foil blows out and the pattern is the signal.
- **A card outline in the viewfinder**, which VisionKit could not draw.

Work is rationed by `FramePolicy` — text at 4/s, card detection at 10/s, and a
feature print only on a sharp frame that improves on what is already signed —
because thirty frames a second of everything heats the phone and reads nothing
better.

Recognition languages are still declared explicitly: **`en` and `ja`**.

Three things are read now, not two:

- **Card name**
- **Collector number** — `114/084`, `BT26-001`, `031/071`
- **The artwork**, as a signature — see below

**Artwork recognition is in, and the old "no ML, no embeddings" rule is gone.**
It was the right rule while it stood: it kept a card tracker from becoming a
machine-learning project. It broke on three things text cannot do — two cards
sharing a number, a Japanese card whose name the catalog files in English, and
the foil printings that share a name *and* a number and differ only in the
pattern stamped across them. All three are visible and none is readable.

There is still no third-party dependency and no model to train. `CardArtDescriptor`
is Apple's `VNGenerateImageFeaturePrint`, projected to 128 dimensions and one byte
each — 9.3 MB across the catalog instead of 58 MB, with the ordering preserved.
The catalog carries a signature per product; the phone signs the card in front of
it and compares.

Two rules that keep this honest:

- **The app and the catalog build tool compile the same source file.** Two
  implementations of one arithmetic would drift, and the day they drifted every
  distance would quietly become noise rather than an error.
- **The catalog records the version it was signed with.** A signature the phone
  cannot reproduce is ignored, not compared. A silent wrong answer is worse than
  no answer.

Measured on an index of 8,251 real cards, references degraded with perspective, a
colour shift and a specular glare: **95% exact card at rank 1, 99.5% in the top
3**. Perspective alone costs nothing, which is `CardRectifier` earning its place —
it finds the card in the frame and flattens it before anything looks at pixels.
Accuracy held as the index grew 33-fold.

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

5. Score the artwork against each candidate's signature (below).

6. Resolve:
     one candidate            -> .certain
     one clear winner         -> .likely
     several                  -> .uncertain, attach candidates for the chip
```

**Artwork is a signal beside the number and the name, not above them.** It is
weighted at about what a name is worth, so no single signal can overrule the
other two on its own. A candidate with no reference image scores nothing here
and is neither helped nor punished — roughly one product in forty has no image
on TCGplayer, and "we cannot see it" is not "it is wrong".

Two bars, not one, because they answer different questions:

- **`sameCard`, 0.78** — is this that card? The nearest unrelated card sits at
  0.84 and the printings of one card sit at 0.53 to 0.73, so this separates
  cards cleanly.
- **`artSamePrinting`, 0.40** — is this *that printing* of that card? Tighter on
  purpose. The printings sit only about 0.5 apart, so a distance that comfortably
  says "this is a Snivy" says nothing about which of the three Snivys it is.
  Confusing these two bars is how a Master Ball card gets confidently logged as
  the plain one.

**Artwork can rescue a card whose text is a mess.** When the camera agrees with
exactly one candidate and no other, a misread name and an ambiguous number stop
deciding anything. This is the Japanese card, and the card read through glare.

**A name on its own must be a strong match.** When no number is read at all,
the name is the entire decision, and a loose match becomes a wrong card. Dice
similarity must clear **0.75**, not the 0.5 used when a number agrees. Below
that, assign nothing and show the candidates.

This came off a real failure on 2026-09-10. A Sableye was held with a finger
over `070/196`, so no number was read; the name picker fell through to the
attack name `Scratch`; and `scratch` against `scramble switch` scores 0.53. The
card was logged twice as a Japanese trainer from Start Deck 100.

**The catalog says which line is the name.** Added 2026-09-10, on AJ's
suggestion: the catalog holds every card name there is, so membership settles
what no rule about position or size can. The interpreter stops choosing. It
offers up to four lines — a line carrying the HP first, then the tallest, then
the highest — and the matcher takes the first that `product.cleanName` actually
holds. `Sableye` is a card and `Scratch` is not, so the attack loses however
large it is printed and wherever it sits.

`isACardName` is one indexed lookup per line against `idx_product_clean`. When
no line names a real card, the matcher falls back to the closest fuzzy match,
because OCR misreads a name about as often as it reads the wrong line.

This replaced `isPlausibleName` as the thing that matters. That blocklist is
still there to drop obvious furniture — `BASIC`, `Stage 1`, the copyright line
— but it never had to be complete, and now it does not have to be right either.

**The name can veto the number.** Many sets share a printed total, so a misread
denominator lands on a real card with the wrong name. Three rules:

1. When the number's candidates all disagree with the name, run the name search
   too and merge both sets. A card both signals pick gets a bonus.
2. When a near-exact name contradicts the number, the name wins and the result
   is `.uncertain`. Two disagreeing signals must ask, not assert.
3. When several cards share the total and none matches the name, assign no
   product at all. A wrong card that looks confident is worse than an unknown.

A name the catalog does not hold cannot overrule the number: glare and attack
text produce readings like that, and the number is still right.

The matcher's name search ranks by **relevance, not market value**. The result
list ranks by value for a person reading it, and the candidate cap would drop
the true card in favour of dearer look-alikes. `SearchRequest.ranking` carries
the difference.

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

**Japanese script is itself a signal.** Added 2026-09-11. The catalog files a
Japanese card under its *English* name, so the name printed on the card can never
agree with it — and scoring it as a weak name dragged every Japanese card down to
"nothing agrees" and assigned no product at all. Two rules fix it:

1. A name line in kana or kanji is dropped before scoring. It is not a weak
   signal, it is no signal, and the number is left to decide.
2. Seeing Japanese script anywhere in the frame keeps the match inside the
   Japanese catalogue. `034/190` is one card there and a different card in the
   English one.

The second rule runs **one way only**. Glare can hide every kana on a card, so
the absence of Japanese script is not evidence that a card is English, and a
frame with none must not rule the Japanese catalogue out.

### Printing

**The pattern printings are their own problem.** Black Bolt prints Snivy three
times at `001/086`: plain, Poké Ball Pattern, Master Ball Pattern. Same name,
same number, same art — the difference is foil stamped across the whole card.
No reading of the text can see it, and the plain card wins the name every time,
so a pattern card was logged as the plain one and looked `.certain` doing it.

The card also prints only `Snivy`, never `Snivy (Poke Ball Pattern)`. Scoring
against the catalog's full name penalised every variant for a qualifier printed
nowhere on it, so the matcher scores against both and takes the better.

Where the catalog has a reference image for each printing, artwork settles it
outright — the pattern is plainly visible even in a 200px thumbnail. Where it
does not, the scanner **asks**, and the correction screen shows the printings as
art with prices, because three rows reading "Snivy" is not a question anyone can
answer.

It has to ask often: TCGplayer serves no image for **124 of 144** Master Ball and
**102 of 160** Poké Ball products. This is the one place where more artwork in
the catalog would buy more accuracy, and the missing images are not ours to fix.

### Printing count, without AI

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
  per-set, and per-product performance breakdowns. **Amended 2026-09-11:** the
  ledger's `Summary` tab holds whole-business totals and the periodic P&L. See
  decision 23 in `00-brief.md`. Still no charts, and still nothing sliced by
  vendor, set, product, or channel.
- Do not add CloudKit, accounts, or sync. Free developer account; it isn't available.
- Do not add AWS or any server. A script on AJ's Mac and a public release asset cover it.
- Do not bundle a catalog in the binary.
- Do not use `Double` for money, anywhere, at any point.
- Do not make him choose a set before scanning.
- Do not build a separate sealed picker.
- Ask before adding a dependency. The whole design is deliberately dependency-light —
  GRDB is the only one currently justified.
