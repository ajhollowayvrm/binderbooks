"""Tests for carrying artwork signatures between nightly catalogs."""

import sqlite3
import tempfile
import unittest
from pathlib import Path

from merge_descriptors import merge


def make_catalog(path: Path, products: list[int], art: dict[int, bytes] | None = None,
                 version: str | None = None) -> None:
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        CREATE TABLE product (productId INTEGER PRIMARY KEY, name TEXT NOT NULL);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """
    )
    connection.executemany(
        "INSERT INTO product VALUES (?, ?)", [(p, f"Card {p}") for p in products]
    )
    if art is not None:
        connection.executescript(
            "CREATE TABLE productArt (productId INTEGER PRIMARY KEY, descriptor BLOB NOT NULL);"
        )
        connection.executemany(
            "INSERT INTO productArt VALUES (?, ?)", list(art.items())
        )
    if version is not None:
        connection.execute(
            "INSERT INTO meta VALUES ('artFormatVersion', ?)", (version,)
        )
    connection.commit()
    connection.close()


def signatures(path: Path) -> dict[int, bytes]:
    connection = sqlite3.connect(path)
    try:
        return dict(connection.execute("SELECT productId, descriptor FROM productArt"))
    finally:
        connection.close()


class MergeDescriptorsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.new = Path(self.directory.name) / "new.sqlite"
        self.old = Path(self.directory.name) / "old.sqlite"

    def tearDown(self) -> None:
        self.directory.cleanup()

    def test_carries_signatures_forward(self) -> None:
        """The nightly rebuild must not pay for artwork it already has."""
        make_catalog(self.new, [1, 2, 3])
        make_catalog(self.old, [1, 2, 3], art={1: b"aaa", 2: b"bbb"}, version="1")

        carried, dropped, skipped = merge(self.new, self.old)

        self.assertEqual((carried, dropped, skipped), (2, 0, 0))
        self.assertEqual(signatures(self.new), {1: b"aaa", 2: b"bbb"})

    def test_drops_a_signature_whose_product_is_gone(self) -> None:
        """TCGplayer retires products. A signature with no product is orphaned."""
        make_catalog(self.new, [1])
        make_catalog(self.old, [1, 2], art={1: b"aaa", 2: b"bbb"}, version="1")

        carried, dropped, _ = merge(self.new, self.old)

        self.assertEqual((carried, dropped), (1, 1))
        self.assertEqual(signatures(self.new), {1: b"aaa"})

    def test_refuses_signatures_from_different_arithmetic(self) -> None:
        """A signature the phone would compare wrongly is worse than none."""
        make_catalog(self.new, [1, 2], version="2")
        make_catalog(self.old, [1, 2], art={1: b"aaa"}, version="1")

        carried, _, skipped = merge(self.new, self.old)

        self.assertEqual((carried, skipped), (0, 1))
        self.assertEqual(signatures(self.new), {})

    def test_an_old_catalog_with_no_artwork_is_harmless(self) -> None:
        """The first night after the feature ships has nothing to carry."""
        make_catalog(self.new, [1, 2])
        make_catalog(self.old, [1, 2])

        self.assertEqual(merge(self.new, self.old), (0, 0, 0))

    def test_merging_twice_changes_nothing(self) -> None:
        """The job is retried. A retry must not double anything."""
        make_catalog(self.new, [1, 2])
        make_catalog(self.old, [1, 2], art={1: b"aaa"}, version="1")

        merge(self.new, self.old)
        merge(self.new, self.old)

        self.assertEqual(signatures(self.new), {1: b"aaa"})


if __name__ == "__main__":
    unittest.main()
