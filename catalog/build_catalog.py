#!/usr/bin/env python3
"""Build catalog.sqlite from TCGCSV.

The job walks categories -> groups -> products -> prices, flattens the fields the
app searches on, and writes one SQLite file plus a manifest. It runs daily in
GitHub Actions. See docs/01-catalog-pipeline.md for the design and
catalog/README.md for the operational notes.

Standard library only. No third-party dependency.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import gzip
import hashlib
import json
import os
import re
import shutil
import sqlite3
import ssl
import sys
import time
import unicodedata
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path
from typing import Any, Iterable

SCHEMA_VERSION = 1
BASE_URL = "https://tcgcsv.com/tcgplayer"

# Category names as TCGCSV spells them. The job resolves them to IDs at run time
# and fails if a name does not resolve.
CATEGORY_NAMES = ["Pokemon", "Pokemon Japan", "Digimon Card Game", "Union Arena"]

# Words that mark a Chinese-language category. The job scans the full category
# list for them and reports the result. It does not add them to the build.
CHINESE_MARKERS = ("chinese", "china", "mandarin", "simplified", "traditional")

# TCGCSV answers 401 to Python's default user agent. Send a descriptive one.
USER_AGENT = "card-tracker-catalog-builder/1.0 (+https://github.com/ajhollowayvrm/binderbooks)"

WORKERS = 6
RETRIES = 5
TIMEOUT_SECONDS = 60


# --------------------------------------------------------------------------- money


def to_cents(value: Any) -> int | None:
    """Convert a TCGCSV price to integer cents. Round exactly once, here.

    Decimal(str(x)) reads the literal as written. That avoids float artifacts
    such as 0.35000000000000003.
    """
    if value is None:
        return None
    return int(Decimal(str(value)).quantize(Decimal("0.01"), ROUND_HALF_UP) * 100)


# ------------------------------------------------------------------------ parsing


@dataclass(frozen=True)
class ParsedNumber:
    numberNum: int | None = None
    setTotal: int | None = None
    setCode: str | None = None


_NUM_SLASH_NUM = re.compile(r"^(\d+)\s*/\s*(\d+)\b")
_NUM_SLASH_CODE = re.compile(r"^(\d+)\s*/\s*([A-Za-z][A-Za-z0-9\-]*)$")
_CODE_SLASH_TAIL = re.compile(r"^([A-Za-z0-9]+)/(.+)$")
_CODE_DASH_NUM = re.compile(r"^([A-Za-z]+\d*[A-Za-z]*)-(\d+)")
_CODE_NUM = re.compile(r"^([A-Za-z]+)\s*(\d+)[a-z]?$")
_BARE_NUM = re.compile(r"^(\d+)$")
_TRAILING_DIGITS = re.compile(r"(\d+)\s*$")


def parse_number(raw: str | None) -> ParsedNumber:
    """Split a collector number into the parts the scanner matches on.

    Formats seen in the live catalog, 2026-09:
      114/084             -> numberNum 114, setTotal 84            (Pokemon)
      001/M-P, 226/S-P    -> numberNum 1,   setCode M-P            (promos, mostly Japan)
      007/PPP             -> numberNum 7,   setCode PPP
      SWSH083, SVP 200    -> numberNum 83,  setCode SWSH / SVP     (English promos)
      XY67a, SM30a        -> numberNum 67,  setCode XY             (promo variants)
      001                 -> numberNum 1                            (bare)
      BT26-052 C          -> numberNum 52,  setCode BT26           (Digimon; rarity suffix dropped)
      UE10BT/AOT-1-007    -> numberNum 7,   setCode UE10BT         (Union Arena)
      UEX07BT/AOT-2-AP01  -> numberNum 1,   setCode UEX07BT
      073/076 / 074/076   -> first card wins
    """
    if not raw:
        return ParsedNumber()
    text = raw.strip()
    if not text:
        return ParsedNumber()

    m = _NUM_SLASH_NUM.match(text)
    if m:
        return ParsedNumber(numberNum=int(m.group(1)), setTotal=int(m.group(2)))

    m = _NUM_SLASH_CODE.match(text)
    if m:
        return ParsedNumber(numberNum=int(m.group(1)), setCode=m.group(2).upper())

    m = _CODE_SLASH_TAIL.match(text)
    if m:
        # Union Arena: the set code sits before the slash, the number is the last
        # numeric run in the tail.
        tail = m.group(2)
        digits = _TRAILING_DIGITS.search(tail)
        num = int(digits.group(1)) if digits else None
        return ParsedNumber(numberNum=num, setCode=m.group(1).upper())

    m = _CODE_DASH_NUM.match(text)
    if m:
        return ParsedNumber(numberNum=int(m.group(2)), setCode=m.group(1).upper())

    m = _CODE_NUM.match(text)
    if m:
        return ParsedNumber(numberNum=int(m.group(2)), setCode=m.group(1).upper())

    m = _BARE_NUM.match(text)
    if m:
        return ParsedNumber(numberNum=int(m.group(1)))

    return ParsedNumber()


_PUNCT = re.compile(r"[^\w\s]", re.UNICODE)
_SPACES = re.compile(r"\s+")


def clean_name(name: str) -> str:
    """Lowercase, no diacritics, no punctuation, single spaces. The matching key."""
    decomposed = unicodedata.normalize("NFKD", name)
    stripped = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    no_punct = _PUNCT.sub(" ", stripped.replace("&", " and "))
    return _SPACES.sub(" ", no_punct).strip().lower()


def display_name(name: str, number: str | None) -> str:
    """Drop a trailing ' - <number>' or ' (<number>)' that repeats the collector number.

    TCGplayer names promos 'Alakazam V - SWSH083' and Union Arena cards
    'Levi (007)'. The number lives in its own column, so the name should not
    carry it. OCR reads the printed name, which does not include it.
    """
    if not number:
        return name.strip()
    num = number.strip()
    for suffix in (f" - {num}", f" ({num})"):
        if name.endswith(suffix):
            return name[: -len(suffix)].strip()
    parsed = parse_number(num)
    if parsed.numberNum is not None:
        m = re.search(r"\s\((\d+)\)$", name)
        if m and int(m.group(1)) == parsed.numberNum:
            return name[: m.start()].strip()
    return name.strip()


def extended(product: dict[str, Any]) -> dict[str, str]:
    """Flatten extendedData into {name: value}."""
    out: dict[str, str] = {}
    for entry in product.get("extendedData") or []:
        name = entry.get("name")
        value = entry.get("value")
        if name and value is not None:
            out[name] = str(value)
    return out


def is_sealed(product: dict[str, Any], ext: dict[str, str]) -> bool:
    """A product with neither a collector number nor a rarity is sealed.

    TCGCSV does not say which products fall under the category's sealed label,
    so the extendedData keys are the deterministic signal. Booster boxes,
    packs, tins, ETBs, blisters, bundles, and cases carry neither key. Basic
    energies and unnumbered Japanese promos carry no Number but do carry a
    Rarity, so they stay singles. Code cards carry neither key but are not
    sealed product. They stay unsealed and never match a number query.
    """
    if "Number" in ext or "Rarity" in ext:
        return False
    return not product.get("name", "").startswith("Code Card")


# ------------------------------------------------------------------------- fetch


class FetchError(RuntimeError):
    pass


def _ssl_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    try:
        import certifi  # type: ignore

        ctx.load_verify_locations(cafile=certifi.where())
    except ImportError:
        pass
    return ctx


_SSL = _ssl_context()


def fetch_json(url: str, retries: int = RETRIES) -> dict[str, Any]:
    """GET a TCGCSV endpoint. Retry on 5xx, 429, and network errors.

    A 404 means an empty group. It comes back as {"results": []}.
    """
    delay = 1.0
    last: Exception | None = None
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS, context=_SSL) as resp:
                body = json.load(resp)
            if not isinstance(body, dict) or "results" not in body:
                raise FetchError(f"{url}: unexpected body shape")
            return body
        except urllib.error.HTTPError as err:
            if err.code == 404:
                return {"success": True, "errors": [], "results": []}
            last = err
            if err.code < 500 and err.code != 429:
                raise FetchError(f"{url}: HTTP {err.code}") from err
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as err:
            last = err
        if attempt < retries:
            time.sleep(delay)
            delay = min(delay * 2, 30)
    raise FetchError(f"{url}: gave up after {retries} attempts: {last}")


# ------------------------------------------------------------------------- model


@dataclass
class GroupData:
    group: dict[str, Any]
    products: list[dict[str, Any]] = field(default_factory=list)
    prices: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class CategoryData:
    category: dict[str, Any]
    groups: list[GroupData] = field(default_factory=list)

    @property
    def product_count(self) -> int:
        return sum(len(g.products) for g in self.groups)


def resolve_categories(all_categories: list[dict[str, Any]], names: Iterable[str]) -> list[dict[str, Any]]:
    """Map configured names to live category rows. Fail loudly on a miss."""
    by_name = {c["name"].strip().lower(): c for c in all_categories}
    resolved = []
    missing = []
    for name in names:
        row = by_name.get(name.strip().lower())
        if row is None:
            missing.append(name)
        else:
            resolved.append(row)
    if missing:
        available = ", ".join(sorted(c["name"] for c in all_categories))
        raise SystemExit(f"category names did not resolve: {missing}. Live names: {available}")
    return resolved


def find_chinese_categories(all_categories: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [c for c in all_categories if any(m in c["name"].lower() for m in CHINESE_MARKERS)]


def fetch_group(category_id: int, group: dict[str, Any]) -> GroupData:
    gid = group["groupId"]
    products = fetch_json(f"{BASE_URL}/{category_id}/{gid}/products")["results"]
    prices = fetch_json(f"{BASE_URL}/{category_id}/{gid}/prices")["results"]
    return GroupData(group=group, products=products, prices=prices)


def fetch_everything(categories: list[dict[str, Any]], log) -> list[CategoryData]:
    out: list[CategoryData] = []
    for cat in categories:
        cid = cat["categoryId"]
        groups = fetch_json(f"{BASE_URL}/{cid}/groups")["results"]
        if not groups:
            raise SystemExit(f"category {cat['name']} ({cid}) returned zero groups; refusing to publish")
        data = CategoryData(category=cat)
        started = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=WORKERS) as pool:
            futures = {pool.submit(fetch_group, cid, g): g for g in groups}
            for fut in concurrent.futures.as_completed(futures):
                # Any group failure aborts the build. A missing group looks like an
                # empty search result on the device, which is the failure this job
                # exists to prevent.
                data.groups.append(fut.result())
        data.groups.sort(key=lambda g: g.group["groupId"])
        empty = sum(1 for g in data.groups if not g.products)
        log(
            f"{cat['name']}: {len(groups)} groups, {data.product_count} products, "
            f"{empty} empty groups, {time.monotonic() - started:.1f}s"
        )
        if data.product_count == 0:
            raise SystemExit(f"category {cat['name']} ({cid}) has zero products; refusing to publish")
        out.append(data)
    return out


# ------------------------------------------------------------------------ sqlite


DDL = """
CREATE TABLE meta (
    key    TEXT PRIMARY KEY,
    value  TEXT NOT NULL
);

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
CREATE INDEX idx_product_numstr   ON product(number);
CREATE INDEX idx_product_sealed   ON product(isSealed);

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
"""


def product_row(p: dict[str, Any], category_id: int) -> tuple:
    ext = extended(p)
    number = ext.get("Number")
    parsed = parse_number(number)
    shown = display_name(p["name"], number)
    return (
        p["productId"],
        p["groupId"],
        category_id,
        shown,
        clean_name(shown),
        p.get("imageUrl"),
        number,
        parsed.numberNum,
        parsed.setTotal,
        parsed.setCode,
        ext.get("Rarity"),
        ext.get("CardType") or ext.get("Card Type"),
        1 if is_sealed(p, ext) else 0,
    )


def build_sqlite(path: Path, data: list[CategoryData], built_at: str, source_date: str) -> dict[str, Any]:
    if path.exists():
        path.unlink()
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode = DELETE")
    conn.executescript(DDL)

    product_count = 0
    seen_products: set[int] = set()
    category_counts = []

    for cat in data:
        c = cat.category
        conn.execute(
            "INSERT INTO category VALUES (?, ?, ?)",
            (c["categoryId"], c["name"], c.get("displayName") or c["name"]),
        )
        cat_products = 0
        for g in cat.groups:
            grp = g.group
            conn.execute(
                "INSERT INTO cardSet VALUES (?, ?, ?, ?, ?)",
                (grp["groupId"], c["categoryId"], grp["name"], grp.get("abbreviation"), grp.get("publishedOn")),
            )
            printings: dict[int, set[str]] = {}
            for pr in g.prices:
                printings.setdefault(pr["productId"], set()).add(pr["subTypeName"])

            rows = []
            fts_rows = []
            tri_rows = []
            for p in g.products:
                pid = p["productId"]
                if pid in seen_products:
                    continue
                seen_products.add(pid)
                row = product_row(p, c["categoryId"])
                rows.append(row + (max(1, len(printings.get(pid, ()))),))
                fts_rows.append((pid, row[3], row[6] or "", grp["name"]))
                tri_rows.append((pid, row[3], row[6] or ""))
            conn.executemany("INSERT INTO product VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
            conn.executemany("INSERT INTO product_fts(rowid, name, number, setName) VALUES (?,?,?,?)", fts_rows)
            conn.executemany("INSERT INTO product_trigram(rowid, name, number) VALUES (?,?,?)", tri_rows)
            cat_products += len(rows)

            conn.executemany(
                "INSERT OR REPLACE INTO price VALUES (?,?,?,?,?,?,?,?)",
                [
                    (
                        pr["productId"],
                        pr["subTypeName"],
                        to_cents(pr.get("marketPrice")),
                        to_cents(pr.get("lowPrice")),
                        to_cents(pr.get("midPrice")),
                        to_cents(pr.get("highPrice")),
                        to_cents(pr.get("directLowPrice")),
                        source_date,
                    )
                    for pr in g.prices
                    if pr["productId"] in seen_products
                ],
            )
        product_count += cat_products
        category_counts.append({"categoryId": c["categoryId"], "name": c["name"], "productCount": cat_products})

    meta = {
        "schemaVersion": str(SCHEMA_VERSION),
        "builtAt": built_at,
        "sourceDate": source_date,
        "productCount": str(product_count),
        "categories": json.dumps(category_counts, separators=(",", ":")),
    }
    conn.executemany("INSERT INTO meta VALUES (?, ?)", meta.items())
    conn.commit()

    conn.execute("INSERT INTO product_fts(product_fts) VALUES('optimize')")
    conn.execute("INSERT INTO product_trigram(product_trigram) VALUES('optimize')")
    conn.commit()
    conn.execute("PRAGMA optimize")
    conn.execute("VACUUM")
    conn.close()
    return {"productCount": product_count, "categories": category_counts}


# ------------------------------------------------------------------------ output


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def gzip_file(src: Path, dst: Path) -> None:
    with src.open("rb") as fin, gzip.open(dst, "wb", compresslevel=9) as fout:
        shutil.copyfileobj(fin, fout)


def restamp(out: Path) -> int:
    """Recompute the manifest's size and checksum for the file on disk.

    The artwork signatures are added after this job runs, on a macOS runner,
    because Vision's feature print needs the neural engine. That changes the
    SQLite file and so the gzip, and the app refuses a download whose checksum
    does not match the manifest. Everything else the manifest says — the product
    count, the categories, the build time — is still true.
    """
    gz_path = out / "catalog.sqlite.gz"
    manifest_path = out / "catalog-manifest.json"
    if not gz_path.exists():
        print(f"no catalog at {gz_path}", file=sys.stderr)
        return 1
    if not manifest_path.exists():
        print(f"no manifest at {manifest_path}", file=sys.stderr)
        return 1

    manifest = json.loads(manifest_path.read_text())
    manifest["sizeBytes"] = gz_path.stat().st_size
    manifest["sha256"] = sha256_of(gz_path)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"restamped: {manifest['sizeBytes'] / 1e6:.1f} MB, sha256 {manifest['sha256'][:12]}…")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="build", help="output directory")
    ap.add_argument(
        "--release-url",
        default=os.environ.get("CATALOG_RELEASE_URL", ""),
        help="download URL written into the manifest",
    )
    ap.add_argument(
        "--restamp",
        action="store_true",
        help="only recompute the manifest's size and checksum for the file on disk",
    )
    args = ap.parse_args(argv)

    out = Path(args.out)
    if args.restamp:
        return restamp(out)

    out.mkdir(parents=True, exist_ok=True)
    report: list[str] = []

    def log(msg: str) -> None:
        print(msg, flush=True)
        report.append(f"- {msg}")

    started = time.monotonic()
    now = datetime.now(timezone.utc)
    built_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    source_date = now.strftime("%Y-%m-%d")

    all_categories = fetch_json(f"{BASE_URL}/categories")["results"]
    log(f"TCGCSV lists {len(all_categories)} categories")
    categories = resolve_categories(all_categories, CATEGORY_NAMES)
    log("resolved: " + ", ".join(f"{c['name']}={c['categoryId']}" for c in categories))

    chinese = find_chinese_categories(all_categories)
    if chinese:
        log("Chinese-language categories found (not in the build): " + ", ".join(f"{c['name']}={c['categoryId']}" for c in chinese))
    else:
        log("No Chinese-language category exists on TCGCSV. TCGplayer does not carry Chinese cards.")

    data = fetch_everything(categories, log)

    sqlite_path = out / "catalog.sqlite"
    gz_path = out / "catalog.sqlite.gz"
    manifest_path = out / "catalog-manifest.json"

    summary = build_sqlite(sqlite_path, data, built_at, source_date)
    gzip_file(sqlite_path, gz_path)

    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "builtAt": built_at,
        "sourceDate": source_date,
        "sizeBytes": gz_path.stat().st_size,
        "sha256": sha256_of(gz_path),
        "productCount": summary["productCount"],
        "categories": summary["categories"],
        "url": args.release_url,
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")

    log(
        f"wrote {summary['productCount']} products; sqlite {sqlite_path.stat().st_size / 1e6:.1f} MB, "
        f"gzip {manifest['sizeBytes'] / 1e6:.1f} MB, {time.monotonic() - started:.0f}s total"
    )
    (out / "build-report.md").write_text("## Catalog build\n\n" + "\n".join(report) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
