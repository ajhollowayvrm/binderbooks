# 01 — Catalog Pipeline

Builds the read-only catalog the app searches. Runs by hand on AJ's Mac, publishes
a prepared SQLite file to a public release. No server, no AWS, no cost.

---

## Source

**TCGCSV** (`https://tcgcsv.com`) mirrors TCGplayer's catalog and pricing daily,
returning the same JSON shape as TCGplayer's own API. Content updates around
**20:00 UTC**. TCGplayer is not granting new API keys, so this is the practical
source rather than a fallback.

Four tiers:

```
categories  ->  groups (sets)  ->  products  ->  prices
```

Endpoints:

```
https://tcgcsv.com/tcgplayer/categories
https://tcgcsv.com/tcgplayer/{categoryId}/groups
https://tcgcsv.com/tcgplayer/{categoryId}/{groupId}/products
https://tcgcsv.com/tcgplayer/{categoryId}/{groupId}/prices
```

Responses wrap results as `{ totalItems, success, errors, results }`. The market price
collection omits `totalItems`. A group with no products returns 404 with a JSON error
body — normalize that case rather than treating it as a failure.

Price history, if ever needed:
`https://tcgcsv.com/archive/tcgplayer/prices-YYYY-MM-DD.ppmd.7z`, available from
2024-02-08 onward. Not part of Phase 1.

### Category selection

**Fetch `/tcgplayer/categories` and resolve IDs at runtime.** Do not hardcode IDs
from any document, including this one. Match on category `name`, and fail loudly if a
configured name doesn't resolve — a silently missing category looks identical to an
empty search result.

Configured categories: Pokémon (English), Pokémon Japan, Digimon, Union Arena.

Also: scan the full category list for any Chinese-language card category and report
what you find in the job log. If one exists, add it. If not, note it — the assumption
is that TCGplayer doesn't carry Chinese, but that should be verified from the
endpoint rather than believed.

---

## Ingest rules

### Money

Every price becomes an integer number of cents, rounded exactly once, here.

```python
from decimal import Decimal, ROUND_HALF_UP

def to_cents(value):
    if value is None:
        return None
    # Decimal(str(x)) reads the literal as written, avoiding float artifacts
    # such as 0.35000000000000003 or 12.339999999999999
    return int(Decimal(str(value)).quantize(Decimal("0.01"), ROUND_HALF_UP) * 100)
```

After ingest, no float exists anywhere in the catalog. This is the mechanism that
makes "two decimal places" true by construction rather than by formatting discipline.

### Product fields

TCGplayer nests card attributes under `extendedData`, an array of
`{name, displayName, value}` objects. Flatten the ones that matter into real columns:

| extendedData name | column | notes |
|---|---|---|
| `Number` | `number` | raw string, e.g. `114/084`, `BT26-001` |
| `Rarity` | `rarity` | drives the printing heuristic |
| `CardType` | `cardType` | |

Derive additionally:

- **`cleanName`** — lowercase, strip punctuation, collapse whitespace, normalize
  Unicode (NFKD), remove diacritics. The matching key.
- **`numberNum`** — leading integer parsed out of `number` (`114` from `114/084`,
  `1` from `BT26-001`). Null if unparseable.
- **`setTotal`** — the denominator when the number is `x/y` form (`84` from `114/084`).
  **This is the single most important derived field.** It is what lets the scanner
  identify a set without reading a set symbol. Null when the format doesn't carry one.
- **`setCode`** — the alphabetic prefix when present (`BT26` from `BT26-001`). Union
  Arena and Digimon encode their set here, which makes them easier to match than
  Pokémon.
- **`isSealed`** — true for booster boxes, packs, ETBs, premium collections, tins,
  bundles. TCGplayer separates sealed from singles by subtype/category labels
  (`sealedLabel` / `nonSealedLabel` on the category object); use those rather than
  guessing from the product name.

Note that **oversize/jumbo promo cards are distinct products** in the catalog. The
Legendary Warriors Premium Collection includes an oversize foil Zacian V, and that is
its own entry, not a variant of the standard card.

### Prices

Prices are per `(productId, subTypeName)`, where `subTypeName` is the printing —
`Normal`, `Holofoil`, `Reverse Holofoil`, and so on. A product commonly has several
rows. The app needs to know **how many printings a product has**, because that
determines whether the scanner asks about printing at all. Store a
`printingCount` on the product during the build so the app never has to aggregate at
query time.

---

## Output: `catalog.sqlite`

Built fresh each run. Schema:

