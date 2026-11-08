#!/usr/bin/env bash
# Icarus run of the video CDC testbench: compiles sim/tb_video_cdc.sv with
# rtl/video/video_cdc.sv and the Icarus-side behaviour model of the async
# FIFO (sim/models/cdc_fifo_model.sv - Icarus cannot bind the VHDL
# rtl/mem/cdc_fifo.vhd, whose own tests live on the GHDL side in
# tb_cdc_fifo). The last line of the output is the verdict,
# `tb_video_cdc: PASS` or `tb_video_cdc: FAIL <reason>`, and it exits
# non-zero on anything but PASS.
# Called through tools/sim.sh (Icarus is in the karabas-sim:1 image):
#   tools/sim.sh sim/run_tb_video_cdc.sh
set -euo pipefail

cd "$(dirname "$0")/.."

LOG=""
# Whatever fails - compilation, the run, or the check of the verdict - the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_video_cdc: FAIL the run did not print it (exit $code), see the Icarus log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p build/sim
iverilog -g2012 -o build/sim/tb_video_cdc.vvp \
    sim/tb_video_cdc.sv rtl/video/video_cdc.sv sim/models/cdc_fifo_model.sv
vvp build/sim/tb_video_cdc.vvp > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of its initial block);
# grep decides here, so a run that dies inside VVP fails as well.
grep -q 'tb_video_cdc: PASS' "$LOG"
echo "tb_video_cdc: PASS"
