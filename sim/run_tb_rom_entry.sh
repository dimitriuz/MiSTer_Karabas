#!/usr/bin/env bash
# GHDL run of tb_rom_entry (which ROM page the first fetch of an entry address reads).
#   tools/sim.sh sim/run_tb_rom_entry.sh [--no-prepare] [-gEARLY=false]
# -gEARLY=false switches the dos_early term off (the old behaviour): kind 0 must then FAIL.
set -euo pipefail
cd "$(dirname "$0")/.."
PREPARE=1
if [ "${1:-}" = "--no-prepare" ]; then PREPARE=0; shift; fi
if [ "$PREPARE" = 1 ] && command -v git >/dev/null 2>&1; then python3 tools/prepare_upstream.py; fi
if ! command -v ghdl >/dev/null 2>&1; then exec tools/sim.sh sim/run_tb_rom_entry.sh --no-prepare "$@"; fi
UP=build/upstream/src/rtl
STD="--std=93c -fsynopsys -fexplicit"
WORK=build/sim
SRC="sim/models/pll_model.vhd rtl/clk/clkmux2.vhd rtl/clk/clkgate.vhd
     rtl/clk/clkdiv4.vhd rtl/replaced/clock.vhd
     sim/models/sdram_chip.vhd rtl/mem/sdram_nowait.vhd
     sim/models/kg_sdpram.vhd rtl/replaced/memory.vhd
     $UP/t80se/T80_Pack.vhd $UP/t80se/T80_MCode.vhd $UP/t80se/T80_ALU.vhd $UP/t80se/T80_Reg.vhd
     $UP/t80se/T80.vhd $UP/t80se/T80s.vhd $UP/bus/divmmc_map.vhd sim/tb_rom_entry.vhd"
mkdir -p "$WORK"
LOG=$(mktemp); trap 'rm -f "$LOG"' EXIT
# shellcheck disable=SC2086
ghdl -a $STD --workdir="$WORK" $SRC
# shellcheck disable=SC2086
ghdl -r $STD --workdir="$WORK" tb_rom_entry --stop-time="${TB_STOP:-8ms}" "$@" > "$LOG" 2>&1 || true
grep -E "tb_rom_entry|error|Error" "$LOG" | sort | uniq -c | sort -rn | head -80
grep -q 'tb_rom_entry: PASS' "$LOG"
echo "tb_rom_entry: PASS"
