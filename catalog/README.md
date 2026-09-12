# Catalog pipeline

`build_catalog.py` builds the read-only catalog the app searches. It runs daily in
GitHub Actions (`.github/workflows/build-catalog.yml`) and publishes two assets to
the public release `catalog-latest`:

- `catalog.sqlite.gz`
- `catalog-manifest.json`

The Action does not sign artwork. It copies the signatures from the published
catalog into the new one, and `merge_descriptors.py` does that copy. AJ's Mac signs
the products that have no signature with `scripts/sign-catalog.sh`, then publishes
the catalog again. A macOS runner does the same work several times slower.

The design is in `docs/01-catalog-pipeline.md`. This file records what the live
TCGCSV data looks like and where the build deviates from the design.

## Run it locally

```sh
python3 -m unittest discover -s catalog -v
python3 catalog/build_catalog.py --out build
```

The script uses only the standard library. If your Python cannot verify TLS
certificates, install `certifi` in that Python. The script uses it when it is
present.

A full build makes about 1,750 requests and takes a few minutes.

## Facts about TCGCSV, verified 2026-09-09

- **The category names are exact.** `Pokemon`, `Pokemon Japan`, `Digimon Card Game`,
  `Union Arena`. The name is not `Digimon`. The job resolves names to IDs on every
  run and fails if a name does not resolve.
- **No Chinese-language category exists.** The job scans all category names on every
  run and writes the result to the build report.
- **TCGCSV returns 401 to Python's default user agent.** The job sends its own
  `User-Agent` header. `curl` works without one.
- **An empty group returns 200 with `results: []`**, not only 404. The job treats
  both as an empty group.
- **There is no SKU endpoint.** `/{categoryId}/{groupId}/skus` does not exist. The
  `sku` table from the design is not in the build. Add it when a source exists.
- **Products have no sealed flag.** The category object names its sealed and single
  labels, but no product carries either label. The job marks a product as sealed
  when its `extendedData` has neither a `Number` nor a `Rarity` entry. Basic
  energies and unnumbered Japanese promos have a rarity and no number, and they are
  singles. Code cards have neither key. The job keeps them unsealed, so a sealed
  boost never lifts a code card.
- **The card type key differs by category.** English Pokemon uses `Card Type`.
  Pokemon Japan, Digimon, and Union Arena use `CardType`. The job reads both.
- **Prices carry no timestamp.** The job stamps every price row with the build date
  (UTC) as `asOf`.

## Collector number formats

`parse_number` handles every shape seen in the live catalog:

| Raw | numberNum | setTotal | setCode | Where |
|---|---:|---:|---|---|
| `114/084` | 114 | 84 | | Pokemon, Pokemon Japan |
| `226/197` | 226 | 197 | | secret rares exceed the total |
| `001/M-P` | 1 | | `M-P` | Pokemon Japan promos |
| `SWSH083` | 83 | | `SWSH` | English promos |
| `SVP 200` | 200 | | `SVP` | English promos |
| `073` | 73 | | | Mega Evolution promos |
| `BT26-052 C` | 52 | | `BT26` | Digimon, rarity suffix dropped |
| `UE10BT/AOT-1-007` | 7 | | `UE10BT` | Union Arena |
| `UEX07BT/AOT-2-AP01` | 1 | | `UEX07BT` | Union Arena alternate art |
| `073/076 / 074/076` | 73 | 76 | | two-card products, first wins |

## Names

TCGplayer repeats the collector number in many product names: `Alakazam V - SWSH083`,
`Levi (007)`. The job removes that suffix from `name` and `cleanName`. The number
stays in the `number` column and in both search indexes. OCR reads the printed
name, which never includes the suffix.

## Search notes for the app

Measured on the 2026-09-10 build (79,802 products, 41.5 MB) with SQLite on a Mac:

- `product_fts MATCH 'char*'` returns in under 1 ms. A number key lookup returns in
  under 0.1 ms.
- **Both FTS tables are contentless.** A query returns `rowid` only. Join to
  `product` on `productId` for the name.
- **`MATCH 'charzard'` on the trigram table returns nothing.** The trigram tokenizer
  needs every trigram of the query to exist in the row. For typo tolerance, split the
  query into trigrams and join them with `OR`, then order by `bm25()`:
  `"cha" OR "har" OR "arz" OR "rza" OR "zar" OR "ard"`. That query returns Charizard
  first in under 3 ms.
- **Japanese script finds nothing.** TCGplayer names Pokemon Japan products in
  English. Number matching still works on Japanese cards.
- **`(numberNum, setTotal)` is not unique on its own.** Of 18,511 keys, 7,779 map to
  one product. The rest collide across reprints, English and Japanese sets that share a
  total, and older sets. The name narrows them, as `docs/03` expects.
- 6,523 products have no price row. Their `printingCount` is 1.

## Failure behavior

The job publishes nothing when:

- a configured category name does not resolve,
- a category returns zero groups or zero products,
- any group request still fails after five retries.

A stale catalog on the device is safe. A truncated one is not.
