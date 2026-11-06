#!/usr/bin/env bash
# GHDL run of the no-wait SDRAM controller testbench: analyses the sim-only
# pll and SDRAM chip models, the clock units (rtl/clk/*.vhd,
# rtl/replaced/clock.vhd), rtl/mem/sdram_nowait.vhd and sim/tb_sdram_nowait.vhd,
# then elaborates and runs tb_sdram_nowait. The last line of the output is the
# verdict, `tb_sdram_nowait: PASS` or `tb_sdram_nowait: FAIL <reason>`, and it
# exits non-zero on anything but PASS. Called through tools/sim.sh (GHDL is in
# the karabas-sim:1 image):
#   tools/sim.sh sim/run_tb_sdram_nowait.sh
# The controller's sim-only assertions and the testbench verdict carry
# severity failure: GHDL's default stops on failure, which the trap below
# reports as a FAIL verdict too.
set -euo pipefail

cd "$(dirname "$0")/.."

# --std=93c -fsynopsys: as for every other VHDL unit of the sim
STD="--std=93c -fsynopsys"
WORK=build/sim
SRC="sim/models/pll_model.vhd sim/models/sdram_chip.vhd
     rtl/clk/clkmux2.vhd rtl/clk/clkgate.vhd rtl/clk/clkdiv4.vhd
     rtl/replaced/clock.vhd rtl/mem/sdram_nowait.vhd
     sim/tb_sdram_nowait.vhd"

LOG=""
# Whatever fails - analysis, elaboration, the run, or the check of the verdict -
# the verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_sdram_nowait: FAIL the run did not print it (exit $code), see the GHDL log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p "$WORK"
# shellcheck disable=SC2086
ghdl -a $STD --workdir="$WORK" $SRC
# The full case matrix runs to ~40 ms of simulation time; the stop time only
# catches a case that never ends.
# shellcheck disable=SC2086
ghdl -r $STD --workdir="$WORK" tb_sdram_nowait --stop-time=60ms > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of the main process); grep
# decides here, so that a run that hangs to the stop time or dies in GHDL also
# fails.
grep -q 'tb_sdram_nowait: PASS' "$LOG"
echo "tb_sdram_nowait: PASS"
