#!/usr/bin/env python3
"""Carry artwork signatures from yesterday's catalog into today's.

The catalog is rebuilt from TCGCSV every night, but a signature costs an image
download and a Vision pass, and 76,000 of them take over half an hour. They do
not change: a product's artwork is the same artwork tomorrow. So the nightly job
copies every published signature into the new catalog, and
scripts/sign-catalog.sh on AJ's Mac only signs what is new. The script uses this
same merge to keep its own unpublished work.

A signature is dropped when its product is gone from the new catalog, and when
the version of the arithmetic that made it no longer matches the app's. Both are
the same rule: never carry forward something the phone would compare wrongly.

Standard library only, like build_catalog.py.
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS productArt (
    productId  INTEGER PRIMARY KEY REFERENCES product(productId),
    descriptor BLOB NOT NULL
);
"""


def format_version(connection: sqlite3.Connection) -> str | None:
    """The version of the signature arithmetic this catalog was built with."""
    try:
        row = connection.execute(
            "SELECT value FROM meta WHERE key = 'artFormatVersion'"
        ).fetchone()
    except sqlite3.DatabaseError:
        return None
    return row[0] if row else None


def has_table(connection: sqlite3.Connection, name: str) -> bool:
    row = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (name,)
    ).fetchone()
    return row is not None


def merge(new_path: Path, old_path: Path) -> tuple[int, int, int]:
    """Copy signatures from `old_path` into `new_path`.

    Returns (carried, dropped_missing_product, skipped_version_mismatch).
    """
    target = sqlite3.connect(new_path)
    try:
        target.executescript(SCHEMA)

        source = sqlite3.connect(f"file:{old_path}?mode=ro", uri=True)
        try:
            if not has_table(source, "productArt"):
                return (0, 0, 0)

            old_version = format_version(source)
            new_version = format_version(target)
            # The new catalog has not been signed yet, so it carries no version
            # of its own. The old one's version is what the rows mean, and the
            # signing step will stamp it.
            if new_version is not None and old_version != new_version:
                total = source.execute("SELECT count(*) FROM productArt").fetchone()[0]
                return (0, 0, total)

            rows = source.execute(
                "SELECT productId, descriptor FROM productArt"
            ).fetchall()
        finally:
            source.close()

        if not rows:
            return (0, 0, 0)

        live = {
            row[0]
            for row in target.execute("SELECT productId FROM product").fetchall()
        }
        keep = [row for row in rows if row[0] in live]
        dropped = len(rows) - len(keep)

        target.executemany(
            "INSERT INTO productArt (productId, descriptor) VALUES (?, ?) "
            "ON CONFLICT(productId) DO UPDATE SET descriptor = excluded.descriptor",
            keep,
        )
        if old_version is not None:
            target.executescript(
                "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
            )
            target.execute(
                "INSERT INTO meta (key, value) VALUES ('artFormatVersion', ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (old_version,),
            )
        target.commit()
        return (len(keep), dropped, 0)
    finally:
        target.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--new", required=True, type=Path, help="tonight's catalog")
    parser.add_argument("--old", required=True, type=Path, help="the previous catalog")
    arguments = parser.parse_args()

    if not arguments.new.exists():
        print(f"no catalog at {arguments.new}", file=sys.stderr)
        return 1
    if not arguments.old.exists():
        # The first run has nothing to carry. That is not a failure; the signing
        # step will simply have every product to do.
        print("no previous catalog, so nothing to carry")
        return 0

    carried, dropped, skipped = merge(arguments.new, arguments.old)
    print(f"carried {carried} signatures")
    if dropped:
        print(f"dropped {dropped} whose product is gone")
    if skipped:
        print(f"skipped {skipped} built by a different version of the arithmetic")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
