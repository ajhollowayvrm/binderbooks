"""Unit tests for the pure parts of the catalog build. No network."""

import sqlite3
import tempfile
import unittest
from pathlib import Path

import build_catalog as bc


class ToCentsTests(unittest.TestCase):
    def test_rounds_half_up_once(self):
        self.assertEqual(bc.to_cents(0.35), 35)
        self.assertEqual(bc.to_cents(12.34), 1234)
        self.assertEqual(bc.to_cents(1.005), 101)
        self.assertEqual(bc.to_cents(49.26), 4926)
        self.assertEqual(bc.to_cents(1651.89), 165189)

    def test_none_stays_none(self):
        self.assertIsNone(bc.to_cents(None))

    def test_integer_input(self):
        self.assertEqual(bc.to_cents(45), 4500)


class ParseNumberTests(unittest.TestCase):
    def check(self, raw, num, total=None, code=None):
        self.assertEqual(bc.parse_number(raw), bc.ParsedNumber(numberNum=num, setTotal=total, setCode=code))

    def test_pokemon_fraction(self):
        self.check("114/084", 114, 84)
        self.check("001/102", 1, 102)

    def test_secret_rare_exceeds_total(self):
        self.check("226/197", 226, 197)

    def test_promo_with_series_suffix(self):
        self.check("001/M-P", 1, None, "M-P")
        self.check("226/S-P", 226, None, "S-P")
        self.check("007/PPP", 7, None, "PPP")

    def test_english_promo_prefix(self):
        self.check("SWSH083", 83, None, "SWSH")
        self.check("SVP 200", 200, None, "SVP")

    def test_promo_variant_letter_suffix(self):
        self.check("XY67a", 67, None, "XY")
        self.check("SM30a", 30, None, "SM")

    def test_bare_number(self):
        self.check("073", 73)

    def test_digimon_drops_rarity_suffix(self):
        self.check("BT26-052 C", 52, None, "BT26")
        self.check("BT25-044 SR", 44, None, "BT25")
        self.check("BT25-091", 91, None, "BT25")

    def test_union_arena(self):
        self.check("UE10BT/AOT-1-007", 7, None, "UE10BT")
        self.check("UEX07BT/AOT-2-AP01", 1, None, "UEX07BT")

    def test_double_card_takes_first(self):
        self.check("073/076 / 074/076", 73, 76)

    def test_unparseable(self):
        self.check("SV-P", None)
        self.check("", None)
        self.check(None, None)


class NameTests(unittest.TestCase):
    def test_clean_name(self):
        self.assertEqual(bc.clean_name("Pokémon Center Lady"), "pokemon center lady")
        self.assertEqual(bc.clean_name("Farfetch'd"), "farfetch d")
        self.assertEqual(bc.clean_name("Stellar Crown Build & Battle Box"), "stellar crown build and battle box")
        self.assertEqual(bc.clean_name("  Mr.   Mime  "), "mr mime")

    def test_display_name_strips_number_suffix(self):
        self.assertEqual(bc.display_name("Alakazam V - SWSH083", "SWSH083"), "Alakazam V")
        self.assertEqual(bc.display_name("Levi (007)", "UE10BT/AOT-1-007"), "Levi")
        self.assertEqual(bc.display_name("Charizard ex - 199/165", "199/165"), "Charizard ex")

    def test_display_name_keeps_variant_parentheticals(self):
        self.assertEqual(bc.display_name("Pikachu (Cosmos Holo)", "025/102"), "Pikachu (Cosmos Holo)")
        self.assertEqual(bc.display_name("Stellar Crown Booster Pack", None), "Stellar Crown Booster Pack")


class SealedTests(unittest.TestCase):
    def test_number_means_single(self):
        p = {"name": "Heracross", "extendedData": [{"name": "Number", "value": "001/076"}]}
        self.assertFalse(bc.is_sealed(p, bc.extended(p)))

    def test_no_number_means_sealed(self):
        p = {"name": "Stellar Crown Booster Box", "extendedData": [{"name": "CardText", "value": "x"}]}
        self.assertTrue(bc.is_sealed(p, bc.extended(p)))

    def test_rarity_without_number_is_a_single(self):
        p = {"name": "Fire Energy", "extendedData": [{"name": "Rarity", "value": "Common"}]}
        self.assertFalse(bc.is_sealed(p, bc.extended(p)))
        p = {"name": "Charizard", "extendedData": [{"name": "Rarity", "value": "None"}]}
        self.assertFalse(bc.is_sealed(p, bc.extended(p)))

    def test_code_card_is_not_sealed(self):
        p = {"name": "Code Card - Stellar Crown Booster Pack", "extendedData": []}
        self.assertFalse(bc.is_sealed(p, bc.extended(p)))


