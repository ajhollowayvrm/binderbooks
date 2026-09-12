#!/usr/bin/env bash
# Builds the catalog on this Mac, signs its artwork, and publishes it to the
# public release `catalog-latest`. The app downloads it from there.
#
# Nothing runs this on a schedule. Run it by hand when the app needs new cards
# and new prices:
#
#   caffeinate -i scripts/publish-catalog.sh
#
# `caffeinate -i` stops the Mac from sleeping during a long run. The first full
# signing took 24 minutes for 76,000 cards. A later run keeps the published
# signatures and signs only the new products, so it takes a few minutes.
#
# You can stop the script with Ctrl-C at any time. The tool writes signatures in
# batches to build/catalog/catalog.sqlite, and the next run keeps them.
#
# Needs macOS with a neural engine, Xcode's swiftc, python3, and gh signed in with
# write access to the repo.

set -euo pipefail

repo=ajhollowayvrm/binderbooks
tag=catalog-latest
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/build/catalog"
mkdir -p "$work"

echo "running the unit tests"
python3 -m unittest discover -s "$root/catalog"

echo "building the signing tool"
swiftc -O "$root/catalog/build_descriptors.swift" "$root/ios/Sources/Scan/CardArtDescriptor.swift" \
  -o "$work/build-descriptors"

echo "building the catalog from TCGCSV"
rm -rf "$work/new"
python3 "$root/catalog/build_catalog.py" --out "$work/new" \
  --release-url "https://github.com/$repo/releases/download/$tag/catalog.sqlite.gz"

# The new catalog is built from nothing. Copy in the signatures that already
# exist, so that no card is signed twice: first the published ones, then the
# ones from an earlier run of this script that stopped before it published.
rm -rf "$work/published"
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  mkdir -p "$work/published"
  gh release download "$tag" --repo "$repo" --dir "$work/published" --pattern catalog.sqlite.gz
  gunzip "$work/published/catalog.sqlite.gz"
  python3 "$root/catalog/merge_descriptors.py" \
    --new "$work/new/catalog.sqlite" --old "$work/published/catalog.sqlite"
else
  echo "no published catalog, so every product needs a signature"
fi
if [ -f "$work/catalog.sqlite" ]; then
  python3 "$root/catalog/merge_descriptors.py" \
    --new "$work/new/catalog.sqlite" --old "$work/catalog.sqlite"
fi
mv -f "$work/new/catalog.sqlite" "$work/catalog.sqlite"
mv -f "$work/new/catalog-manifest.json" "$work/catalog-manifest.json"
mv -f "$work/new/build-report.md" "$work/build-report.md"
rm -rf "$work/new" "$work/published"

"$work/build-descriptors" --catalog "$work/catalog.sqlite"

# Signing changes the SQLite file. The manifest carries the checksum the app
# verifies, so it is rewritten against the file that is published.
gzip -9 -k -f "$work/catalog.sqlite"
python3 "$root/catalog/build_catalog.py" --out "$work" --restamp

echo "publishing"
if ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
  gh release create "$tag" --repo "$repo" \
    --title "Catalog (latest)" \
    --notes "Rolling release. Every run of scripts/publish-catalog.sh replaces the assets." \
    --latest=false
fi
gh release upload "$tag" --repo "$repo" --clobber \
  "$work/catalog.sqlite.gz" "$work/catalog-manifest.json"
signed="$(sqlite3 "$work/catalog.sqlite" "SELECT count(*) FROM productArt")"
gh release edit "$tag" --repo "$repo" \
  --notes "Rolling release. Every run of scripts/publish-catalog.sh replaces the assets. Last build: $(date -u +%Y-%m-%dT%H:%M:%SZ) on a Mac, with $signed artwork signatures."
echo "published the catalog with $signed signatures"
