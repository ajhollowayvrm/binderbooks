"""Unit tests for the pure parts of the Chinese catalog build. No network."""

import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

import build_catalog as bc
import build_chinese as bz


def card(cid, number, name="Ponyta", local="小火马", rarity="Common", variant="holo", is_variant=False):
    return {
        "id": cid, "card_set_id": "cbb4c", "card_number": number, "name": name, "local_name": local,
        "card_type": "pokemon", "rarity_label": rarity, "variant": variant, "is_variant": is_variant,
        "image_url": f"https://images.pikaqian.com/originals/x/{cid}.png",
    }


class IdTests(unittest.TestCase):
    def test_an_id_does_not_change_between_builds(self):
        first = bz.assign_ids(["a", "b", "c"], {})
        second = bz.assign_ids(["c", "b", "a", "d"], {})
        for key in ("a", "b", "c"):
            self.assertEqual(first[key], second[key])

    def test_ids_stay_inside_the_int32_range_above_tcgplayer(self):
        ids = bz.assign_ids([f"card-{i}" for i in range(2000)], {})
        self.assertEqual(len(set(ids.values())), 2000)
        for value in ids.values():
            self.assertGreaterEqual(value, 1_000_000_000)
            self.assertLessEqual(value, 2_147_483_647)

    def test_the_previous_mapping_wins_over_the_hash(self):
        ids = bz.assign_ids(["a", "b"], {"a": 1_000_000_123})
        self.assertEqual(ids["a"], 1_000_000_123)

    def test_a_collision_moves_to_the_next_free_number(self):
        taken = {bz.stable_id("a", set())}
        moved = bz.stable_id("a", taken)
        self.assertNotIn(moved, taken)


class NumberTests(unittest.TestCase):
    def test_a_numbered_set_prints_its_total(self):
        cards = [
            card("1", "001", rarity="Common"),
            card("2", "128", rarity="Uncommon"),
            card("3", "129", rarity="Art Rare"),
            card("4", "163", rarity="Ultra Rare"),
            card("5", "140", rarity="Common", variant="pokeball", is_variant=True),
        ]
        self.assertEqual(bz.set_total(cards), 128)
        self.assertEqual(bz.printed_number("001", 128, {}), "001/128")
        self.assertEqual(bz.printed_number("163", 128, {}), "163/128")

    def test_an_ace_spec_card_is_inside_the_total(self):
        cards = [
            card("1", "207", rarity="Uncommon"),
            card("2", "208", rarity="ACE SPEC Rare"),
            card("3", "209", rarity="Super Rare"),
        ]
        self.assertEqual(bz.set_total(cards), 208)

    def test_a_gem_pack_prints_slot_art_and_art_count(self):
        cards = [card(str(i), f"01 0{i}") for i in range(1, 8)] + [card("9", "02 01")]
        slots = bz.slot_totals(cards)
        self.assertEqual(slots, {"01": 7, "02": 1})
        self.assertEqual(bz.printed_number("01 01", None, slots), "0101/07")

    def test_the_app_reads_the_printed_gem_number(self):
        self.assertEqual(bc.parse_number("0101/07"), bc.ParsedNumber(numberNum=101, setTotal=7))
        self.assertEqual(bc.parse_number("001/128"), bc.ParsedNumber(numberNum=1, setTotal=128))

    def test_an_unknown_shape_stays_as_given(self):
        self.assertEqual(bz.printed_number("SVP-001", None, {}), "SVP-001")
        self.assertEqual(bz.printed_number("001", None, {}), "001")


class NameTests(unittest.TestCase):
    def test_a_pattern_printing_gets_the_tcgplayer_qualifier(self):
        c = card("1", "001", name="Surskit", variant="pokeball", is_variant=True)
        self.assertEqual(bz.product_name(c), "Surskit (Poke Ball Pattern)")
        self.assertEqual(bz.printing(c), "Holofoil")

    def test_the_base_card_has_no_qualifier(self):
        self.assertEqual(bz.product_name(card("1", "001", variant="non-holo")), "Ponyta")
        self.assertEqual(bz.printing(card("1", "001", variant="non-holo")), "Normal")

    def test_a_card_with_no_english_name_uses_the_chinese_one(self):
        self.assertEqual(bz.product_name(card("1", "001", name=None)), "小火马")