class CategoryTests(unittest.TestCase):
    LIVE = [
        {"categoryId": 3, "name": "Pokemon"},
        {"categoryId": 63, "name": "Digimon Card Game"},
        {"categoryId": 81, "name": "Union Arena"},
        {"categoryId": 85, "name": "Pokemon Japan"},
    ]

    def test_resolves_configured_names(self):
        ids = [c["categoryId"] for c in bc.resolve_categories(self.LIVE, bc.CATEGORY_NAMES)]
        self.assertEqual(ids, [3, 85, 63, 81])

    def test_missing_name_fails(self):
        with self.assertRaises(SystemExit):
            bc.resolve_categories(self.LIVE, ["Pokemon", "Digimon"])

    def test_chinese_scan(self):
        cats = self.LIVE + [{"categoryId": 99, "name": "Pokemon Chinese"}]
        self.assertEqual([c["categoryId"] for c in bc.find_chinese_categories(cats)], [99])
        self.assertEqual(bc.find_chinese_categories(self.LIVE), [])


class SourceDateTests(unittest.TestCase):
    def test_tcgcsv_stamp(self):
        self.assertEqual(bc.parse_last_updated("2026-09-11T20:05:58+0000\n"), "2026-09-11")

    def test_offset_is_converted_to_utc(self):
        # 20:05 at UTC-6 is 02:05 the next day in UTC.
        self.assertEqual(bc.parse_last_updated("2026-09-11T20:05:58-0600"), "2026-09-12")

    def test_unreadable_stamp_fails(self):
        with self.assertRaises(ValueError):
            bc.parse_last_updated("<html>maintenance</html>")


class BuildSqliteTests(unittest.TestCase):
    def test_end_to_end_on_fixture(self):
        cat = {"categoryId": 3, "name": "Pokemon", "displayName": "Pokemon"}
        grp = {"groupId": 23537, "name": "SV07: Stellar Crown", "abbreviation": "SCR", "publishedOn": "2024-09-13T00:00:00"}
        products = [
            {
                "productId": 1,
                "groupId": 23537,
                "name": "Terapagos ex - 128/142",
                "imageUrl": "https://img/1.jpg",
                "extendedData": [
                    {"name": "Number", "value": "128/142"},
                    {"name": "Rarity", "value": "Double Rare"},
                    {"name": "Card Type", "value": "Colorless"},
                ],
            },
            {
                "productId": 2,
                "groupId": 23537,
                "name": "Duskull",
                "imageUrl": None,
                "extendedData": [{"name": "Number", "value": "068/142"}, {"name": "Rarity", "value": "Common"}],
            },
            {"productId": 3, "groupId": 23537, "name": "Stellar Crown Booster Pack", "extendedData": []},
        ]
        prices = [
            {"productId": 1, "subTypeName": "Holofoil", "marketPrice": 3.21, "lowPrice": 2.5, "midPrice": 3.0, "highPrice": 9.99, "directLowPrice": None},
            {"productId": 2, "subTypeName": "Normal", "marketPrice": 0.05, "lowPrice": 0.01, "midPrice": 0.1, "highPrice": 1.0, "directLowPrice": 0.35},
            {"productId": 2, "subTypeName": "Reverse Holofoil", "marketPrice": 0.12, "lowPrice": 0.05, "midPrice": 0.2, "highPrice": 2.0, "directLowPrice": None},
            {"productId": 3, "subTypeName": "Normal", "marketPrice": 10.47, "lowPrice": 9.32, "midPrice": 10.99, "highPrice": 99.99, "directLowPrice": None},
        ]
        data = [bc.CategoryData(category=cat, groups=[bc.GroupData(group=grp, products=products, prices=prices)])]

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "catalog.sqlite"
            summary = bc.build_sqlite(path, data, "2026-09-09T21:30:00Z", "2026-09-09")
            self.assertEqual(summary["productCount"], 3)

            conn = sqlite3.connect(path)
            rows = {r[0]: r for r in conn.execute("SELECT productId, name, cleanName, numberNum, setTotal, isSealed, printingCount, rarity, cardType FROM product")}
            self.assertEqual(rows[1][1:], ("Terapagos ex", "terapagos ex", 128, 142, 0, 1, "Double Rare", "Colorless"))
            self.assertEqual(rows[2][3:7], (68, 142, 0, 2))
            self.assertEqual(rows[3][5:7], (1, 1))

            self.assertEqual(
                conn.execute("SELECT marketPriceCents, directLowPriceCents FROM price WHERE productId=2 AND subTypeName='Normal'").fetchone(),
                (5, 35),
            )
            self.assertEqual(conn.execute("SELECT typeof(marketPriceCents) FROM price WHERE productId=1").fetchone(), ("integer",))

            # prefix search
            hits = [r[0] for r in conn.execute("SELECT rowid FROM product_fts WHERE product_fts MATCH 'tera*'")]
            self.assertEqual(hits, [1])
            # typo tolerance via trigram
            hits = [r[0] for r in conn.execute("SELECT rowid FROM product_trigram WHERE product_trigram MATCH 'rapagos'")]
            self.assertEqual(hits, [1])
            # set name is searchable on path A
            hits = sorted(r[0] for r in conn.execute("SELECT rowid FROM product_fts WHERE product_fts MATCH 'stellar'"))
            self.assertEqual(hits, [1, 2, 3])

            meta = dict(conn.execute("SELECT key, value FROM meta"))
            self.assertEqual(meta["schemaVersion"], "1")
            self.assertEqual(meta["productCount"], "3")
            self.assertEqual(conn.execute("PRAGMA journal_mode").fetchone()[0], "delete")
            conn.close()


if __name__ == "__main__":
    unittest.main()
