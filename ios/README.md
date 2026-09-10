# BinderBooks on iPhone

SwiftUI, iOS 26. The Xcode project is generated from `project.yml` and never
committed. The bundle id is `com.ajholloway.binderbooks`, the same as the old web-shell app,
so the install replaces it in place.

```sh
brew install xcodegen
cd ios
xcodegen generate
xcodebuild -project BinderBooks.xcodeproj -scheme BinderBooks \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath build test
```

Or open `BinderBooks.xcodeproj` in Xcode and press Cmd-U.

## Deployment target

iOS 26.0. Every simulator on the Mac and the phone run iOS 26. The data model in
`docs/02-data-model.md` uses the `#Unique` macro, which needs iOS 18 or later.

## Layout

| Path | Contents |
|---|---|
| `Sources/BinderBooksApp.swift` | The entry point. Starts the catalog controller. |
| `Sources/Catalog/` | Step 2: manifest, download, checksum, gunzip, sanity checks, atomic swap. |
| `Sources/Model/` | The collection store: `Purchase`, `PurchaseItem`, `OwnedCard`, `ScanSession` in SwiftData, and the allocator. |
| `Sources/Scan/` | Step 4: the VisionKit scanner, the frame interpreter, the matcher, the printing rules, and the session model. |
| `Sources/Inventory/` | Step 5: the inventory model, filters, and summary. |
| `Sources/Search/` | Step 3: the query builder, the ranker, the engine, the debounced model, and recently viewed. |
| `Sources/UI/` | The shell, the content switch, the two-section result list, the large-art grids, the filter chips, the tag sheets, the set picker sheet, the product detail, the first-run download screen, and the catalog status screen. |
| `Tests/` | Swift Testing suites. No network. |

## The catalog on the device

- The file lives in Application Support/Catalog, excluded from backup.
- On every launch the app fetches the manifest from the `catalog-latest` release,
  compares the checksum with the installed one, and downloads only on change.
- The download is verified in this order: SHA-256 of the gzip, decompress, open with
  GRDB, `meta.schemaVersion` equals 1, `meta.productCount` equals the manifest, and
  the count is at least half of the installed count.
- The swap closes the live handle, replaces the file atomically, and reopens it.
- A scan session calls `beginExclusiveUse()`. A catalog verified during a session is
  staged as `pending.sqlite` and swaps in when the session ends.
- A manifest with a schema version above what the app reads is refused. The
  installed catalog stays.

## Search

One field answers with two sections: "In your collection" first, then "Catalog".
The collection pass is a string scan over his own cards in memory
(`OwnedCardMatcher`), so it answers on every keystroke with no debounce. The catalog
keeps the 150 ms debounce, so it lands second.

One engine, `CatalogSearch`, answers every catalog query. The caller passes a
`SearchContext`; the user never picks a mode.

- Path A runs first: every token becomes a quoted prefix phrase on `product_fts`,
  ranked by `bm25` with `name` weighted above `setName`.
- Path B runs when path A returns fewer than 5 hits and the text has 3 or more
  characters: the query's trigrams, joined with `OR`, on `product_trigram`.
- A direct number lookup runs when the text parses as a collector number. It uses
  the same rules as the Python job, in `CollectorNumber`.
- `SearchRanker` orders the merged candidates: exact number, exact clean name,
  bm25, context boost, then set recency.
- `SearchModel` debounces typing by 150 ms, cancels superseded queries, and runs
  SQLite through GRDB's async read, off the main thread. Debug builds show the
  query time under the results.

Filters are chips, not pickers: kind (all, singles, sealed), category toggles, and
one set chosen from a searchable sheet. An empty query with a set chosen browses
that set in number order. An empty query with no filter shows recently viewed
products.

## Scan session

`ScanSessionView` runs VisionKit's `DataScannerViewController` with live text in
`en` and `ja` plus barcodes. Every frame's items go through `FrameInterpreter`: the
collector number by shape, the name as the tallest string near the top. A card is
accepted once per visit to the frame, after the same number reads twice. The
number item must leave the frame before the card can log again. "Same card again"
covers real duplicates. Slab barcodes yield the cert number and land unidentified.

`CardMatcher` follows docs/03: candidates by set code or set total plus number,
narrowed by the OCR name with a bigram Dice score, biased toward sets seen earlier
in the session, then resolved to certain, likely, or uncertain. `PrintingRules`
assigns the printing when the product has one, and otherwise applies a rarity
table and marks the card uncertain unless the session has a printing default.

Every match persists as an `OwnedCard` on the `ScanSession` the moment it lands.
Review defaults to the cards that need a look, supports multi-select edits of
condition, printing, set, and bulk, and commits the session to a purchase. Commit
creates one `PurchaseItem` per card, runs the equal-split allocator across the
non-bulk lines, and writes each card's basis with `basisIsAllocated` set. A card is
inventory once its session commits.

The simulator has no camera. Debug builds show a text field in the viewfinder that
feeds the same path. See the debug launch variables below.

Known behavior worth knowing: a card that TCGplayer lists several times with the
same name and number, such as a main-set print, a Prize Pack reprint, and a stamped
copy in Miscellaneous, lands uncertain on the first sighting. TCGCSV's supplemental
flag does not separate those groups. The session bias resolves later cards in the
same run.

