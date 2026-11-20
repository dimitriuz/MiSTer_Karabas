#!/usr/bin/env bash
# Icarus run of sim/tb_pc_trace.sv. The last line is `tb_pc_trace: PASS` or `FAIL ...`.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v iverilog >/dev/null 2>&1; then exec tools/sim.sh sim/run_tb_pc_trace.sh; fi
mkdir -p build/sim
iverilog -g2012 -o build/sim/tb_pc_trace.vvp sim/tb_pc_trace.sv rtl/host/pc_trace.sv
vvp -n build/sim/tb_pc_trace.vvp | tee build/sim/tb_pc_trace.log
grep -q 'tb_pc_trace: PASS' build/sim/tb_pc_trace.log
