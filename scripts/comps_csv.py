#!/usr/bin/env python3
"""Edit graded comps in a spreadsheet instead of on the phone.

Typing a comp into an iOS text field is slow, and the figures come from a
browser on the Mac. This script takes a `cardtracker-collection` export,
writes the cards that need comps to a CSV, and writes the filled CSV back
into a new export file. The app's own importer loads the result in merge
mode, so nothing else in the collection changes.

  ./comps_csv.py extract collection.json comps.csv
  # fill the price columns in Numbers or Excel, save as CSV
  ./comps_csv.py apply collection.json comps.csv collection-priced.json
  # AirDrop the new file, then Settings -> Import collection -> Merge

Three rules protect the store:

  It writes `gradedCompCents` and nothing else. That field holds what AJ
  typed, and the app already prefers it over `fetchedCompCents`, so a later
  fetch from any price source can never overwrite these figures.

  An empty cell leaves the existing figure alone. Only the word `clear`
  removes one. The app's importer reads a missing key as "wipe this card's
  comps", so a blank column must never reach it as a deletion.

  It never writes over its input, and it matches cards by id, never by
  name. A renamed or re-scanned card still lands on the right row.

The CSV carries prices in dollars, because that is what a spreadsheet and a
sales page both show. The JSON carries cents, which is what the app stores.

Standard library only, like catalog/build_catalog.py.
"""

from __future__ import annotations

import argparse
import csv
import json
import sqlite3
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_CATALOG = ROOT / "scripts" / "catalog.sqlite"

FORMAT = "cardtracker-collection"
MAX_VERSION = 9

# The grade ladder the app shows. `GradedComps.swift` owns the spelling; a key
# that does not match one of these still imports, but it lands in the "others"
# block of the card page rather than on a named row.
PSA_GRADES = ["PSA 10", "PSA 9", "PSA 8"]
CGC_GRADES = ["CGC Pristine 10", "CGC 10", "CGC 9", "CGC 8"]
ALL_GRADES = PSA_GRADES + CGC_GRADES

# The default is the one figure PPT structurally cannot supply: it files CGC
# Pristine 10 sales under `cgc10`, so this row is empty on every card.
DEFAULT_GRADES = ["CGC Pristine 10"]

FIXED_COLUMNS = ["cardId", "name", "set", "number", "grader", "grade", "condition", "printing", "quantity"]
FETCHED_PREFIX = "fetched: "
CLEAR = "clear"


class Problem(Exception):
    """A message for AJ, not a stack trace."""


# ---------------------------------------------------------------- the file


