#!/usr/bin/env bash
# Icarus run of sim/tb_td0_lzh.sv: the LZHUF decoder against tools/td0.py on a
# prefix of a real Teledisk file (build/sim/td0/*.in/.out are made from the
# file named by TD0_SRC, default the repository's own fixture).
set -euo pipefail
cd "$(dirname "$0")/.."
PREPARE=1
if [ "${1:-}" = "--no-prepare" ]; then PREPARE=0; fi
OUT=build/sim/td0
if [ "$PREPARE" = 1 ]; then
    mkdir -p "$OUT"
    python3 tools/td0.py fixture "$OUT" --bytes 14000
fi
if ! command -v iverilog >/dev/null 2>&1; then exec tools/sim.sh sim/run_tb_td0_lzh.sh --no-prepare; fi
NC=$(wc -l < "$OUT/lzh.in"); NE=$(wc -l < "$OUT/lzh.out")
iverilog -g2012 -DNC=$NC -DNE=$NE -o build/sim/tb_td0_lzh.vvp sim/tb_td0_lzh.sv rtl/disk/td0_lzh.sv
vvp -n build/sim/tb_td0_lzh.vvp | tee build/sim/tb_td0_lzh.log
grep -q "tb_td0_lzh: PASS" build/sim/tb_td0_lzh.log
