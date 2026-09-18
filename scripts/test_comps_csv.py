"""Tests for the comps spreadsheet round trip.

  python3 -m unittest discover -s scripts -v

The tests that matter are the ones about not losing figures: an empty cell
must leave a comp alone, `apply` must touch nothing but `gradedCompCents`,
and the script must refuse to write over its own input. A converter that
silently drops a typed comp passes every other test in this file.
"""

import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import comps_csv as cc  # noqa: E402


def card(card_id: str, **overrides) -> dict:
    """One OwnedCardDTO, with the fields this script reads."""
    row = {
        "id": card_id,
        "productId": 232613,
        "printing": "Holofoil",
        "condition": "Near Mint",
        "language": "en",
        "quantity": 1,
        "graderRaw": "cgc",
        "gradeLabel": "Pristine 10",
        "gradedCompCents": {},
        "fetchedCompCents": {},
        "acquisitionBasisCents": 7229,
        "tags": ["binder 3"],
    }
    row.update(overrides)
    return row


def export(cards: list[dict], **overrides) -> dict:
    file = {
        "format": "cardtracker-collection",
        "version": 8,
        "exportedAt": "2026-09-15T12:00:00Z",
        "purchases": [{"id": "p1", "vendor": "TCGplayer"}],
        "purchaseItems": [],
        "cards": cards,
        "sessions": [],
    }
    file.update(overrides)
    return file


class Harness(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())

    def write(self, file: dict, name: str = "collection.json") -> Path:
        path = self.dir / name
        path.write_text(json.dumps(file), encoding="utf-8")
        return path

    def rows(self, path: Path) -> list[dict]:
        return list(csv.DictReader(path.read_text(encoding="utf-8").splitlines()))

    def fill(self, path: Path, values: dict[str, str], column: str = "CGC Pristine 10") -> Path:
        """Type a price into the sheet the way Numbers would save it."""
        rows = self.rows(path)
        for row in rows:
            if row["cardId"] in values:
                row[column] = values[row["cardId"]]
        out = self.dir / "filled.csv"
        with out.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        return out


class TestMoney(unittest.TestCase):
    def test_reads_what_a_person_types(self):
        for text, expected in [("125", 12500), ("125.00", 12500), ("$125", 12500), ("1,250.50", 125050), ("0", 0)]:
            self.assertEqual(cc.cents(text, "x"), expected, text)

    def test_rejects_nonsense(self):
        for text in ["", "abc", "$", "-5"]:
            with self.assertRaises(cc.Problem):
                cc.cents(text, "x")

    def test_dollars_round_trip(self):
        for value in [0, 1, 99, 12500, 125050]:
            self.assertEqual(cc.cents(cc.dollars(value), "x"), value)


class TestLoad(Harness):
    def test_rejects_another_format(self):
        path = self.write(export([], format="binderbooks-export"))
        with self.assertRaises(cc.Problem):
            cc.load_export(path)

    def test_rejects_a_newer_version(self):
        path = self.write(export([], version=99))
        with self.assertRaises(cc.Problem):
            cc.load_export(path)

    def test_accepts_an_older_version(self):
        path = self.write(export([card("a")], version=6))
        self.assertEqual(len(cc.load_export(path)["cards"]), 1)


class TestExtract(Harness):
    def test_selects_by_only(self):
        cards = [
            card("pristine", gradeLabel="Pristine 10"),
            card("ten", gradeLabel="10"),
            card("raw", graderRaw=None, gradeLabel=None),
        ]
        path = self.write(export(cards))
        out = self.dir / "comps.csv"

        cc.extract(path, out, ["CGC Pristine 10"], "pristine", None)
        self.assertEqual([r["cardId"] for r in self.rows(out)], ["pristine"])

        cc.extract(path, out, ["CGC Pristine 10"], "graded", None)
        self.assertEqual(sorted(r["cardId"] for r in self.rows(out)), ["pristine", "ten"])

        cc.extract(path, out, ["CGC Pristine 10"], "all", None)
        self.assertEqual(len(self.rows(out)), 3)

    def test_prefills_typed_and_shows_fetched(self):
        cards = [card("a", gradedCompCents={"CGC Pristine 10": 12500}, fetchedCompCents={"CGC Pristine 10": 9900})]
        path = self.write(export(cards))
        out = self.dir / "comps.csv"
        cc.extract(path, out, ["CGC Pristine 10"], "graded", None)

        row = self.rows(out)[0]
        self.assertEqual(row["CGC Pristine 10"], "125.00")
        self.assertEqual(row["fetched: CGC Pristine 10"], "99.00")

    def test_uses_the_hand_entered_name(self):
        cards = [card("a", manualName="Rowlet", manualSetName="Nihil Zero", manualNumber="082/080")]
        path = self.write(export(cards))
        out = self.dir / "comps.csv"
        cc.extract(path, out, ["CGC Pristine 10"], "graded", None)

        row = self.rows(out)[0]
        self.assertEqual((row["name"], row["set"], row["number"]), ("Rowlet", "Nihil Zero", "082/080"))

    def test_a_missing_catalog_is_not_fatal(self):
        path = self.write(export([card("a")]))
        out = self.dir / "comps.csv"
        cc.extract(path, out, ["CGC Pristine 10"], "graded", self.dir / "nothing.sqlite")
        self.assertEqual(self.rows(out)[0]["cardId"], "a")

    def test_refuses_an_empty_selection(self):
        path = self.write(export([card("a", graderRaw=None)]))
        with self.assertRaises(cc.Problem):
            cc.extract(path, self.dir / "comps.csv", ["CGC Pristine 10"], "graded", None)