def load_export(path: Path) -> dict:
    """Read an export and refuse anything this script does not understand."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise Problem(f"cannot read {path}: {error}") from error
    try:
        file = json.loads(text)
    except json.JSONDecodeError as error:
        raise Problem(f"{path} is not valid JSON: {error}") from error
    if not isinstance(file, dict):
        raise Problem(f"{path} is not a collection export")
    if file.get("format") != FORMAT:
        raise Problem(f"{path} has format {file.get('format')!r}, expected {FORMAT!r}")
    version = file.get("version")
    if not isinstance(version, int) or version > MAX_VERSION:
        raise Problem(f"{path} is version {version}, and this script knows up to {MAX_VERSION}")
    if not isinstance(file.get("cards"), list):
        raise Problem(f"{path} holds no cards array")
    return file


def catalog_names(card_ids: list[int], catalog: Path | None) -> dict[int, tuple[str, str, str]]:
    """productId -> (name, set, number), so the CSV reads like a binder page.

    The catalog is a convenience, not a requirement. Without it the CSV still
    identifies every card by id, and by whatever the card carries itself.
    """
    if catalog is None or not catalog.exists() or not card_ids:
        return {}
    try:
        db = sqlite3.connect(f"file:{catalog}?mode=ro", uri=True)
    except sqlite3.Error:
        return {}
    try:
        out: dict[int, tuple[str, str, str]] = {}
        # Chunked, because SQLite caps the number of bound variables.
        ids = sorted(set(card_ids))
        for start in range(0, len(ids), 500):
            chunk = ids[start : start + 500]
            marks = ",".join("?" * len(chunk))
            rows = db.execute(
                f"SELECT p.productId, p.name, s.name, COALESCE(p.number, '') "
                f"FROM product p JOIN cardSet s USING (groupId) WHERE p.productId IN ({marks})",
                chunk,
            )
            for product_id, name, set_name, number in rows:
                out[product_id] = (name, set_name, number)
        return out
    except sqlite3.Error:
        return {}
    finally:
        db.close()


# ---------------------------------------------------------------- money


def dollars(cents: int) -> str:
    """Cents to a plain decimal string. No currency sign, so a spreadsheet
    reads the column as a number rather than as text."""
    return f"{Decimal(cents) / 100:.2f}"


def cents(text: str, where: str) -> int:
    """A typed price to cents. Accepts "125", "125.00", "$125.00", "1,250"."""
    cleaned = text.strip().lstrip("$").replace(",", "").replace("_", "")
    try:
        value = Decimal(cleaned)
    except (InvalidOperation, ValueError) as error:
        raise Problem(f"{where}: {text!r} is not a price") from error
    if value < 0:
        raise Problem(f"{where}: {text!r} is negative")
    return int((value * 100).quantize(Decimal(1)))


# ---------------------------------------------------------------- selection


def is_pristine(card: dict) -> bool:
    return "pristine" in (card.get("gradeLabel") or "").lower()


def is_graded(card: dict) -> bool:
    return bool((card.get("graderRaw") or "").strip())


def select(cards: list[dict], only: str) -> list[dict]:
    if only == "all":
        return list(cards)
    if only == "pristine":
        return [c for c in cards if is_pristine(c)]
    return [c for c in cards if is_graded(c)]


def sort_key(card: dict, names: dict[int, tuple[str, str, str]]) -> tuple:
    name, set_name, number = describe(card, names)
    return (set_name.lower(), number, name.lower(), str(card.get("id")))


def describe(card: dict, names: dict[int, tuple[str, str, str]]) -> tuple[str, str, str]:
    """The card's name, set, and number. A hand-entered card carries its own;
    a catalog card borrows the catalog's."""
    manual_name = (card.get("manualName") or "").strip()
    manual_set = (card.get("manualSetName") or "").strip()
    manual_number = (card.get("manualNumber") or "").strip()
    name, set_name, number = names.get(card.get("productId"), ("", "", ""))
    return (manual_name or name, manual_set or set_name, manual_number or number)


# ---------------------------------------------------------------- extract


def extract(export: Path, out_csv: Path, grades: list[str], only: str, catalog: Path | None) -> str:
    file = load_export(export)
    cards = select(file["cards"], only)
    if not cards:
        raise Problem(f"no cards matched --only {only}")

    names = catalog_names([c.get("productId") for c in cards if isinstance(c.get("productId"), int)], catalog)
    cards.sort(key=lambda c: sort_key(c, names))

    header = FIXED_COLUMNS + grades + [FETCHED_PREFIX + g for g in grades]
    with out_csv.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        for card in cards:
            name, set_name, number = describe(card, names)
            typed = card.get("gradedCompCents") or {}
            fetched = card.get("fetchedCompCents") or {}
            row = [
                card.get("id", ""),
                name,
                set_name,
                number,
                (card.get("graderRaw") or "").upper(),
                card.get("gradeLabel") or "",
                card.get("condition", ""),
                card.get("printing", ""),
                card.get("quantity", 1),
            ]
            row += [dollars(typed[g]) if g in typed else "" for g in grades]
            row += [dollars(fetched[g]) if g in fetched else "" for g in grades]
            writer.writerow(row)

    blank = sum(1 for c in cards for g in grades if g not in (c.get("gradedCompCents") or {}))
    return (
        f"Wrote {len(cards)} cards to {out_csv}.\n"
        f"{blank} of {len(cards) * len(grades)} price cells are empty.\n"
        f"Fill the {', '.join(grades)} column(s) in dollars. Leave a cell empty to keep what is there.\n"
        f"The 'fetched:' columns are what the price source last said. They are read-only and apply ignores them."
    )


# ---------------------------------------------------------------- apply


