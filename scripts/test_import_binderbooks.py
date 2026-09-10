"""Tests for the BinderBooks converter.

  python3 -m unittest discover -s scripts -v

The reconciliation test is the one that matters. It converts the real ledger
and checks the totals against docs/04-seed-import.md. A converter that loses
money passes every other test in this file.
"""

import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import import_binderbooks as conv  # noqa: E402

SEED = ROOT / "seed" / "binderbooks-export.json"


def build_catalog(path: Path, products: list[tuple], sets: list[tuple], prices: list[tuple] = ()) -> None:
    """A catalog with the columns the converter reads. The real schema is in
    catalog/build_catalog.py."""
    db = sqlite3.connect(path)
    db.executescript(
        """
        CREATE TABLE cardSet (groupId INTEGER PRIMARY KEY, categoryId INTEGER, name TEXT, abbreviation TEXT, publishedOn TEXT);
        CREATE TABLE product (
            productId INTEGER PRIMARY KEY, groupId INTEGER, categoryId INTEGER, name TEXT, cleanName TEXT,
            imageUrl TEXT, number TEXT, numberNum INTEGER, setTotal INTEGER, setCode TEXT, rarity TEXT,
            cardType TEXT, isSealed INTEGER DEFAULT 0, printingCount INTEGER DEFAULT 1
        );
        CREATE TABLE price (productId INTEGER, subTypeName TEXT, marketPriceCents INTEGER, lowPriceCents INTEGER,
            midPriceCents INTEGER, highPriceCents INTEGER, directLowPriceCents INTEGER, asOf TEXT,
            PRIMARY KEY (productId, subTypeName));
        """
    )
    db.executemany("INSERT INTO cardSet (groupId, categoryId, name) VALUES (?,?,?)", sets)
    for product_id, group, category, name, number, printings in products:
        parsed = conv.parse_number(number)
        db.execute(
            "INSERT INTO product (productId, groupId, categoryId, name, cleanName, number, numberNum, setTotal, setCode, printingCount)"
            " VALUES (?,?,?,?,?,?,?,?,?,?)",
            (product_id, group, category, name, conv.clean_name(name), number, parsed.numberNum, parsed.setTotal, parsed.setCode, max(printings, 1)),
        )
    db.executemany("INSERT INTO price (productId, subTypeName, marketPriceCents, asOf) VALUES (?,?,?,'2026-09-10')", prices)
    db.commit()
    db.close()


class MoneyTests(unittest.TestCase):
    def test_dollars_convert_to_exact_cents(self):
        self.assertEqual(conv.cents(193.39), 19339)
        self.assertEqual(conv.cents(0.1), 10)
        self.assertEqual(conv.cents(215), 21500)
        self.assertEqual(conv.cents(0), 0)
        self.assertEqual(conv.cents(None), 0)

    def test_every_money_literal_in_the_ledger_has_two_decimals_or_fewer(self):
        """The reason `Decimal(str(value))` is exact rather than lucky."""
        seed = json.loads(SEED.read_text())
        rows = seed["buys"] + seed["sales"] + seed["inventory"]
        for row in rows:
            for key, value in row.items():
                if isinstance(value, float):
                    self.assertLessEqual(len(str(value).split(".")[-1]), 2, f"{key}={value}")


class IdentityTests(unittest.TestCase):
    def test_the_same_source_row_always_gets_the_same_id(self):
        self.assertEqual(conv.ident("buy", "p44rflym"), conv.ident("buy", "p44rflym"))

    def test_different_arrays_never_collide(self):
        self.assertNotEqual(conv.ident("buy", "x1"), conv.ident("sale", "x1"))

    def test_a_day_lands_on_that_day_in_his_timezone(self):
        """Midnight UTC is the previous day in Denver, and he reads these dates."""
        from datetime import datetime, timedelta, timezone

        interval = conv.when("2026-04-20")
        stamp = datetime(2001, 1, 1, tzinfo=timezone.utc) + timedelta(seconds=interval)
        self.assertEqual(stamp.astimezone(timezone(timedelta(hours=-7))).date().isoformat(), "2026-04-20")
        self.assertEqual(stamp.astimezone(timezone(timedelta(hours=10))).date().isoformat(), "2026-04-20")


class MatchingTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        path = Path(self.dir.name) / "catalog.sqlite"
        build_catalog(
            path,
            products=[
                (100, 1, 3, "Roxie's Performance", "121/086", 1),
                (101, 2, 3, "Roxie's Performance", "121/159", 1),
                (102, 1, 3, "Psyduck", "039/217", 1),
                (103, 1, 3, "Psyduck", "226/217", 1),
                (104, 3, 85, "Piplup", "085/80", 1),
                (105, 1, 3, "Charmander", "004/165", 2),
            ],
            sets=[(1, 3, "ME04: Chaos Rising"), (2, 3, "SV: Surging Sparks"), (3, 85, "Inferno X")],
            prices=[(105, "Normal", 10), (105, "Reverse Holofoil", 40), (104, "Holofoil", 3100)],
        )
        self.catalog = conv.Catalog(path)

    def match(self, **row):
        return conv.match_card(self.catalog, row, {})

    def test_the_set_name_decides_between_sets_that_share_a_number(self):
        """His older rows record "121" with no denominator, so the set name is
        the only thing separating two real cards."""
        result = self.match(id="a", name="Roxie's Performance", set="Chaos Rising", number="121", lang="en")
        self.assertEqual(result.product_id, 100)

    def test_the_name_decides_between_cards_that_share_a_set_and_a_number(self):
        result = self.match(id="b", name="Psyduck", set="Ascended Heroes", number="226", lang="en")
        self.assertEqual(result.product_id, 103)

    def test_language_picks_the_category(self):
        result = self.match(id="c", name="Piplup", set="Inferno X", number="085/80", lang="jp")
        self.assertEqual(result.product_id, 104)

    def test_a_product_id_in_the_export_wins(self):
        result = self.match(id="d", name="anything", productId="102", lang="en")
        self.assertEqual(result.product_id, 102)
        self.assertEqual(result.confidence, "certain")

    def test_an_override_beats_everything(self):
        result = conv.match_card(self.catalog, {"id": "e", "productId": "102"}, {"e": 105})
        self.assertEqual(result.product_id, 105)

    def test_a_card_the_catalog_does_not_hold_is_held_back(self):
        product, reason = self.match(id="f", name="Blue-Eyes White Dragon", set="YGO Forbidden Legacy (2005)", number="FL1-EN001", lang="en")
        self.assertIsNone(product)
        self.assertIn("no set named", reason)

    def test_ambiguity_is_held_back_rather_than_guessed(self):
        """Two sets hold a card numbered 121. The set name is unknown and the
        card name matches neither, so the converter refuses to pick."""
        product, reason = self.match(id="g", name="Unlisted Card", set="Mystery Set", number="121", lang="en")
        self.assertIsNone(product)
        self.assertIn("share number", reason)

    def test_a_single_printing_is_assigned_without_asking(self):
        printing, guessed = conv.choose_printing(self.catalog, 104, None)
        self.assertEqual((printing, guessed), ("Holofoil", False))

    def test_several_printings_and_no_variant_is_a_guess(self):
        printing, guessed = conv.choose_printing(self.catalog, 105, None)
        self.assertEqual((printing, guessed), ("Reverse Holofoil", True))

    def test_the_variant_in_the_ledger_wins(self):
        printing, guessed = conv.choose_printing(self.catalog, 105, "Normal")
        self.assertEqual((printing, guessed), ("Normal", False))


