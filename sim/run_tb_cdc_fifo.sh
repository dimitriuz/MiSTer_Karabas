#!/usr/bin/env bash
# GHDL run of the asynchronous FIFO testbench: analyses rtl/mem/cdc_fifo.vhd
# (the VHDL cell the build instantiates in rtl/video/video_cdc.sv) and
# sim/tb_cdc_fifo.vhd, elaborates and runs tb_cdc_fifo. The last line of the
# output is the verdict, `tb_cdc_fifo: PASS` or `tb_cdc_fifo: FAIL <case>
# <reason>`, and it exits non-zero on anything but PASS.
# Called through tools/sim.sh (GHDL is in the karabas-sim:1 image):
#   tools/sim.sh sim/run_tb_cdc_fifo.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# --std=93c -fsynopsys: as for every other VHDL unit of the sim
STD="--std=93c -fsynopsys"
WORK=build/sim
SRC="rtl/mem/cdc_fifo.vhd sim/tb_cdc_fifo.vhd"

LOG=""
# Whatever fails - analysis, elaboration, the run, or the check of the verdict -
# the verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_cdc_fifo: FAIL the run did not print it (exit $code), see the GHDL log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p "$WORK"
# shellcheck disable=SC2086
ghdl -a $STD --workdir="$WORK" $SRC
# The two random cases take ~220 us of simulation time; the stop time only
# catches a run that never reaches its verdict.
# shellcheck disable=SC2086
ghdl -r $STD --workdir="$WORK" tb_cdc_fifo --stop-time=2ms > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of the main process); grep
# decides here, so that a run that hangs to the stop time or dies in GHDL also
# fails.
grep -q 'tb_cdc_fifo: PASS' "$LOG"
echo "tb_cdc_fifo: PASS"