# Catalog pipeline

`build_catalog.py` builds the read-only catalog the app searches. AJ runs it by hand
on his Mac with `scripts/publish-catalog.sh`, which publishes two assets to the
public release `catalog-latest`:

- `catalog.sqlite.gz`
- `catalog-manifest.json`

The script also signs the artwork. `merge_descriptors.py` copies the published
signatures into the new catalog, and `build_descriptors.swift` signs the products
that have none. Nothing runs on a schedule. A GitHub Action did this until
2026-09-11, and its macOS runner was several times slower than the Mac.

The design is in `docs/01-catalog-pipeline.md`. This file records what the live
TCGCSV data looks like and where the build deviates from the design.

## The Simplified Chinese catalog

TCGplayer does not sell Simplified Chinese cards, so TCGCSV has none. On 2026-09-14
AJ approved PikaQian (https://pikaqian.com/docs/) as a second source, for these
cards only. `build_chinese.py` writes `chinese-catalog.sqlite` with the same schema
as `catalog.sqlite`. The app imports the file through Files and merges its rows into
the live catalog (`ios/Sources/Catalog/ChineseCatalog.swift`).

The file never goes to GitHub. PikaQian publishes no terms of use, and the data is
for AJ alone. `scripts/build-chinese-catalog.sh` builds it, signs the artwork, and
copies it to Box.

```sh
caffeinate -i scripts/build-chinese-catalog.sh              # every set, about 200 requests
scripts/build-chinese-catalog.sh --price collection.json    # price the cards he holds
```

The key is in `~/.config/binderbooks/pikaqian-key` or `PIKAQIAN_API_KEY`. Never put
it in the repo.

Facts about PikaQian, verified 2026-09-14:

- **The plan is Hobby.** The response header `x-ratelimit-quota` is 5,000 requests a
  month. Graded prices need Pro and come back `null` on Hobby.
- **132 sets.** `/v1/sets` and `/v1/cards` use cursor pages of at most 100 rows.
- **A card id is a UUID.** The build hashes it into a product id from 1,000,000,000
  to 1,999,999,999. The artwork index stores ids as `Int32`. A rebuild reads the
  previous file's `pikaqianCard` table first, so an id never moves.
- **The card list has no price.** A price is one request to
  `/v1/cards/{id}/prices`: `grades.raw.price_cents`, the eBay average of the last 7
  days, and `recent_sale_count`. That is why the build prices only the cards he
  holds.
- **The API number is not the printed number.** A Gem Pack card is `"01 01"` in the
  API and prints `0101/07`: slot 01, art 01 of 7. A numbered card is `"001"` and
  prints `001/128`. The build writes the printed form. The total is the highest
  number among Common, Uncommon, Rare, Double Rare, and ACE SPEC Rare cards. That
  rule gives 128 for `csv6c` and 208 for Terastal Gathering, which match the cards.
  A set with none of these rarities, such as a start deck or a promo set, gets no
  total. Start Deck 100 prints `/414`, but its numbers go to 433.
- **Most cards have no eBay sales.** On 2026-09-14, `/v1/cards?has_price=true` listed
  6,393 of 20,252 cards, at 100 a page. The build writes those cards to `productSales`
  and sets `meta.salesCheckedAt`. The app shows "No sales" for a Chinese card that is
  not in the table. A `--sets` build does not ask, so its file claims nothing. For a
  card with no sales, `/cards/{id}/prices` returns 404. The price run records no price
  and continues.
- **A pattern printing is its own card.** `variant` is `pokeball` or `masterball`
  with `is_variant: true`. The build names it `Surskit (Poke Ball Pattern)`, the way
  TCGplayer does, so `CardMatcher.isVariantSibling` works unchanged.
- **Images need no key.** They are 300×419 PNGs on `images.pikaqian.com`, larger
  than TCGplayer's 200×280 thumbnails.
- **Chinese category id 10,000.** It is not a TCGplayer id. The app names it
  `TCGCategory.pokemonChinese`.

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

- **The build takes two categories: `Pokemon` and `Pokemon Japan`.** The names are
  exact. The job resolves names to IDs on every run and fails if a name does not
  resolve. On 2026-09-12 AJ removed `Digimon Card Game`, `Union Arena`, and
  `Palworld OFFICIAL CARD GAME`. He owns no English cards from them, and he enters
  other cards by hand in the app. The parser still reads their number formats,
  below, so a category can come back with one line in `CATEGORY_NAMES`.
- **Palworld (category 91) was checked on 2026-09-12.** It had 8 groups and 282
  products. Numbers look like `EBP01-001OSR`, and the `CODE-NUM` rule reads them.
  Prototype cards have no number and the rarity `None`, so they stay singles. The
  printings are `Normal` and `Foil`. TCGplayer carries no Chinese Palworld cards.
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
