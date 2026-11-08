#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

out=build/taps
mkdir -p "$out"

for src in tests/zx/*.bas; do
    stem=$(basename "$src" .bas)
    python3 tools/zxtap.py bas "$src" "$out/$stem.tap" --autostart 10
    python3 tools/zxtap.py tzx "$out/$stem.tap" "$out/$stem.tzx"
    python3 tools/zxtap.py csw "$out/$stem.tap" "$out/$stem.csw"
    printf '%s\n' "$out/$stem.tap" "$out/$stem.tzx" "$out/$stem.csw"
done