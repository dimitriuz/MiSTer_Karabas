#!/usr/bin/env bash
# Icarus run of sim/tb_core_beacon.sv. The last line is `tb_core_beacon: PASS` or `FAIL ...`.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v iverilog >/dev/null 2>&1; then exec tools/sim.sh sim/run_tb_core_beacon.sh; fi
mkdir -p build/sim
iverilog -g2012 -o build/sim/tb_core_beacon.vvp sim/tb_core_beacon.sv rtl/host/core_beacon.sv
vvp -n build/sim/tb_core_beacon.vvp | tee build/sim/tb_core_beacon.log
grep -q 'tb_core_beacon: PASS' build/sim/tb_core_beacon.log
