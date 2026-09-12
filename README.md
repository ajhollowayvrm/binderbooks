# BinderBooks

A single-user iOS app for a card reselling operation. It replaces the BinderBooks
web app that lived in this repository before the `Reset` commit, and keeps the name.

Read `docs/00-brief.md` first. The other documents in `docs/` are the catalog
pipeline, the data model, the Phase 1 build spec, and the seed import plan.

## Layout

| Path | Contents |
|---|---|
| `docs/` | The build brief and the design documents. |
| `catalog/` | The catalog build. Python, standard library only, plus the Swift tool that signs the artwork. See `catalog/README.md`. |
| `seed/` | The BinderBooks ledger for 2026-04-20 to 2026-09-05, the collection file converted from it, and the report of what did not convert. |
| `scripts/` | `import_binderbooks.py` converts the ledger into a file the app imports. `ios-device.py` builds, signs and installs on the phone. `publish-catalog.sh` builds the catalog on the Mac, signs its artwork, and publishes it to the `catalog-latest` release. Run it by hand. |
| `ios/` | The SwiftUI app. The Xcode project is generated from `ios/project.yml`. See `ios/README.md`. |

## Status

Phase 1 is built: the catalog pipeline, the on-device download and swap, search,
the scan session with review and commit, the inventory view, and JSON export and
import. The live scanner has not run on a phone yet. See `ios/README.md`.

The BinderBooks ledger is imported: 93 purchases, 8 grading submissions, 58 sealed
lines, 279 of 285 cards, and 131 sales. See `docs/04-seed-import.md`.

The **ledger screen** shows money in and money out in one list, by month, with a
detail for each order, purchase and grading charge, and a plus button that
records a purchase, an order, or a grading charge by hand. Ripping starts from a
purchase and writes no rip record — see the amendment in `docs/02-data-model.md`.
`GradingSubmission`, `GradingEntry`, `Sale` and `SaleLine` exist as models and
travel in the export, but the grading and selling flows are not built.
