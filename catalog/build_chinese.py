#!/usr/bin/env python3
"""Build chinese-catalog.sqlite from PikaQian, and price the cards AJ owns.

TCGplayer carries no Simplified Chinese cards, so TCGCSV cannot supply them.
PikaQian (https://pikaqian.com/docs/) indexes every Simplified Chinese set with
English names, Chinese names, images, and eBay prices. This job turns that into
a second catalog file with the same schema as catalog.sqlite. The app imports
the file through Files and adds its rows to the live catalog.

The file never goes to GitHub. PikaQian publishes no terms of use, and the data
is for AJ alone. scripts/build-chinese-catalog.sh runs this job, signs the
artwork, and copies the file to Box.

Two commands:

    build   Fetch every set and card. Keep the IDs, signatures, and prices of
            the previous file, so a card he owns keeps its productId.
    price   Read a collection export, fetch the eBay price of each Chinese card
            he owns, write the prices into the file, and write a CSV sorted by
            value for the eBay listing decision.

The key comes from PIKAQIAN_API_KEY or from ~/.config/binderbooks/pikaqian-key.
Standard library only, plus certifi when it is present.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

import build_catalog as bc

API_URL = "https://api.pikaqian.com/v1"
USER_AGENT = "binderbooks-chinese-catalog/1.0"
KEY_FILE = Path.home() / ".config" / "binderbooks" / "pikaqian-key"

FILE_NAME = "chinese-catalog.sqlite"
# The app refuses a file whose `kind` it does not know.
KIND = "pokemon-zh-hans"
FORMAT_VERSION = 1

# Not a TCGplayer category. TCGplayer's ids are two digits, so this one cannot
# collide. The app names it TCGCategory.pokemonChinese.
CATEGORY_ID = 10_000
CATEGORY_NAME = "Pokemon Simplified Chinese"

# Product ids live from 1,000,000,000 to 1,999,999,999. TCGplayer's highest is
# under 1,000,000, and the app's artwork index stores ids as Int32, whose
# ceiling is 2,147,483,647.
PRODUCT_ID_BASE = 1_000_000_000
ID_SPAN = 1_000_000_000
# Set ids get the same range. They are a different table, so the ranges may
# overlap with product ids.
GROUP_ID_BASE = 1_000_000_000

PAGE_SIZE = 100
RETRIES = 5
TIMEOUT_SECONDS = 60

# The rarities that sit inside the printed total. A numbered set prints
# "001/128", and the API gives only "001". On csv6c the last card of these
# rarities is 128 and the first Art Rare is 129.
TOTAL_RARITIES = {"common", "uncommon", "rare", "double rare"}

# PikaQian lists a pattern printing as its own card. TCGplayer lists it as its
# own product under the base name plus this qualifier, and the matcher knows
# that shape: `CardMatcher.isVariantSibling`.
PATTERN_QUALIFIERS = {
    "pokeball": "Poke Ball Pattern",
    "masterball": "Master Ball Pattern",
}

PRINTINGS = {
    "holo": "Holofoil",
    "non-holo": "Normal",
    "reverse": "Reverse Holofoil",
    "reverse-holo": "Reverse Holofoil",
}

EXTRA_DDL = """
CREATE TABLE IF NOT EXISTS productArt (
    productId  INTEGER PRIMARY KEY,
    descriptor BLOB NOT NULL
);

-- The name the card prints. The matcher looks a Chinese line up here.
CREATE TABLE productLocalName (
    productId  INTEGER PRIMARY KEY,
    localName  TEXT NOT NULL
);
CREATE INDEX idx_local_name ON productLocalName(localName);

-- PikaQian's own ids. A rebuild reads them back, so no productId moves.
CREATE TABLE pikaqianCard (
    productId  INTEGER PRIMARY KEY,
    cardId     TEXT NOT NULL UNIQUE,
    setId      TEXT NOT NULL
);
CREATE TABLE pikaqianSet (
    groupId    INTEGER PRIMARY KEY,
    setId      TEXT NOT NULL UNIQUE
);

