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
| `Sources/UI/` | The shell: the persistent search field with the camera button, the first-run download screen, and the catalog status screen. |
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

## Dependencies

GRDB only. Gunzip uses the system zlib. Checksums use CryptoKit.

## Sideloading

A free developer account signs for 7 days and allows 3 sideloaded apps. The old
BinderBooks install script handled the profile refresh and the team ID lookup. It
lives in git history at `scripts/ios-device.mjs` (commit `04dff1b`). Port it when
the first device install happens.