class BuildTests(unittest.TestCase):
    def build(self, directory, previous=None, with_sales=None):
        data = [bz.SetData(
            set={"id": "cbb4c", "name": "Gem Pack Vol 4", "local_name": "宝石包4", "release_date": "2026-02-06"},
            cards=[card("u1", "01 01"), card("u2", "01 02", rarity="Rare")],
        )]
        path = Path(directory) / bz.FILE_NAME
        bz.build_sqlite(path, data, previous or bz.Previous({}, {}, {}, {}), "2026-09-14T00:00:00Z", lambda _: None, with_sales)
        return path

    def test_the_file_has_the_catalog_schema_and_the_chinese_tables(self):
        with tempfile.TemporaryDirectory() as d:
            path = self.build(d)
            conn = sqlite3.connect(path)
            meta = dict(conn.execute("SELECT key, value FROM meta"))
            self.assertEqual(meta["kind"], bz.KIND)
            self.assertEqual(meta["productCount"], "2")
            row = conn.execute("SELECT categoryId, name, number, numberNum, setTotal FROM product ORDER BY number").fetchone()
            # Slot 01 has two arts in this fixture, so the card prints "/02".
            self.assertEqual(row, (bz.CATEGORY_ID, "Ponyta", "0101/02", 101, 2))
            self.assertEqual(conn.execute("SELECT localName FROM productLocalName LIMIT 1").fetchone()[0], "小火马")
            hits = conn.execute("SELECT rowid FROM product_fts WHERE product_fts MATCH '小火马'").fetchall()
            self.assertEqual(len(hits), 2)
            self.assertEqual(conn.execute("SELECT count(*) FROM price WHERE subTypeName = 'Holofoil'").fetchone()[0], 2)
            conn.close()

    def test_a_rebuild_keeps_ids_signatures_and_prices(self):
        with tempfile.TemporaryDirectory() as d:
            path = self.build(d)
            conn = sqlite3.connect(path)
            pid = conn.execute("SELECT productId FROM pikaqianCard WHERE cardId = 'u1'").fetchone()[0]
            conn.execute("INSERT INTO productArt VALUES (?, ?)", (pid, b"\x01" * 128))
            conn.execute("INSERT INTO pikaqianPrice VALUES (?, 1850, 3, '2026-09-13T11:00:00Z', '2026-09-14T00:00:00Z')", (pid,))
            conn.commit()
            conn.close()

            previous = bz.read_previous(path)
            path.rename(Path(d) / "old.sqlite")
            path = self.build(d, previous)
            conn = sqlite3.connect(path)
            self.assertEqual(conn.execute("SELECT productId FROM pikaqianCard WHERE cardId = 'u1'").fetchone()[0], pid)
            self.assertEqual(conn.execute("SELECT count(*) FROM productArt").fetchone()[0], 1)
            self.assertEqual(conn.execute("SELECT marketPriceCents, asOf FROM price WHERE productId = ?", (pid,)).fetchone(), (1850, "2026-09-13"))
            conn.close()


    def test_the_file_lists_the_cards_with_sales(self):
        with tempfile.TemporaryDirectory() as d:
            conn = sqlite3.connect(self.build(d, with_sales={"u1"}))
            pid = conn.execute("SELECT productId FROM pikaqianCard WHERE cardId = 'u1'").fetchone()[0]
            self.assertEqual(conn.execute("SELECT productId FROM productSales").fetchall(), [(pid,)])
            self.assertIsNotNone(conn.execute("SELECT value FROM meta WHERE key = 'salesCheckedAt'").fetchone())
            conn.close()

    def test_a_build_that_did_not_check_sales_claims_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            conn = sqlite3.connect(self.build(d))
            self.assertEqual(conn.execute("SELECT count(*) FROM productSales").fetchone()[0], 0)
            self.assertIsNone(conn.execute("SELECT value FROM meta WHERE key = 'salesCheckedAt'").fetchone())
            conn.close()


class PriceTests(unittest.TestCase):
    def test_owned_cards_skip_sold_and_non_chinese_cards(self):
        export = {"cards": [
            {"productId": 1_000_000_001, "printing": "Holofoil", "condition": "Near Mint", "quantity": 1, "statusRaw": "owned", "tags": []},
            {"productId": 1_000_000_001, "printing": "Holofoil", "condition": "Lightly Played", "quantity": 2, "statusRaw": "owned"},
            {"productId": 1_000_000_002, "printing": "Holofoil", "condition": "Near Mint", "quantity": 1, "statusRaw": "owned", "tags": ["sold"]},
            {"productId": 1_000_000_003, "printing": "Holofoil", "condition": "Near Mint", "quantity": 1, "statusRaw": "sold"},
            {"productId": 42346, "printing": "Normal", "condition": "Near Mint", "quantity": 1, "statusRaw": "owned"},
        ]}
        owned = bz.owned_chinese_cards(export, {1_000_000_001, 1_000_000_002, 1_000_000_003})
        self.assertEqual(list(owned), [1_000_000_001])
        self.assertEqual(owned[1_000_000_001].quantity, 3)

    def test_the_price_summary_reads_the_raw_grade(self):
        body = json.loads('{"currency":"USD","updated_at":"2026-09-13T11:27:26Z","recent_sale_count":1,'
                          '"grades":{"raw":{"price_cents":149,"source":"ebay"},"psa10":null}}')
        self.assertEqual(bz.price_summary(body), (149, 1, "2026-09-13T11:27:26Z"))

    def test_a_card_never_sold_has_no_price(self):
        self.assertEqual(bz.price_summary({"grades": {"raw": None}}), (None, None, None))

    def test_a_card_with_no_sales_does_not_stop_the_price_run(self):
        class FakeClient:
            requests = 0

            def __init__(self, prices):
                self.prices = prices

            def log(self, _):
                pass

            def get(self, path, params=None):
                card_id = path.split("/")[2]
                if card_id not in self.prices:
                    raise bz.PikaQianNotFound(f"{path}: HTTP 404")
                return {"grades": {"raw": {"price_cents": self.prices[card_id]}}, "recent_sale_count": 2}

        with tempfile.TemporaryDirectory() as d:
            path = BuildTests().build(d, with_sales={"u1", "u2"})
            conn = sqlite3.connect(path)
            ids = dict(conn.execute("SELECT cardId, productId FROM pikaqianCard"))
            conn.close()
            export = Path(d) / "export.json"
            export.write_text(json.dumps({"cards": [
                {"productId": ids["u1"], "statusRaw": "owned"},
                {"productId": ids["u2"], "statusRaw": "owned"},
            ]}))
            summary = bz.price(path, export, Path(d) / "prices.csv", FakeClient({"u1": 1850}), "2026-09-15T00:00:00Z")
            self.assertEqual((summary["products"], summary["priced"]), (2, 1))
            conn = sqlite3.connect(path)
            prices = dict(conn.execute("SELECT productId, marketPriceCents FROM price"))
            self.assertEqual((prices[ids["u1"]], prices[ids["u2"]]), (1850, None))
            self.assertEqual(conn.execute("SELECT productId FROM productSales").fetchall(), [(ids["u1"],)])
            conn.close()


if __name__ == "__main__":
    unittest.main()