## Inventory

**The inventory page is the app's landing screen.** The persistent search field sits
above it, and `ShellContentView` swaps the page for the result list as soon as he
types. Nothing pushes the inventory any more.

`InventoryView` lists committed cards newest first with market value from the
catalog, the basis, and the difference. Filters are two chips: tags and set. Tags
replaced the status chips, and he narrows by label more than by anything else.
The confidence, slab, bulk, and personal filters stay in `InventoryFilter` but
have no chip; the row markers still show confidence and bulk.

The money sits behind the **Metrics** button, not above the cards. The sheet
reports what the current chips and query left on the page, so its figures always
match the cards behind it. Graded cards render as a small slab with the grader and
cert number on the label. The detail screen shows the basis breakdown, the source
purchase, and the edits that need no other model.

Layout is one global preference in `cardLayout`, and grid is the default. One toggle
beside the chips rules the inventory page, the collection section, and the catalog
section. A grid cell cannot hold the basis or the gain; read those in list layout,
in the summary tiles, or on the card detail.

**Tags** are free-form labels: "binder 3", "for sale", "PSA queue". `TagKey` folds
case and inner space but never punctuation, because a label is his own text. **A long press on a card starts selection**, with that card ticked; the Tag menu in
the bottom bar then holds the five labels he uses most, plus "Tag…" for the full
sheet. Metrics sits on the left of the navigation bar and Select on the right. A tag also
matches in the search field. The reserved labels `sold`, `listed`, `at grader`,
`graded`, and `lost` replaced `CardStatus`; `StatusTagBackfill` copies each card's
old status into its label once, and `OwnedCard.statusRaw` stays in the store and in
the export for one release, because a dropped field cannot be read back.

Every card with a cost and a market price shows the difference, including a cost
split out of a purchase. The Metrics sheet reports how many of those costs were
derived rather than paid for one card. See the 2026-09-10 amendment in docs/04.

## Pricing at review

He sets a **total** for a selection, and the Cost button splits it evenly over
those cards. `OwnedCard.basisIsManual` then marks the basis as his:

- The purchase total at commit covers everything. What he priced comes out
  first, and the remainder splits over the cards he did not price. Typing more
  than the total leaves the split at zero and rewrites nothing.
- A split over several cards stays `basisIsAllocated`, which reports that the
  cost was derived. It no longer hides the gain: every card with a cost and a
  market price shows the difference, because that is the figure he compares a
  sale against.

## Export and import

Settings prepares the export when the screen opens, so exporting is one tap into
the share sheet. The file holds every purchase, line, card, and session, with
relationships as UUIDs and dates as seconds since the reference date, sorted by id.
Two exports of the same store are byte-identical, and importing an export then
exporting again reproduces the file exactly. Import offers merge, which upserts by
id, and replace, which empties the store first and asks twice. The catalog is not in
the file.

## Debug launch variables

The simulator cannot type or tap for a script, so debug builds read these on launch:

| Variable | Effect |
|---|---|
| `CT_SEARCH_QUERY` | Pre-fills the search field. |
| `CT_OPEN_SCANNER=1` | Opens the scan session once the catalog is ready. |
| `CT_SIMULATE_SCANS` | Feeds `Name number` entries separated by `;` through the matcher. |
| `CT_OPEN_REVIEW=1` | Opens review after the simulated scans settle. |
| `CT_AUTO_COMMIT="Vendor\|cents"` | Commits the session to a new purchase and closes the scanner. |
| `CT_SET_COST=3000` | Prices the simulated session at that many cents, split evenly. |
| `CT_SEARCH_LAYOUT` | `list` or `grid`. Grid is the default, so this mostly forces `list`. |
| `CT_OPEN_CARD=1` | Pushes the newest card's detail. |
| `CT_OPEN_SETTINGS=1` | Pushes Settings, which holds export. |
| `CT_OPEN_METRICS=1` | Opens the inventory Metrics sheet. |
| `CT_SELECT_ALL=1` | Enters selection with every row ticked. |
| `CT_OPEN_INVENTORY=1` | Deprecated. Inventory is the landing screen, so this only clears the query and pops to the root. |

Prefix each with `SIMCTL_CHILD_` on `xcrun simctl launch`.

## Dependencies

GRDB only. Gunzip uses the system zlib. Checksums use CryptoKit.

## Sideloading

```sh
python3 scripts/ios-device.py            # build Release, sign, install, launch
python3 scripts/ios-device.py --dry-run  # show the plan, change nothing
```

A free developer account signs for 7 days and allows three sideloaded apps per
device. The script handles the four things that makes awkward, and its header
documents each: the team id comes from the certificate's OU field; a cached profile
with fewer than 6 days left is moved aside so Apple issues a fresh one; the
three-app limit is explained when an install fails; and the script checks that
Xcode holds a usable Apple ID credential before it builds.

Xcode can look signed in while it is not. When the script stops with "Xcode has no
signed-in Apple ID", open Xcode > Settings > Accounts, remove the stale entry, and
sign in again. xcodebuild cannot answer the two-factor prompt, so this step is
manual. The signing certificate is not the problem and lasts a year.