def read_rows(path: Path, grades: list[str]) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError as error:
        raise Problem(f"cannot read {path}: {error}") from error
    rows = list(csv.DictReader(text.splitlines()))
    if not rows:
        raise Problem(f"{path} holds no rows")
    header = rows[0].keys()
    if "cardId" not in header:
        raise Problem(f"{path} has no cardId column. Use the CSV that extract wrote.")
    missing = [g for g in grades if g not in header]
    if missing:
        raise Problem(f"{path} has no column for: {', '.join(missing)}")
    return rows


def apply(export: Path, in_csv: Path, out_json: Path, grades: list[str]) -> str:
    if out_json.resolve() == export.resolve():
        raise Problem("refusing to write over the export. Give the output a new name.")

    file = load_export(export)
    rows = read_rows(in_csv, grades)
    by_id = {str(c.get("id")): c for c in file["cards"]}

    set_count = 0
    cleared = 0
    touched: list[str] = []
    unknown: list[str] = []

    for index, row in enumerate(rows, start=2):
        card_id = (row.get("cardId") or "").strip()
        if not card_id:
            continue
        card = by_id.get(card_id)
        if card is None:
            unknown.append(card_id)
            continue
        comps = dict(card.get("gradedCompCents") or {})
        before = dict(comps)
        for grade in grades:
            value = (row.get(grade) or "").strip()
            if not value:
                continue
            if value.lower() == CLEAR:
                if comps.pop(grade, None) is not None:
                    cleared += 1
                continue
            comps[grade] = cents(value, f"{in_csv.name} line {index}, column {grade!r}")
            set_count += 1
        if comps != before:
            card["gradedCompCents"] = comps
            name = (row.get("name") or card_id).strip() or card_id
            changes = ", ".join(
                f"{g} {dollars(comps[g])}" if g in comps else f"{g} cleared"
                for g in grades
                if before.get(g) != comps.get(g)
            )
            touched.append(f"  {name} — {changes}")

    if not touched:
        raise Problem("nothing to write: every price cell was empty.")

    out_json.write_text(json.dumps(file, ensure_ascii=False), encoding="utf-8")

    report = [
        f"Wrote {out_json}.",
        f"{len(touched)} cards changed. {set_count} figures set, {cleared} cleared.",
        *touched,
    ]
    if unknown:
        report.append(f"{len(unknown)} rows had a cardId that is not in the export, and were skipped:")
        report += [f"  {u}" for u in unknown[:10]]
    report.append("Import it with Settings -> Import collection, and choose Merge. Never Replace.")
    return "\n".join(report)


# ---------------------------------------------------------------- cli


def grade_list(text: str) -> list[str]:
    grades = [g.strip() for g in text.split(",") if g.strip()]
    if not grades:
        raise argparse.ArgumentTypeError("give at least one grade")
    return grades


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG, help="catalog.sqlite, for card names")
    sub = parser.add_subparsers(dest="command", required=True)

    e = sub.add_parser("extract", help="write the cards that need comps to a CSV")
    e.add_argument("export", type=Path)
    e.add_argument("csv", type=Path)
    e.add_argument("--grades", type=grade_list, default=DEFAULT_GRADES, help=f"default: {','.join(DEFAULT_GRADES)}")
    e.add_argument("--only", choices=["graded", "pristine", "all"], default="graded")
    e.add_argument("--ladder", action="store_true", help=f"every grade the app shows: {', '.join(ALL_GRADES)}")

    a = sub.add_parser("apply", help="write a filled CSV back into a new export file")
    a.add_argument("export", type=Path)
    a.add_argument("csv", type=Path)
    a.add_argument("out", type=Path)
    a.add_argument("--grades", type=grade_list, default=DEFAULT_GRADES)
    a.add_argument("--ladder", action="store_true")

    args = parser.parse_args(argv)
    grades = ALL_GRADES if args.ladder else args.grades

    try:
        if args.command == "extract":
            print(extract(args.export, args.csv, grades, args.only, args.catalog))
        else:
            print(apply(args.export, args.csv, args.out, grades))
    except Problem as problem:
        print(f"error: {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
