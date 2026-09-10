# BinderBooks

A single-user iOS app for a card reselling operation. It replaces the BinderBooks
web app that lived in this repository before the `Reset` commit, and keeps the name.

Read `docs/00-brief.md` first. The other documents in `docs/` are the catalog
pipeline, the data model, the Phase 1 build spec, and the seed import plan.

## Layout

| Path | Contents |
|---|---|
| `docs/` | The build brief and the design documents. |
| `catalog/` | The daily catalog build. Python, standard library only. See `catalog/README.md`. |
| `seed/binderbooks-export.json` | The BinderBooks ledger, 2026-04-20 to 2026-09-05. Imported in a later phase. |
| `.github/workflows/build-catalog.yml` | Builds the catalog every day at 21:30 UTC and publishes it to the `catalog-latest` release. |
| `ios/` | The SwiftUI app. The Xcode project is generated from `ios/project.yml`. See `ios/README.md`. |

## Status

Phase 1 is built: the catalog pipeline, the on-device download and swap, search,
the scan session with review and commit, the inventory view, and JSON export and
import. The live scanner has not run on a phone yet. See `ios/README.md`.
