#!/usr/bin/env python3
"""Convert the BinderBooks ledger into a Card Tracker collection file.

The app already imports `cardtracker-collection` files, so this script writes
one and the app's own importer loads it. See docs/04-seed-import.md.

This is a one-off. The app holds no BinderBooks-specific code.

Two rules shape the output:

  Money always imports. A purchase, a grading charge, a rip, and a sale are
  records of real money and do not need a catalog identity.

  A card that the catalog cannot identify is held back. The collection store
  references the catalog by productId alone, so a card without one is not a
  card. Held-back rows go to the report. Put their product ids in an overrides
  file and run again; the ids this script derives are stable, so the second
  import adds the cards and links the sale lines that waited for them.

Standard library only, like catalog/build_catalog.py.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "catalog"))
from build_catalog import clean_name, parse_number  # noqa: E402

FORMAT = "cardtracker-collection"
VERSION = 4

# Fixed, so a second run derives the same ids and the import upserts instead of
# duplicating. Never change it.
NAMESPACE = uuid.UUID("6f9f4e1c-6a2f-5c4b-9d7e-2b1a8c3d4e5f")

# Seconds from the Unix epoch to Foundation's reference date, 2001-01-01 UTC.
# Swift's JSONDecoder reads a bare number as seconds since that date.
REFERENCE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc).timestamp()

POKEMON_JAPAN = 85
ENGLISH_CATEGORIES = (3, 63, 81)  # Pokemon, Digimon Card Game, Union Arena

# docs/04: BinderBooks allocated rip cost by market value. Record what happened.
HISTORICAL_ALLOCATION = "byMarketValue"

# The reserved labels in ios/Sources/Inventory/CardTags.swift. "Kept" is the
# default BinderBooks applied to everything not sold or listed, so it maps to
# `owned` and carries no label. It does NOT mean personal collection.
STATUS_MAP = {
    "Sold": ("sold", "sold"),
    "Listed": ("listed", "listed"),
    "At grading": ("atGrader", "at grader"),
    "Kept": ("owned", None),
}

# ios/Sources/Inventory/CardTags.swift: sending a card to a named grader
# writes that grader's own label, so the app can show a value range while a
# card is out ("at PSA" / "at CGC"). An unknown grader keeps the old generic
# label, which reads but earns no range.
ATGRADER_TAG = {"psa": "at PSA", "cgc": "at CGC"}


def parse_grade(grade: str) -> tuple[str | None, str | None]:
    """"CGC 10 Pristine" -> ("cgc", "Pristine 10"). "PSA 9" -> ("psa", "9").

    The label is reordered to match `OwnedCard.gradeLabel`'s own convention
    (the word before the number, "Pristine 10") — BinderBooks wrote the
    number first, and the two disagreeing would read as two different grades
    to anything that parses the number back out of the string.
    """
    if grade == "Raw":
        return None, None
    tokens = grade.split()
    grader = tokens[0].lower()
    rest = [t for t in tokens[1:] if t.lower() != "pristine"]
    label = "Pristine " + " ".join(rest) if len(rest) != len(tokens) - 1 else " ".join(rest)
    return grader, (label or None)


CHANNEL_MAP = {
    "TCGplayer": "tcgplayer",
    "eBay": "ebay",
    "Whatnot": "whatnot",
    "LGS consignment": "local",
    "In-person": "local",
    "Other": "other",
}


# --- primitives ---------------------------------------------------------------


def ident(kind: str, source_id: str) -> str:
    """The stable UUID for one source row."""
    return str(uuid.uuid5(NAMESPACE, f"binderbooks:{kind}:{source_id}")).upper()


def cents(value: Any) -> int:
    """Dollars to Int cents, through Decimal.

    Every money literal in the ledger carries two decimal places or fewer, so
    `Decimal(str(value))` is exact. No float reaches the output.
    """
    if value in (None, ""):
        return 0
    return int((Decimal(str(value)) * 100).to_integral_value())


def when(day: str | None) -> float:
    """A "YYYY-MM-DD" day as Foundation's time interval.

    Noon UTC, not midnight: midnight lands on the previous calendar day for
    every timezone west of Greenwich, and he reads these dates in Denver.
    """
    if not day:
        day = "1970-01-01"
    stamp = datetime.strptime(day, "%Y-%m-%d").replace(hour=12, tzinfo=timezone.utc)
    return stamp.timestamp() - REFERENCE_EPOCH


# --- catalog matching ---------------------------------------------------------


class Catalog:
    def __init__(self, path: Path):
        self.db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        self.db.row_factory = sqlite3.Row
        rows = list(self.db.execute("SELECT groupId, categoryId, name FROM cardSet"))
        self._sets: dict[int, str] = {r["groupId"]: clean_name(r["name"]) for r in rows}
        self._set_categories: dict[int, int] = {r["groupId"]: r["categoryId"] for r in rows}

    def categories_for(self, lang: str | None) -> tuple[int, ...]:
        return (POKEMON_JAPAN,) if (lang or "en").lower() in ("jp", "ja") else ENGLISH_CATEGORIES

    def exists(self, product_id: int) -> bool:
        return self.db.execute("SELECT 1 FROM product WHERE productId = ?", (product_id,)).fetchone() is not None

    def by_number(self, number: str | None, categories: tuple[int, ...]) -> list[sqlite3.Row]:
        """Candidates for a collector number.

        The denominator carries the set, so `numberNum` plus `setTotal` is close
        to a unique key. Most of his older rows record only the numerator, so
        `numberNum` alone is the fallback and the set name does the narrowing.
        """
        parsed = parse_number(number)
        marks = ",".join("?" * len(categories))
        if parsed.numberNum is not None and parsed.setTotal is not None:
            sql = f"SELECT * FROM product WHERE numberNum = ? AND setTotal = ? AND categoryId IN ({marks})"
            args: tuple = (parsed.numberNum, parsed.setTotal, *categories)
        elif parsed.setCode and parsed.numberNum is not None:
            sql = f"SELECT * FROM product WHERE setCode = ? AND numberNum = ? AND categoryId IN ({marks})"
            args = (parsed.setCode, parsed.numberNum, *categories)
        elif parsed.numberNum is not None:
            sql = f"SELECT * FROM product WHERE numberNum = ? AND categoryId IN ({marks})"
            args = (parsed.numberNum, *categories)
        elif number:
            sql = f"SELECT * FROM product WHERE number = ? COLLATE NOCASE AND categoryId IN ({marks})"
            args = (number, *categories)
        else:
            return []
        return list(self.db.execute(sql, args))

    def by_name(self, name: str, categories: tuple[int, ...]) -> list[sqlite3.Row]:
        marks = ",".join("?" * len(categories))
        sql = f"SELECT * FROM product WHERE cleanName = ? AND categoryId IN ({marks})"
        return list(self.db.execute(sql, (clean_name(name), *categories)))

    def groups_named(self, set_name: str | None, categories: tuple[int, ...]) -> set[int] | None:
        """The catalog set ids the ledger's set name points at, or None when the
        name points at nothing.

        The catalog prefixes a set name ("SV: Prismatic Evolutions") and the
        ledger does not, so this contains rather than equals. None and the empty
        set mean different things: None says the name is unknown, so the caller
        must not narrow on it.
        """
        if not set_name:
            return None
        wanted = clean_name(set_name)
        if not wanted:
            return None
        found = {
            group
            for group, name in self._sets.items()
            if wanted in name and self._set_categories.get(group) in categories
        }
        return found or None

    def printings(self, product_id: int) -> list[tuple[str, int]]:
        rows = self.db.execute(
            "SELECT subTypeName, COALESCE(marketPriceCents, 0) AS m FROM price WHERE productId = ? ORDER BY m DESC",
            (product_id,),
        )
        return [(r["subTypeName"], r["m"]) for r in rows]


class Match:
    def __init__(self, product_id: int, confidence: str, reason: str):
        self.product_id = product_id
        self.confidence = confidence
        self.reason = reason


def match_card(catalog: Catalog, row: dict, overrides: dict[str, Any]) -> Match | tuple[None, str]:
    source_id = row.get("id", "")
    if source_id in overrides:
        return Match(int(overrides[source_id]), "manual", "override")

    raw = row.get("productId")
    if raw not in (None, "", 0):
        product_id = int(raw)
        if catalog.exists(product_id):
            return Match(product_id, "certain", "productId in the export")
        return None, f"the export's productId {product_id} is not in the catalog"

    categories = catalog.categories_for(row.get("lang"))
    name = row.get("name")
    set_name = row.get("set")
    groups = catalog.groups_named(set_name, categories)

    def in_set(rows: list) -> list:
        """Keep only the rows in the named set. A set the catalog does not know
        narrows nothing, because dropping every candidate would hold back a card
        the number alone identifies."""
        return [r for r in rows if r["groupId"] in groups] if groups else rows

    def named(rows: list) -> list:
        """The name decides between candidates that share a number. It never
        rescues a card whose name matches nothing: two disagreeing signals must
        ask, not assert."""
        if not name or len(rows) < 2:
            return rows
        wanted = clean_name(name)
        exact = [r for r in rows if r["cleanName"] == wanted]
        return exact if exact else rows

    numbered = named(in_set(catalog.by_number(row.get("number"), categories)))
    if len(numbered) == 1:
        agreed = clean_name(name or "") == numbered[0]["cleanName"]
        return Match(numbered[0]["productId"], "certain" if agreed else "likely", "number and set")

    if name:
        by_name = in_set(catalog.by_name(name, categories))
        if len(by_name) == 1:
            return Match(by_name[0]["productId"], "likely", "name and set")
        if len(numbered) > 1:
            return None, f"{len(numbered)} products share number {row.get('number')} in {set_name}"
        if len(by_name) > 1:
            return None, f"{len(by_name)} products are named {name} in {set_name}"

    if len(numbered) > 1:
        return None, f"{len(numbered)} products share number {row.get('number')} in {set_name}"
    if set_name and groups is None:
        return None, f"the catalog has no set named {set_name}"
    return None, "no product matches the name or the number"


def choose_printing(catalog: Catalog, product_id: int, variant: str | None) -> tuple[str, bool]:
    """The printing, and whether the choice was a guess."""
    printings = catalog.printings(product_id)
    names = [p[0] for p in printings]
    if variant:
        for candidate in names:
            if candidate.lower() == variant.lower():
                return candidate, False
        return variant, False
    if len(names) == 1:
        return names[0], False
    if not names:
        return "Normal", True
    return names[0], True


# --- conversion ---------------------------------------------------------------


class Converter:
    def __init__(self, seed: dict, catalog: Catalog, overrides: dict[str, Any]):
        self.seed = seed
        self.catalog = catalog
        self.overrides = overrides

        self.purchases: list[dict] = []
        self.purchase_items: list[dict] = []
        self.cards: list[dict] = []
        self.grading: list[dict] = []
        self.sales: list[dict] = []
        self.sale_lines: list[dict] = []

        self.held_back: list[dict] = []
        self.faults: dict[str, list] = {}

    def note(self, kind: str, detail: Any) -> None:
        self.faults.setdefault(kind, []).append(detail)

    # -- buys

    def convert_buys(self) -> None:
        for buy in self.seed["buys"]:
            if buy["category"] == "Grading":
                self.grading.append(
                    {
                        "id": ident("grading", buy["id"]),
                        "graderRaw": buy["source"],
                        "submissionNumber": "",
                        "serviceLevel": "",
                        "declaredValueCents": 0,
                        "shippedAt": when(buy["date"]),
                        "returnedAt": None,
                        "gradingFeesCents": cents(buy["cost"]),
                        "shipToGraderCents": 0,
                        "shipReturnCents": 0,
                        "insuranceCents": 0,
                        "sourceRef": buy["id"],
                    }
                )
                # docs/04: the charge names a card count and no cards. Joining
                # it by grader and date would be a guess, and a wrong join is
                # hard to see later. Each card keeps its own grading cost.
                self.note("grading_without_entries", {"id": buy["id"], "item": buy["item"]})
                continue

            note = buy["item"]
            if buy.get("name"):
                note = f"{buy['name']} — {note}"
            self.purchases.append(
                {
                    "id": ident("buy", buy["id"]),
                    "date": when(buy["date"]),
                    "vendor": buy["source"],
                    "note": note,
                    "receiptImageData": None,
                    "itemCostCents": cents(buy["cost"]),
                    "shippingCents": 0,
                    "taxCents": 0,
                    "feesCents": 0,
                    "allocationMethodRaw": HISTORICAL_ALLOCATION,
                    "sourceRef": buy["id"],
                }
            )
            if buy.get("seed"):
                self.note("seed_row", {"array": "buys", "id": buy["id"], "item": buy["item"]})

    # -- rips

    def convert_rips(self) -> None:
        """A rip becomes one sealed line on its purchase, and nothing else.

        There is no `RipEvent`. The sealed `PurchaseItem` is the pack: it holds
        what the pack cost and the cards that came out of it. Recording the
        opening as its own row added a date and nothing he reads.
        """
        buys = {b["id"]: b for b in self.seed["buys"]}
        for rip in self.seed["rips"]:
            buy = buys.get(rip["buyId"])
            if buy is None:
                self.note("rip_without_buy", {"id": rip["id"], "buyId": rip["buyId"]})
                continue

            item_id = ident("sealed", rip["id"])
            # The sealed product has no catalog id in the ledger, only a typed
            # name. productId 0 is the store's "not identified yet".
            self.purchase_items.append(
                {
                    "id": item_id,
                    "productId": 0,
                    "quantity": max(int(rip.get("packs") or 1), 1),
                    "isSealed": True,
                    "allocatedCostCents": cents(buy["cost"]),
                    "purchaseId": ident("buy", buy["id"]),
                    "parentItemId": None,
                    "identifiedGroupId": None,
                    "isRipped": True,
                }
            )
            self.note("sealed_without_product", {"id": rip["id"], "product": rip["product"]})
            if rip["date"] < buy["date"]:
                # docs/04: real, and not an error. Do not reorder on it.
                self.note("rip_before_buy", {"rip": rip["id"], "ripDate": rip["date"], "buy": buy["id"], "buyDate": buy["date"]})

    # -- inventory

    def convert_inventory(self) -> None:
        rip_of_hit: dict[str, dict] = {}
        for rip in self.seed["rips"]:
            for hit in rip["hits"]:
                rip_of_hit[hit["id"]] = rip
        claimed: set[str] = set()

        for row in self.seed["inventory"]:
            source_id = row["id"]
            hit_id = row.get("hitId")
            if hit_id:
                # Claim the hit before the match decides anything. A held-back
                # card is still the row that accounts for its hit, and counting
                # it as an orphan would report a fault that is not there.
                if hit_id in rip_of_hit:
                    claimed.add(hit_id)
                else:
                    self.note("hit_id_without_hit", {"id": source_id, "hitId": hit_id, "name": row.get("name")})
            outcome = match_card(self.catalog, row, self.overrides)
            if isinstance(outcome, tuple):
                _, reason = outcome
                self.held_back.append(
                    {
                        "id": source_id,
                        "name": row.get("name"),
                        "set": row.get("set"),
                        "number": row.get("number"),
                        "lang": row.get("lang"),
                        "status": row.get("status"),
                        "costCents": cents(row.get("cost")),
                        "valueCents": cents(row.get("value")),
                        "reason": reason,
                    }
                )
                continue

            printing, guessed = choose_printing(self.catalog, outcome.product_id, row.get("variant"))
            confidence = "uncertain" if guessed else outcome.confidence

            status_raw, tag = STATUS_MAP.get(row.get("status", "Kept"), ("owned", None))
            tags = [tag] if tag else []

            grade = row.get("grade") or "Raw"
            grader_from_grade, grade_label = parse_grade(grade)
            # A card out for grading names its grader while still raw, so read
            # that field first and fall back to the one the grade string carries.
            explicit_grader = (row.get("grader") or "").lower() or None
            grader = explicit_grader or grader_from_grade
            if grade != "Raw" and "graded" not in tags:
                tags.append("graded")
            if tag == "at grader" and grader in ATGRADER_TAG:
                tags[tags.index(tag)] = ATGRADER_TAG[grader]
            if row.get("seed"):
                tags.append("seed")

            # Speculative grades for a card already at a named grader carry no
            # grader of their own ("8", "9"), so a range for "if PSA grades
            # it" would match nothing. Prefixing them is safe only here: a
            # card with no destination grader keeps bare keys, which is the
            # documented behavior for a figure that names no company.
            comps = row.get("gradeEst") or {}
            if grader in ATGRADER_TAG and comps:
                comps = {f"{grader.upper()} {k}": v for k, v in comps.items()}

            rip = rip_of_hit.get(hit_id or "")

            self.cards.append(
                {
                    "id": ident("inv", source_id),
                    "productId": outcome.product_id,
                    "skuId": None,
                    "printing": printing,
                    "condition": "Near Mint",
                    "language": "ja" if (row.get("lang") or "en").lower() in ("jp", "ja") else "en",
                    "quantity": 1,
                    "acquiredAt": when(row.get("date")),
                    "statusRaw": status_raw,
                    "acquisitionBasisCents": cents(row.get("cost")),
                    "gradingBasisCents": cents(row.get("gradingCost")) + cents(row.get("gradingShip")),
                    # docs/04: costAuto true means BinderBooks derived the basis
                    # by market value. Absent means he typed a real price.
                    "basisIsAllocated": bool(row.get("costAuto")),
                    "basisIsManual": not bool(row.get("costAuto")),
                    "isBulk": False,
                    "isPersonalCollection": False,
                    "sourceItemId": ident("sealed", rip["id"]) if rip else None,
                    "scanSessionId": None,
                    "matchConfidenceRaw": confidence,
                    "certNumber": None,
                    "graderRaw": grader,
                    "gradeLabel": grade_label,
                    "ocrName": None,
                    "ocrNumber": None,
                    "candidateProductIds": [],
                    "scannedAt": when(row.get("date")),
                    "gradedCompCents": {k: cents(v) for k, v in comps.items()},
                    "sourceRef": source_id,
                    "tags": tags,
                }
            )

        for hit_id, rip in rip_of_hit.items():
            if hit_id not in claimed:
                self.note("hit_without_inventory", {"hitId": hit_id, "rip": rip["id"]})

    # -- sales

    def convert_sales(self) -> None:
        kept = {c["sourceRef"] for c in self.cards}
        inventory = {row["id"] for row in self.seed["inventory"]}
        sold_by_a_sale: set[str] = set()

        for sale in self.seed["sales"]:
            self.sales.append(
                {
                    "id": ident("sale", sale["id"]),
                    "soldAt": when(sale["date"]),
                    "channelRaw": CHANNEL_MAP.get(sale["channel"], sale["channel"].lower()),
                    "grossCents": cents(sale.get("price")),
                    "marketplaceFeesCents": cents(sale.get("fees")) + cents(sale.get("consign")),
                    "salesTaxCents": cents(sale.get("tax")),
                    "shippingChargedCents": 0,
                    "shippingCostCents": cents(sale.get("shipping")),
                    "otherFeesCents": 0,
                    # The export dropped the order number. See docs/04.
                    "externalOrderId": "",
                    "sourceRef": sale["id"],
                }
            )
            if sale.get("seed"):
                self.note("seed_row", {"array": "sales", "id": sale["id"], "channel": sale["channel"]})
            if not sale["cards"]:
                # docs/04: about 30 May-June orders carry a price and no lines.
                # The revenue is real; the attribution does not exist.
                self.note("sale_without_lines", {"id": sale["id"], "date": sale["date"], "priceCents": cents(sale.get("price"))})

            for index, line in enumerate(sale["cards"]):
                inv_id = line.get("invId")
                if inv_id:
                    sold_by_a_sale.add(inv_id)
                    if inv_id not in inventory:
                        self.note("sale_line_without_card", {"sale": sale["id"], "invId": inv_id, "name": line.get("name")})
                basis = cents(line.get("basis"))
                linked = bool(inv_id) and inv_id in kept
                self.sale_lines.append(
                    {
                        "id": ident("saleline", f"{sale['id']}:{index}"),
                        "saleId": ident("sale", sale["id"]),
                        "cardId": ident("inv", inv_id) if linked else None,
                        "sealedItemId": None,
                        "basisCents": basis,
                        # docs/04: import the revenue and leave the cost unknown
                        # rather than recording a fictitious 100% margin.
                        "basisIncomplete": basis == 0,
                        "describedAs": line.get("name") or "",
                        "sourceRef": f"{sale['id']}:{index}",
                    }
                )

        for row in self.seed["inventory"]:
            if row["status"] == "Sold" and row["id"] not in sold_by_a_sale:
                self.note("sold_without_sale", {"id": row["id"], "name": row.get("name"), "costCents": cents(row.get("cost"))})

    # -- output

    def run(self) -> None:
        self.convert_buys()
        self.convert_rips()
        self.convert_inventory()
        self.convert_sales()

    def file(self, exported_at: str) -> dict:
        by_id = lambda rows: sorted(rows, key=lambda r: r["id"])  # noqa: E731
        return {
            "format": FORMAT,
            "version": VERSION,
            "exportedAt": exported_at,
            "purchases": by_id(self.purchases),
            "purchaseItems": by_id(self.purchase_items),
            "cards": by_id(self.cards),
            "sessions": [],
            "grading": by_id(self.grading),
            "gradingEntries": [],
            "sales": by_id(self.sales),
            "saleLines": by_id(self.sale_lines),
        }

    def report(self) -> dict:
        held_value = sum(r["costCents"] for r in self.held_back)
        return {
            "wrote": {
                "purchases": len(self.purchases),
                "purchaseItems": len(self.purchase_items),
                "cards": len(self.cards),
                "grading": len(self.grading),
                "sales": len(self.sales),
                "saleLines": len(self.sale_lines),
            },
            "heldBack": {
                "count": len(self.held_back),
                "basisCentsHeldBack": held_value,
                "rows": sorted(self.held_back, key=lambda r: -r["costCents"]),
            },
            "faults": {k: {"count": len(v), "rows": v} for k, v in sorted(self.faults.items())},
        }


# --- entry point --------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", type=Path, default=Path("seed/binderbooks-export.json"))
    parser.add_argument("--catalog", type=Path, required=True, help="catalog.sqlite, from the catalog-latest release")
    parser.add_argument("--out", type=Path, default=Path("seed/binderbooks-collection.json"))
    parser.add_argument("--report", type=Path, default=Path("seed/import-report.json"))
    parser.add_argument("--overrides", type=Path, default=None, help="JSON object of BinderBooks id -> productId")
    parser.add_argument("--exported-at", default="2026-09-05T00:00:00Z", help="fixed, so two runs write the same bytes")
    args = parser.parse_args(argv)

    seed = json.loads(args.seed.read_text())
    overrides = json.loads(args.overrides.read_text()) if args.overrides and args.overrides.exists() else {}

    converter = Converter(seed, Catalog(args.catalog), overrides)
    converter.run()

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(converter.file(args.exported_at), indent=2, sort_keys=True) + "\n")
    args.report.write_text(json.dumps(converter.report(), indent=2, sort_keys=True) + "\n")

    report = converter.report()
    print(f"wrote {args.out}")
    for key, value in report["wrote"].items():
        print(f"  {key:16} {value}")
    print(f"held back {report['heldBack']['count']} cards, ${report['heldBack']['basisCentsHeldBack'] / 100:,.2f} of basis")
    for kind, detail in report["faults"].items():
        print(f"  {kind:28} {detail['count']}")
    print(f"see {args.report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