```sql
PRAGMA journal_mode = DELETE;   -- single-file artifact, no WAL sidecar

CREATE TABLE meta (
    key    TEXT PRIMARY KEY,
    value  TEXT NOT NULL
);
-- rows: schemaVersion, builtAt, sourceDate, productCount, categories

CREATE TABLE category (
    categoryId   INTEGER PRIMARY KEY,
    name         TEXT NOT NULL,
    displayName  TEXT NOT NULL
);

CREATE TABLE cardSet (
    groupId      INTEGER PRIMARY KEY,
    categoryId   INTEGER NOT NULL REFERENCES category(categoryId),
    name         TEXT NOT NULL,
    abbreviation TEXT,
    publishedOn  TEXT
);
CREATE INDEX idx_set_category ON cardSet(categoryId);

CREATE TABLE product (
    productId      INTEGER PRIMARY KEY,
    groupId        INTEGER NOT NULL REFERENCES cardSet(groupId),
    categoryId     INTEGER NOT NULL,
    name           TEXT NOT NULL,
    cleanName      TEXT NOT NULL,
    imageUrl       TEXT,
    number         TEXT,
    numberNum      INTEGER,
    setTotal       INTEGER,
    setCode        TEXT,
    rarity         TEXT,
    cardType       TEXT,
    isSealed       INTEGER NOT NULL DEFAULT 0,
    printingCount  INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_product_set      ON product(groupId);
CREATE INDEX idx_product_number   ON product(numberNum, setTotal);
CREATE INDEX idx_product_setcode  ON product(setCode, numberNum);
CREATE INDEX idx_product_clean    ON product(cleanName);
CREATE INDEX idx_product_sealed   ON product(isSealed);

CREATE TABLE sku (
    skuId       INTEGER PRIMARY KEY,
    productId   INTEGER NOT NULL REFERENCES product(productId),
    conditionId INTEGER,
    printingId  INTEGER,
    languageId  INTEGER
);
CREATE INDEX idx_sku_product ON sku(productId);

CREATE TABLE price (
    productId            INTEGER NOT NULL,
    subTypeName          TEXT NOT NULL,
    marketPriceCents     INTEGER,
    lowPriceCents        INTEGER,
    midPriceCents        INTEGER,
    highPriceCents       INTEGER,
    directLowPriceCents  INTEGER,
    asOf                 TEXT NOT NULL,
    PRIMARY KEY (productId, subTypeName)
);
```

### Search indexes

Two, because they fail differently.

```sql
-- Path A: token and prefix search. "char" -> Charizard.
CREATE VIRTUAL TABLE product_fts USING fts5(
    name, number, setName,
    content='',
    tokenize='unicode61 remove_diacritics 2',
    prefix='2 3 4'
);

-- Path B: typo tolerance. "charzard" -> Charizard.
CREATE VIRTUAL TABLE product_trigram USING fts5(
    name, number,
    content='',
    tokenize='trigram'
);
```

Both are contentless with `rowid = productId`. Populate during the build, then
`INSERT INTO product_fts(product_fts) VALUES('optimize');` before finalizing.

Run `VACUUM;` and `PRAGMA optimize;` at the end so the shipped file is compact.

---

## The publish script

```
scripts/publish-catalog.sh
```

- No schedule. AJ runs it by hand on his Mac. Revised 2026-09-11, on AJ's call: this
  was a daily GitHub Action, and its macOS runner took over 78 minutes to sign the
  artwork that the Mac signs in 24. Run it after 20:00 UTC to get that day's TCGCSV data.
- Fetch categories, resolve configured names to IDs, then walk groups → products →
  prices for each
- Be polite: modest concurrency, retry with backoff on 5xx, treat a 404 on an empty
  group as normal
- Build `catalog.sqlite`, compress with gzip
- Copy the artwork signatures from the published catalog into the new one, then
  sign the products that have none (`catalog/build_descriptors.swift`)
- Publish two assets to a **public** release, tag `catalog-latest`, replacing prior
  assets:
  - `catalog.sqlite.gz`
  - `catalog-manifest.json`

Manifest:

```json
{
  "schemaVersion": 1,
  "builtAt": "2026-09-09T21:34:02Z",
  "sourceDate": "2026-09-09",
  "sizeBytes": 41234567,
  "sha256": "…",
  "productCount": 152431,
  "categories": [{ "categoryId": 3, "name": "Pokemon", "productCount": 89210 }],
  "url": "https://github.com/<owner>/<repo>/releases/download/catalog-latest/catalog.sqlite.gz"
}
```

### Failure behavior

If TCGCSV is unreachable or a category resolves to zero products, **fail the run and
publish nothing**. A stale catalog is fine; a truncated one silently breaks search,
which is exactly the failure mode this project exists to eliminate.

---

## Device side

**Download:** fetch the manifest, compare `builtAt` and `sha256` against what's
installed, download only on change. Manual "check now" plus an opportunistic check on
launch. Verify the SHA before use.

**Swap:** decompress to a temp file, open it, sanity-check (`meta.schemaVersion`
matches what the app expects, `productCount` is within a sane band of the previous
build), then atomically replace. Never mutate the live file in place mid-session — a
scan session must not have the catalog change underneath it.

**First run:** the app is useless without a catalog, so the first launch is a download
with visible progress. Expect tens of megabytes gzipped. Do not bundle a catalog in
the app binary; it would be stale on arrival and bloat the sideload.

**Storage:** Application Support, excluded from backup (`isExcludedFromBackup = true`)
— it's re-downloadable, and there's no reason to push it through a device backup.

**Schema version mismatch:** if the manifest's `schemaVersion` exceeds what the app
understands, refuse the update and keep the current catalog rather than downloading
something unreadable.
