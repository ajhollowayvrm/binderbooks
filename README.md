# Card Tracker

A single-user iOS app for a card reselling operation. It replaces BinderBooks, the
web app that lived in this repository before the `Reset` commit.

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

Phase 1, steps 1 and 2 are done: the catalog pipeline, and the on-device download,
verification, and swap. The next step is search. See `docs/03-phase1-search-and-scan.md`.
