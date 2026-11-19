#!/usr/bin/env bash
# Icarus run of sim/tb_hotkeys.sv (rtl/host/hotkeys.sv). The last line is the verdict.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v iverilog >/dev/null 2>&1; then exec tools/sim.sh sim/run_tb_hotkeys.sh; fi
mkdir -p build/sim
iverilog -g2012 -o build/sim/tb_hotkeys.vvp sim/tb_hotkeys.sv rtl/host/hotkeys.sv
vvp -n build/sim/tb_hotkeys.vvp | tee build/sim/tb_hotkeys.log
grep -q 'tb_hotkeys: PASS' build/sim/tb_hotkeys.log