-- The last eBay price fetched for a card, and how many sales it rests on.
CREATE TABLE pikaqianPrice (
    productId        INTEGER PRIMARY KEY,
    rawCents         INTEGER,
    recentSaleCount  INTEGER,
    updatedAt        TEXT,
    fetchedAt        TEXT NOT NULL
);

-- The exact text written into the two FTS tables. Both are contentless, so
-- the app can only delete a row by repeating what was inserted. This table is
-- what it repeats when it replaces an older import.
CREATE TABLE ftsText (
    productId  INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    number     TEXT NOT NULL,
    setName    TEXT NOT NULL
);
"""


# ------------------------------------------------------------------------- ids


def stable_id(key: str, taken: set[int], base: int = PRODUCT_ID_BASE, span: int = ID_SPAN) -> int:
    """A number for `key` that does not change between builds.

    The hash decides, so a card keeps its id even if the previous file is lost.
    A collision moves to the next free number. The previous file's mapping wins
    over the hash, which keeps a moved id in place on the next build.
    """
    digest = hashlib.sha256(key.encode("utf-8")).digest()
    offset = int.from_bytes(digest[:8], "big") % span
    for step in range(span):
        candidate = base + (offset + step) % span
        if candidate not in taken:
            return candidate
    raise RuntimeError("the id range is full")


def assign_ids(keys: Iterable[str], previous: dict[str, int], base: int = PRODUCT_ID_BASE) -> dict[str, int]:
    """Give every key an id. A key from the previous build keeps its id."""
    wanted = sorted(set(keys))
    out: dict[str, int] = {}
    taken: set[int] = set()
    for key in wanted:
        if key in previous and previous[key] not in taken:
            out[key] = previous[key]
            taken.add(previous[key])
    for key in wanted:
        if key not in out:
            out[key] = stable_id(key, taken, base=base)
            taken.add(out[key])
    return out


# --------------------------------------------------------------------- numbers


def set_total(cards: list[dict[str, Any]]) -> int | None:
    """The total a numbered set prints after the slash, or None.

    The API does not give it. The last card of the ordinary rarities is the
    total, and the secret rares count past it.
    """
    numbers = [
        int(c["card_number"])
        for c in cards
        if not c.get("is_variant")
        and str(c.get("card_number", "")).isdigit()
        and (c.get("rarity_label") or "").strip().lower() in TOTAL_RARITIES
    ]
    return max(numbers) if numbers else None


def slot_totals(cards: list[dict[str, Any]]) -> dict[str, int]:
    """For a Gem Pack: how many arts each Pokémon slot has. "01 07" is art 7."""
    arts: dict[str, int] = defaultdict(int)
    for c in cards:
        parts = str(c.get("card_number", "")).split()
        if len(parts) == 2 and all(p.isdigit() for p in parts):
            arts[parts[0]] = max(arts[parts[0]], int(parts[1]))
    return dict(arts)


def printed_number(raw: str, total: int | None, slots: dict[str, int]) -> str:
    """The number as the card prints it.

    A Gem Pack card prints "0101/07" where the API says "01 01". A numbered
    card prints "001/128" where the API says "001". Anything else stays as the
    API gives it.
    """
    text = (raw or "").strip()
    parts = text.split()
    if len(parts) == 2 and all(p.isdigit() for p in parts) and parts[0] in slots:
        return f"{parts[0]}{parts[1]}/{slots[parts[0]]:02d}"
    if text.isdigit() and total:
        return f"{text}/{total:0{max(3, len(text))}d}"
    return text


# ----------------------------------------------------------------------- names


def qualifier(card: dict[str, Any]) -> str | None:
    if not card.get("is_variant"):
        return None
    variant = (card.get("variant") or "").strip().lower()
    if variant in PATTERN_QUALIFIERS:
        return PATTERN_QUALIFIERS[variant]
    return variant.replace("-", " ").title() or None


def printing(card: dict[str, Any]) -> str:
    variant = (card.get("variant") or "").strip().lower()
    if variant in PRINTINGS:
        return PRINTINGS[variant]
    # A pattern printing is foil. TCGplayer files its pattern cards as Holofoil.
    return "Holofoil"


def product_name(card: dict[str, Any]) -> str:
    base = card.get("name") or card.get("local_name") or "Unknown"
    q = qualifier(card)
    return f"{base} ({q})" if q else base


# ----------------------------------------------------------------------- fetch


class PikaQianError(RuntimeError):
    pass


def read_key() -> str:
    key = os.environ.get("PIKAQIAN_API_KEY", "").strip()
    if not key and KEY_FILE.exists():
        key = KEY_FILE.read_text().strip()
    if not key:
        raise PikaQianError(f"no PikaQian key: set PIKAQIAN_API_KEY or write it to {KEY_FILE}")
    return key


class Client:
    def __init__(self, key: str, log: Callable[[str], None] = print):
        self.key = key
        self.log = log
        self.requests = 0
        self.quota_remaining: str | None = None

    def get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        query = urllib.parse.urlencode({k: v for k, v in (params or {}).items() if v is not None})
        url = f"{API_URL}{path}" + (f"?{query}" if query else "")
        delay = 1.0
        last: Exception | None = None
        for attempt in range(1, RETRIES + 1):
            req = urllib.request.Request(
                url, headers={"X-API-Key": self.key, "User-Agent": USER_AGENT, "Accept": "application/json"}
            )
            try:
                self.requests += 1
                with urllib.request.urlopen(req, timeout=TIMEOUT_SECONDS, context=bc._SSL) as resp:
                    self.quota_remaining = resp.headers.get("x-ratelimit-quota-remaining", self.quota_remaining)
                    return json.load(resp)
            except urllib.error.HTTPError as err:
                last = err
                if err.code in (401, 403):
                    raise PikaQianError(f"{path}: HTTP {err.code}. Check the key and the plan.") from err
                if err.code == 404:
                    raise PikaQianError(f"{path}: HTTP 404") from err
                if err.code == 429:
                    retry_after = err.headers.get("Retry-After")
                    delay = max(delay, float(retry_after)) if retry_after and retry_after.isdigit() else delay
                elif err.code < 500:
                    raise PikaQianError(f"{path}: HTTP {err.code}") from err
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as err:
                last = err
            if attempt < RETRIES:
                time.sleep(delay)
                delay = min(delay * 2, 60)
        raise PikaQianError(f"{path}: gave up after {RETRIES} attempts: {last}")

    def paginate(self, path: str, params: dict[str, Any] | None = None) -> list[dict[str, Any]]:
        out: list[dict[str, Any]] = []
        cursor = None
        while True:
            body = self.get(path, {**(params or {}), "page_size": PAGE_SIZE, "cursor": cursor})
            out.extend(body.get("data") or [])
            cursor = (body.get("pagination") or {}).get("next_cursor")
            if not cursor:
                return out


@dataclass
class SetData:
    set: dict[str, Any]
    cards: list[dict[str, Any]]


def fetch_everything(client: Client, only: set[str] | None) -> list[SetData]:
    sets = client.paginate("/sets")
    client.log(f"PikaQian lists {len(sets)} sets")
    if only:
        missing = only - {s["id"] for s in sets}
        if missing:
            raise PikaQianError(f"unknown set ids: {', '.join(sorted(missing))}")
        sets = [s for s in sets if s["id"] in only]
    out = []
    for s in sets:
        cards = client.paginate("/cards", {"set_id": s["id"]})
        out.append(SetData(set=s, cards=cards))
        client.log(f"  {s['id']}: {len(cards)} cards")
    return out


# ----------------------------------------------------------------------- build


@dataclass
class Previous:
    product_ids: dict[str, int]
    group_ids: dict[str, int]
    art: dict[int, bytes]
    prices: dict[int, tuple]


def read_previous(path: Path) -> Previous:
    empty = Previous({}, {}, {}, {})
    if not path.exists():
        return empty
    conn = sqlite3.connect(path)
    try:
        prev = Previous(
            product_ids=dict(conn.execute("SELECT cardId, productId FROM pikaqianCard")),
            group_ids=dict(conn.execute("SELECT setId, groupId FROM pikaqianSet")),
            art=dict(conn.execute("SELECT productId, descriptor FROM productArt")),
            prices={row[0]: row for row in conn.execute("SELECT * FROM pikaqianPrice")},
        )
    except sqlite3.DatabaseError:
        return empty
    finally:
        conn.close()
    return prev


def fts_values(name: str, local: str | None, number: str, set_name: str, set_local: str | None, set_id: str) -> tuple[str, str, str]:
    """The name column carries both names, so he can search 小火马 or Ponyta."""
    name_text = f"{name} {local}" if local else name
    set_text = " ".join(part for part in (set_name, set_local, set_id.upper()) if part)
    return name_text, number, set_text


def build_sqlite(path: Path, data: list[SetData], previous: Previous, built_at: str, log: Callable[[str], None]) -> dict[str, Any]:
    if path.exists():
        path.unlink()
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode = DELETE")
    conn.executescript(bc.DDL)
    conn.executescript(EXTRA_DDL)
    conn.execute("INSERT INTO category VALUES (?, ?, ?)", (CATEGORY_ID, CATEGORY_NAME, CATEGORY_NAME))

    group_ids = assign_ids((sd.set["id"] for sd in data), previous.group_ids, base=GROUP_ID_BASE)
    product_ids = assign_ids((c["id"] for sd in data for c in sd.cards), previous.product_ids)
    source_date = built_at[:10]

    product_count = 0
    kept_art = 0
    kept_prices = 0
    for sd in data:
        s = sd.set
        gid = group_ids[s["id"]]
        set_name = s.get("name") or s.get("local_name") or s["id"].upper()
        conn.execute(
            "INSERT INTO cardSet VALUES (?, ?, ?, ?, ?)",
            (gid, CATEGORY_ID, set_name, s["id"].upper(), s.get("release_date")),
        )
        conn.execute("INSERT INTO pikaqianSet VALUES (?, ?)", (gid, s["id"]))

        total = set_total(sd.cards)
        slots = slot_totals(sd.cards)
        seen: set[str] = set()
        for c in sd.cards:
            if c["id"] in seen:
                continue
            seen.add(c["id"])
            pid = product_ids[c["id"]]
            number = printed_number(str(c.get("card_number") or ""), total, slots)
            parsed = bc.parse_number(number)
            name = product_name(c)
            conn.execute(
                "INSERT INTO product VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    pid, gid, CATEGORY_ID, name, bc.clean_name(name), c.get("image_url"),
                    number or None, parsed.numberNum, parsed.setTotal, parsed.setCode,
                    c.get("rarity_label"), c.get("card_type"), 0, 1,
                ),
            )
            local = c.get("local_name")
            if local:
                conn.execute("INSERT INTO productLocalName VALUES (?, ?)", (pid, local))
            conn.execute("INSERT INTO pikaqianCard VALUES (?, ?, ?)", (pid, c["id"], s["id"]))

            fts = fts_values(name, local, number, set_name, s.get("local_name"), s["id"])
            conn.execute("INSERT INTO ftsText VALUES (?, ?, ?, ?)", (pid, *fts))
            conn.execute("INSERT INTO product_fts(rowid, name, number, setName) VALUES (?,?,?,?)", (pid, *fts))
            conn.execute("INSERT INTO product_trigram(rowid, name, number) VALUES (?,?,?)", (pid, fts[0], fts[1]))

            old_price = previous.prices.get(pid)
            raw_cents = old_price[1] if old_price else None
            as_of = (old_price[3] or old_price[4])[:10] if old_price else source_date
            conn.execute(
                "INSERT INTO price VALUES (?,?,?,?,?,?,?,?)",
                (pid, printing(c), raw_cents, None, None, None, None, as_of),
            )
            if old_price:
                conn.execute("INSERT INTO pikaqianPrice VALUES (?,?,?,?,?)", old_price)
                kept_prices += 1
            if pid in previous.art:
                conn.execute("INSERT INTO productArt VALUES (?, ?)", (pid, previous.art[pid]))
                kept_art += 1
            product_count += 1
        log(f"  {s['id']}: {len(slots)} Gem Pack slots" if slots else f"  {s['id']}: printed total {total}")

    meta = {
        "schemaVersion": str(bc.SCHEMA_VERSION),
        "kind": KIND,
        "formatVersion": str(FORMAT_VERSION),
        "builtAt": built_at,
        "sourceDate": source_date,
        "productCount": str(product_count),
        "categories": json.dumps(
            [{"categoryId": CATEGORY_ID, "name": CATEGORY_NAME, "productCount": product_count}],
            separators=(",", ":"),
        ),
    }
    conn.executemany("INSERT INTO meta VALUES (?, ?)", meta.items())
    conn.commit()
    conn.execute("INSERT INTO product_fts(product_fts) VALUES('optimize')")
    conn.execute("INSERT INTO product_trigram(product_trigram) VALUES('optimize')")
    conn.commit()
    conn.execute("VACUUM")
    conn.close()
    return {"productCount": product_count, "keptArt": kept_art, "keptPrices": kept_prices}


# ----------------------------------------------------------------------- price


@dataclass
class Owned:
    product_id: int
    printing: str
    conditions: Counter
    quantity: int


def owned_chinese_cards(export: dict[str, Any], known_ids: set[int]) -> dict[int, Owned]:
    """The Chinese cards he still holds, by product. A sold card is not for sale."""
    out: dict[int, Owned] = {}
    for card in export.get("cards") or []:
        pid = card.get("productId") or 0
        if pid not in known_ids:
            continue
        tags = {t.strip().lower() for t in (card.get("tags") or [])}
        if card.get("statusRaw") == "sold" or "sold" in tags:
            continue
        quantity = max(1, int(card.get("quantity") or 1))
        entry = out.setdefault(pid, Owned(pid, card.get("printing") or "", Counter(), 0))
        entry.conditions[card.get("condition") or ""] += quantity
        entry.quantity += quantity
    return out


def price_summary(body: dict[str, Any]) -> tuple[int | None, int | None, str | None]:
    """(raw cents, sales in the last 7 days, updated_at) from /cards/{id}/prices."""
    raw = ((body.get("grades") or {}).get("raw") or {}).get("price_cents")
    return raw, body.get("recent_sale_count"), body.get("updated_at")


def report_rows(conn: sqlite3.Connection, owned: dict[int, Owned]) -> list[dict[str, Any]]:
    rows = []
    for pid, entry in owned.items():
        r = conn.execute(
            """
            SELECT p.name, l.localName, s.name, s.abbreviation, p.number, p.rarity,
                   pp.rawCents, pp.recentSaleCount, pp.updatedAt, c.cardId
            FROM product p JOIN cardSet s ON s.groupId = p.groupId
            LEFT JOIN productLocalName l ON l.productId = p.productId
            LEFT JOIN pikaqianPrice pp ON pp.productId = p.productId
            LEFT JOIN pikaqianCard c ON c.productId = p.productId
            WHERE p.productId = ?
            """,
            (pid,),
        ).fetchone()
        if not r:
            continue
        raw = r[6]
        rows.append({
            "name": r[0],
            "chineseName": r[1] or "",
            "set": r[2],
            "setCode": r[3],
            "number": r[4] or "",
            "rarity": r[5] or "",
            "owned": entry.quantity,
            "conditions": "; ".join(f"{k or '?'} x{v}" for k, v in sorted(entry.conditions.items())),
            "rawPrice": f"{raw / 100:.2f}" if raw is not None else "",
            "ownedValue": f"{raw * entry.quantity / 100:.2f}" if raw is not None else "",
            "salesLast7Days": r[7] if r[7] is not None else "",
            "priceUpdated": (r[8] or "")[:10],
            "productId": pid,
            "pikaqianCardId": r[9] or "",
        })
    rows.sort(key=lambda row: (row["rawPrice"] == "", -(float(row["rawPrice"]) if row["rawPrice"] else 0), row["name"]))
    return rows


def price(catalog: Path, export_path: Path, report: Path, client: Client, fetched_at: str) -> dict[str, Any]:
    export = json.loads(export_path.read_text())
    conn = sqlite3.connect(catalog)
    try:
        card_ids = dict(conn.execute("SELECT productId, cardId FROM pikaqianCard"))
        owned = owned_chinese_cards(export, set(card_ids))
        client.log(f"{len(owned)} Chinese products held, {sum(o.quantity for o in owned.values())} cards")
        priced = 0
        for index, pid in enumerate(sorted(owned), start=1):
            body = client.get(f"/cards/{card_ids[pid]}/prices")
            raw, sales, updated = price_summary(body)
            conn.execute("INSERT OR REPLACE INTO pikaqianPrice VALUES (?,?,?,?,?)", (pid, raw, sales, updated, fetched_at))
            conn.execute(
                "UPDATE price SET marketPriceCents = ?, asOf = ? WHERE productId = ?",
                (raw, (updated or fetched_at)[:10], pid),
            )
            if raw is not None:
                priced += 1
            if index % 50 == 0:
                conn.commit()
                client.log(f"  priced {index} of {len(owned)}")
        conn.execute(
            "INSERT INTO meta VALUES ('pricedAt', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (fetched_at,),
        )
        conn.commit()
        rows = report_rows(conn, owned)
    finally:
        conn.close()

    report.parent.mkdir(parents=True, exist_ok=True)
    fields = ["name", "chineseName", "set", "setCode", "number", "rarity", "owned", "conditions",
              "rawPrice", "ownedValue", "salesLast7Days", "priceUpdated", "productId", "pikaqianCardId"]
    with report.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    return {"products": len(owned), "priced": priced, "report": str(report)}


# ------------------------------------------------------------------------ main


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="command", required=True)

    b = sub.add_parser("build", help="fetch every set and card")
    b.add_argument("--out", default="build/chinese", help="output directory")
    b.add_argument("--sets", default="", help="comma-separated set ids, for a quick test build")

    p = sub.add_parser("price", help="price the Chinese cards in a collection export")
    p.add_argument("--catalog", default=f"build/chinese/{FILE_NAME}")
    p.add_argument("--export", required=True, help="the app's collection export (JSON)")
    p.add_argument("--report", default="build/chinese/chinese-prices.csv")

    args = ap.parse_args(argv)
    try:
        client = Client(read_key())
    except PikaQianError as err:
        print(err, file=sys.stderr)
        return 2
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    started = time.monotonic()

    try:
        if args.command == "build":
            out = Path(args.out)
            out.mkdir(parents=True, exist_ok=True)
            final = out / FILE_NAME
            previous = read_previous(final)
            only = {s.strip() for s in args.sets.split(",") if s.strip()} or None
            data = fetch_everything(client, only)
            if not data or not any(sd.cards for sd in data):
                print("PikaQian returned no cards. Nothing written.", file=sys.stderr)
                return 1
            staging = out / (FILE_NAME + ".new")
            summary = build_sqlite(staging, data, previous, now, client.log)
            shutil.move(staging, final)
            client.log(
                f"wrote {summary['productCount']} products to {final} "
                f"(kept {summary['keptArt']} signatures, {summary['keptPrices']} prices); "
                f"{client.requests} requests, quota left {client.quota_remaining}, "
                f"{time.monotonic() - started:.0f}s"
            )
        else:
            catalog = Path(args.catalog)
            if not catalog.exists():
                print(f"no catalog at {catalog}. Run build first.", file=sys.stderr)
                return 1
            summary = price(catalog, Path(args.export), Path(args.report), client, now)
            client.log(
                f"priced {summary['priced']} of {summary['products']} products; report {summary['report']}; "
                f"{client.requests} requests, quota left {client.quota_remaining}"
            )
    except PikaQianError as err:
        print(err, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
