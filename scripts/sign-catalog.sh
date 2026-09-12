#!/usr/bin/env bash
# Signs the artwork in the published catalog on this Mac, then publishes the
# catalog again.
#
# The nightly GitHub Action builds the catalog and carries the published
# signatures forward, but it does not sign. This script signs each product that
# has no signature. The first run signs about 76,000 cards. After that, a run
# signs only the new products.
#
#   caffeinate -i scripts/sign-catalog.sh
#
# `caffeinate -i` stops the Mac from sleeping during a long run. You can stop the
# script with Ctrl-C at any time. The tool writes signatures in batches to
# build/sign/catalog.sqlite, and the next run continues from that file.
#
# Needs macOS with a neural engine, Xcode's swiftc, and gh signed in with write
# access to the repo.

set -euo pipefail

repo=ajhollowayvrm/binderbooks
tag=catalog-latest
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/build/sign"
mkdir -p "$work"

manifest_sha() {
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["sha256"])' "$1"
}

echo "building the signing tool"
swiftc -O "$root/catalog/build_descriptors.swift" "$root/ios/Sources/Scan/CardArtDescriptor.swift" \
  -o "$work/build-descriptors"

while true; do
  rm -rf "$work/incoming"
  mkdir -p "$work/incoming"
  echo "downloading the published catalog"
  gh release download "$tag" --repo "$repo" --dir "$work/incoming" \
    --pattern catalog.sqlite.gz --pattern catalog-manifest.json
  base_sha="$(manifest_sha "$work/incoming/catalog-manifest.json")"
  gunzip "$work/incoming/catalog.sqlite.gz"

  # Copy the signatures from an earlier run of this script into the downloaded
  # catalog, published or not, so that no card is signed twice.
  if [ -f "$work/catalog.sqlite" ]; then
    python3 "$root/catalog/merge_descriptors.py" \
      --new "$work/incoming/catalog.sqlite" --old "$work/catalog.sqlite"
  fi
  mv "$work/incoming/catalog.sqlite" "$work/catalog.sqlite"
  mv "$work/incoming/catalog-manifest.json" "$work/catalog-manifest.json"

  "$work/build-descriptors" --catalog "$work/catalog.sqlite"

  gzip -9 -k -f "$work/catalog.sqlite"
  python3 "$root/catalog/build_catalog.py" --out "$work" --restamp

  # The nightly build can publish while this script signs. An upload then would
  # replace that newer catalog with an older one. So compare the release with
  # the one this run started from. If it changed, start again from the new
  # release. Only its new products need a signature.
  rm -rf "$work/check"
  mkdir -p "$work/check"
  gh release download "$tag" --repo "$repo" --dir "$work/check" --pattern catalog-manifest.json
  if [ "$(manifest_sha "$work/check/catalog-manifest.json")" = "$base_sha" ]; then
    break
  fi
  echo "the release changed during the signing, so the run starts again from the new release"
done

echo "publishing"
gh release upload "$tag" --repo "$repo" --clobber \
  "$work/catalog.sqlite.gz" "$work/catalog-manifest.json"
signed="$(sqlite3 "$work/catalog.sqlite" "SELECT count(*) FROM productArt")"
gh release edit "$tag" --repo "$repo" \
  --notes "Rolling release. Every successful build replaces the assets. Artwork signed on a Mac at $(date -u +%Y-%m-%dT%H:%M:%SZ): $signed signatures."
echo "published $signed signatures"
