# Card Tracker on iPhone

SwiftUI, iOS 26. The Xcode project is generated from `project.yml` and never
committed.

```sh
brew install xcodegen
cd ios
xcodegen generate
xcodebuild -project CardTracker.xcodeproj -scheme CardTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath build test
```

Or open `CardTracker.xcodeproj` in Xcode and press Cmd-U.

## Deployment target

iOS 26.0. Every simulator on the Mac and the phone run iOS 26. The data model in
`docs/02-data-model.md` uses the `#Unique` macro, which needs iOS 18 or later.

## Layout

| Path | Contents |
|---|---|
| `Sources/CardTrackerApp.swift` | The entry point. Starts the catalog controller. |
| `Sources/Catalog/` | Step 2: manifest, download, checksum, gunzip, sanity checks, atomic swap. |
| `Sources/Search/` | Step 3: the query builder, the ranker, the engine, the debounced model, and recently viewed. |
| `Sources/UI/` | The shell, the results list, the filter chips, the set picker sheet, the product detail, the first-run download screen, and the catalog status screen. |
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

One engine, `CatalogSearch`, answers every query. The caller passes a
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

For a screenshot or a timing run, pre-fill the field:

```sh
SIMCTL_CHILD_CT_SEARCH_QUERY="legendary warriors" xcrun simctl launch booted com.ajholloway.cardtracker
```

## Dependencies

GRDB only. Gunzip uses the system zlib. Checksums use CryptoKit.

## Sideloading

A free developer account signs for 7 days and allows 3 sideloaded apps. The old
BinderBooks install script handled the profile refresh and the team ID lookup. It
lives in git history at `scripts/ios-device.mjs` (commit `04dff1b`). Port it when
the first device install happens.
