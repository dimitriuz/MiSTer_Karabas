#!/usr/bin/env bash
# Upstream-change tripwire for the units the port replaces. For every line
# `sha256 <path> <hash>` in tools/upstream-pins.txt, fails with
#   check_upstream: <file> changed upstream — re-port rtl/replaced/<file>
# when the hash of upstream/karabas-go-core-profi/<path> differs. Also fails when
# src/rtl/profi.vhd mentions clk_adc on any lines other than exactly the three
# that exist at the pinned upstream (its signal declaration, `CLK_ADC => clk_adc`,
# `ADC_CLK <= clk_adc`): Task 2 uses CLK_ADC as the pixel-enable carrier, so any
# upstream change to it must be re-ported deliberately.
# Prints `check_upstream: OK` and exits 0 when everything matches.
set -euo pipefail

cd "$(dirname "$0")/.."
UP=upstream/karabas-go-core-profi
PINS=tools/upstream-pins.txt

while read -r algo path hash; do
    case "$algo" in ''|'#'*) continue ;; esac
    if [ "$algo" != sha256 ]; then
        echo "check_upstream: unknown algorithm $algo in $PINS" >&2
        exit 2
    fi
    if [ ! -f "$UP/$path" ]; then
        echo "check_upstream: $path changed upstream — re-port rtl/replaced/$(basename "$path")" >&2
        exit 1
    fi
    actual=$(sha256sum "$UP/$path" | cut -d' ' -f1)
    if [ "$actual" != "$hash" ]; then
        echo "check_upstream: $(basename "$path") changed upstream — re-port rtl/replaced/$(basename "$path")"
        exit 1
    fi
done < "$PINS"

count=$(grep -c clk_adc "$UP/src/rtl/profi.vhd" || true)
if [ "$count" -ne 3 ]; then
    echo "check_upstream: profi.vhd mentions clk_adc on $count lines, expected exactly 3 (signal declaration, CLK_ADC => clk_adc, ADC_CLK <= clk_adc) — re-port the pixel-enable carrier"
    exit 1
fi

echo "check_upstream: OK"