class TestApply(Harness):
    def setUp(self):
        super().setUp()
        self.cards = [
            card("a", gradedCompCents={"CGC 10": 9000}),
            card("b", gradedCompCents={"CGC Pristine 10": 20000}),
        ]
        self.export_path = self.write(export(self.cards))
        self.csv_path = self.dir / "comps.csv"
        cc.extract(self.export_path, self.csv_path, ["CGC Pristine 10"], "graded", None)

    def result(self, filled: Path) -> dict:
        out = self.dir / "priced.json"
        cc.apply(self.export_path, filled, out, ["CGC Pristine 10"])
        return {c["id"]: c for c in json.loads(out.read_text(encoding="utf-8"))["cards"]}

    def test_writes_dollars_as_cents(self):
        cards = self.result(self.fill(self.csv_path, {"a": "125.00"}))
        self.assertEqual(cards["a"]["gradedCompCents"]["CGC Pristine 10"], 12500)

    def test_an_empty_cell_keeps_the_existing_figure(self):
        cards = self.result(self.fill(self.csv_path, {"a": "125.00"}))
        # `b` had a figure and its cell stayed empty, so the figure survives.
        self.assertEqual(cards["b"]["gradedCompCents"], {"CGC Pristine 10": 20000})

    def test_keeps_the_other_grades_on_the_same_card(self):
        cards = self.result(self.fill(self.csv_path, {"a": "125.00"}))
        self.assertEqual(cards["a"]["gradedCompCents"]["CGC 10"], 9000)

    def test_clear_removes_one_figure(self):
        cards = self.result(self.fill(self.csv_path, {"b": "clear"}))
        self.assertEqual(cards["b"]["gradedCompCents"], {})

    def test_touches_nothing_but_graded_comps(self):
        before = json.loads(self.export_path.read_text(encoding="utf-8"))
        out = self.dir / "priced.json"
        cc.apply(self.export_path, self.fill(self.csv_path, {"a": "125.00"}), out, ["CGC Pristine 10"])
        after = json.loads(out.read_text(encoding="utf-8"))

        for card_before, card_after in zip(before["cards"], after["cards"]):
            card_before.pop("gradedCompCents")
            card_after.pop("gradedCompCents")
            self.assertEqual(card_before, card_after)
        before.pop("cards")
        after.pop("cards")
        self.assertEqual(before, after)

    def test_leaves_the_fetched_figures_alone(self):
        self.cards[0]["fetchedCompCents"] = {"CGC 10": 8800}
        self.export_path = self.write(export(self.cards))
        cc.extract(self.export_path, self.csv_path, ["CGC Pristine 10"], "graded", None)
        cards = self.result(self.fill(self.csv_path, {"a": "125.00"}))
        self.assertEqual(cards["a"]["fetchedCompCents"], {"CGC 10": 8800})

    def test_refuses_to_write_over_the_export(self):
        with self.assertRaises(cc.Problem):
            cc.apply(self.export_path, self.fill(self.csv_path, {"a": "1"}), self.export_path, ["CGC Pristine 10"])

    def test_refuses_a_sheet_with_no_prices(self):
        with self.assertRaises(cc.Problem):
            cc.apply(self.export_path, self.csv_path, self.dir / "priced.json", ["CGC Pristine 10"])

    def test_refuses_a_sheet_missing_the_grade_column(self):
        with self.assertRaises(cc.Problem):
            cc.apply(self.export_path, self.csv_path, self.dir / "priced.json", ["PSA 10"])

    def test_skips_a_card_that_is_not_in_the_export(self):
        filled = self.fill(self.csv_path, {"a": "125.00"})
        rows = self.rows(filled)
        rows.append({**rows[0], "cardId": "gone", "CGC Pristine 10": "50.00"})
        with filled.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)

        out = self.dir / "priced.json"
        report = cc.apply(self.export_path, filled, out, ["CGC Pristine 10"])
        self.assertIn("gone", report)
        self.assertEqual(len(json.loads(out.read_text(encoding="utf-8"))["cards"]), 2)

    def test_a_bad_price_names_the_line(self):
        with self.assertRaises(cc.Problem) as caught:
            cc.apply(self.export_path, self.fill(self.csv_path, {"a": "one hundred"}), self.dir / "p.json", ["CGC Pristine 10"])
        self.assertIn("line", str(caught.exception))


class TestRoundTrip(Harness):
    def test_extract_then_apply_keeps_every_other_field(self):
        cards = [card(f"c{i}", productId=1000 + i, gradedCompCents={"CGC 9": 100 * i}) for i in range(5)]
        source = export(cards, expenses=[{"id": "e1", "amountCents": 500}])
        path = self.write(source)
        sheet = self.dir / "comps.csv"
        cc.extract(path, sheet, ["CGC Pristine 10"], "graded", None)

        filled = self.fill(sheet, {f"c{i}": f"{i + 1}.50" for i in range(5)})
        out = self.dir / "priced.json"
        cc.apply(path, filled, out, ["CGC Pristine 10"])
        after = json.loads(out.read_text(encoding="utf-8"))

        self.assertEqual(after["expenses"], [{"id": "e1", "amountCents": 500}])
        for i, updated in enumerate(after["cards"]):
            self.assertEqual(updated["gradedCompCents"]["CGC Pristine 10"], (i + 1) * 100 + 50)
            self.assertEqual(updated["gradedCompCents"]["CGC 9"], 100 * i)


if __name__ == "__main__":
    unittest.main()