class LedgerTests(unittest.TestCase):
    """The real ledger, against docs/04-seed-import.md."""

    @classmethod
    def setUpClass(cls):
        catalog_path = Path(__file__).parent / "catalog.sqlite"
        if not catalog_path.exists():
            catalog_path = ROOT / "catalog.sqlite"
        if not catalog_path.exists():
            raise unittest.SkipTest("no catalog.sqlite; download it from the catalog-latest release")
        seed = json.loads(SEED.read_text())
        cls.converter = conv.Converter(seed, conv.Catalog(catalog_path), {})
        cls.converter.run()
        cls.file = cls.converter.file("2026-09-05T00:00:00Z")

    def total(self, rows, key):
        return sum(row[key] for row in rows)

    def test_money_out_reconciles(self):
        self.assertEqual((self.total(self.file["purchases"], "itemCostCents"), len(self.file["purchases"])), (1_128_302, 93))
        self.assertEqual((self.total(self.file["grading"], "gradingFeesCents"), len(self.file["grading"])), (175_288, 8))

    def test_money_in_reconciles(self):
        sales = self.file["sales"]
        gross = self.total(sales, "grossCents")
        deducted = sum(s["marketplaceFeesCents"] + s["salesTaxCents"] + s["shippingCostCents"] for s in sales)
        self.assertEqual((gross, len(sales)), (355_159, 131))
        # docs/04 calls this line "fees / ship / consign". It includes the $0.98
        # of sales tax, which `saleNet` in the old app deducted too.
        self.assertEqual(deducted, 62_949)
        self.assertEqual(gross - deducted, 292_210)

    def test_every_money_value_is_an_integer(self):
        def walk(node):
            if isinstance(node, dict):
                for key, value in node.items():
                    if key.endswith("Cents"):
                        values = value.values() if isinstance(value, dict) else [value]
                        for each in values:
                            self.assertIsInstance(each, int, key)
                    walk(value)
            elif isinstance(node, list):
                for each in node:
                    walk(each)

        walk(self.file)

    def test_a_rip_becomes_a_sealed_line_and_no_rip_row(self):
        """There is no RipEvent. The sealed PurchaseItem is the pack."""
        self.assertNotIn("rips", self.file)
        sealed = [i for i in self.file["purchaseItems"] if i["isSealed"]]
        self.assertEqual(len(sealed), 58)
        self.assertTrue(all(i["isRipped"] and i["purchaseId"] for i in sealed))
        self.assertTrue(all("sourceRipId" not in c for c in self.file["cards"]))

    def test_a_rip_pull_carries_an_allocated_basis(self):
        """docs/04: costAuto true means BinderBooks derived the figure."""
        allocated = [c for c in self.file["cards"] if c["basisIsAllocated"]]
        self.assertGreater(len(allocated), 200)
        self.assertTrue(all(not c["basisIsManual"] for c in allocated))

    def test_a_slab_he_priced_himself_is_not_allocated(self):
        """The Whatnot slab rows carry costAuto false. docs/04 calls them the
        case that works correctly."""
        typed = [c for c in self.file["cards"] if c["basisIsManual"]]
        self.assertGreater(len(typed), 0)
        self.assertTrue(all(not c["basisIsAllocated"] for c in typed))

    def test_kept_is_a_default_and_never_becomes_personal_collection(self):
        self.assertTrue(all(not c["isPersonalCollection"] for c in self.file["cards"]))
        self.assertEqual([c for c in self.file["cards"] if "kept" in c["tags"]], [])

    def test_status_arrives_as_a_reserved_label(self):
        tagged = {t for c in self.file["cards"] for t in c["tags"]}
        self.assertLessEqual({"sold", "listed", "at grader"}, tagged)

    def test_graded_comps_survive(self):
        with_comps = [c for c in self.file["cards"] if c["gradedCompCents"]]
        self.assertGreaterEqual(len(with_comps), 33)
        for card in with_comps:
            self.assertTrue(all(isinstance(v, int) for v in card["gradedCompCents"].values()))

    def test_a_sale_line_with_no_known_cost_says_so(self):
        incomplete = [line for line in self.file["saleLines"] if line["basisIncomplete"]]
        self.assertEqual(len(incomplete), 70)
        self.assertTrue(all(line["basisCents"] == 0 for line in incomplete))

    def test_a_held_back_card_leaves_its_sale_line_unlinked(self):
        """The revenue still imports. Only the card waits."""
        kept = {c["sourceRef"] for c in self.file["cards"]}
        for line in self.file["saleLines"]:
            source = line["sourceRef"].split(":")[0]
            self.assertTrue(line["cardId"] is None or line["describedAs"] != "" or source in kept)
        self.assertEqual(len(self.file["sales"]), 131)

    def test_the_faults_the_ledger_carries_are_all_reported(self):
        faults = self.converter.report()["faults"]
        self.assertEqual(faults["hit_id_without_hit"]["count"], 25)
        self.assertEqual(faults["hit_without_inventory"]["count"], 28)
        self.assertEqual(faults["sale_line_without_card"]["count"], 53)
        self.assertEqual(faults["sold_without_sale"]["count"], 63)
        self.assertEqual(faults["sale_without_lines"]["count"], 35)
        self.assertEqual(faults["rip_before_buy"]["count"], 3)

    def test_two_runs_write_the_same_bytes(self):
        again = conv.Converter(json.loads(SEED.read_text()), self.converter.catalog, {})
        again.run()
        self.assertEqual(
            json.dumps(again.file("2026-09-05T00:00:00Z"), sort_keys=True),
            json.dumps(self.file, sort_keys=True),
        )


if __name__ == "__main__":
    unittest.main()
