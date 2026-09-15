#!/usr/bin/env bash
# Builds the Simplified Chinese catalog on this Mac from PikaQian, signs its
# artwork, and copies the file to Box. Nothing goes to GitHub: the data is for
# AJ alone, and PikaQian publishes no terms for sharing it.
#
#   caffeinate -i scripts/build-chinese-catalog.sh
#       Fetch every set and card, and sign the artwork. About 200 requests.
#
#   scripts/build-chinese-catalog.sh --price ~/Downloads/collection.json
#       Price the Chinese cards in a collection export. No rebuild. One request
#       for each Chinese product he holds. Writes chinese-prices.csv, sorted by
#       value, for the eBay listing decision.
#
#   scripts/build-chinese-catalog.sh --sets cbb4c,csv6c
#       Build only these sets, for a quick test.
#
# Then on the phone: Catalog, Simplified Chinese, Import. Pick the file in Box.
#
# Needs the PikaQian key in PIKAQIAN_API_KEY or ~/.config/binderbooks/pikaqian-key,
# Xcode's swiftc, and python3. Box Drive is optional. --no-box skips the copy.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$root/build/chinese"
catalog="$work/chinese-catalog.sqlite"
report="$work/chinese-prices.csv"
box="$HOME/Library/CloudStorage/Box-Box/BinderBooks"
export_file=""
sets=""
copy_to_box=1

while [ $# -gt 0 ]; do
  case "$1" in
    --price) export_file="${2:?--price needs a collection export}"; shift 2 ;;
    --sets) sets="${2:?--sets needs set ids}"; shift 2 ;;
    --no-box) copy_to_box=0; shift ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$work"

echo "running the unit tests"
python3 -m unittest discover -s "$root/catalog"

if [ -z "$export_file" ]; then
  echo "building the signing tool"
  swiftc -O "$root/catalog/build_descriptors.swift" "$root/ios/Sources/Scan/CardArtDescriptor.swift" \
    -o "$work/build-descriptors"

  echo "building the Chinese catalog from PikaQian"
  python3 "$root/catalog/build_chinese.py" build --out "$work" ${sets:+--sets "$sets"}

  echo "signing the artwork"
  "$work/build-descriptors" --catalog "$catalog"
else
  if [ ! -f "$catalog" ]; then
    echo "no catalog at $catalog. Run this script without --price first." >&2
    exit 1
  fi
  echo "pricing the Chinese cards in $export_file"
  python3 "$root/catalog/build_chinese.py" price --catalog "$catalog" --export "$export_file" --report "$report"
fi

if [ "$copy_to_box" = 1 ]; then
  if [ -d "$(dirname "$box")" ]; then
    mkdir -p "$box"
    cp "$catalog" "$box/"
    if [ -n "$export_file" ]; then
      cp "$report" "$box/"
    fi
    echo "copied to $box"
  else
    echo "Box Drive is not at $(dirname "$box"). The files stay in $work."
  fi
fi
echo "done: $catalog"
