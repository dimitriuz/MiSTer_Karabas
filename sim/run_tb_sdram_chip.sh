#!/usr/bin/env bash
# GHDL run of the SDRAM chip model testbench: analyses sim/models/sdram_chip.vhd
# (the chip model and its sdram_chip_pkg) and sim/tb_sdram_chip.vhd, elaborates
# and runs tb_sdram_chip. The last line of the output is the verdict,
# `tb_sdram_chip: PASS` or `tb_sdram_chip: FAIL <reason>`, and it exits non-zero
# on anything but PASS. Called through tools/sim.sh (GHDL is in the
# karabas-sim:1 image):
#   tools/sim.sh sim/run_tb_sdram_chip.sh
# No --assert-level flag: the model's rule reports carry severity error and
# must not end the run - GHDL's default stops on failure only, which is what
# the verdict's failure report uses.
set -euo pipefail

cd "$(dirname "$0")/.."

# --std=93c -fsynopsys: as for every other VHDL unit of the sim
STD="--std=93c -fsynopsys"
WORK=build/sim
SRC="sim/models/sdram_chip.vhd sim/tb_sdram_chip.vhd"

LOG=""
# Whatever fails - analysis, elaboration, the run, or the check of the verdict -
# the verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_sdram_chip: FAIL the run did not print it (exit $code), see the GHDL log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p "$WORK"
# shellcheck disable=SC2086
ghdl -a $STD --workdir="$WORK" $SRC
# The phases run to ~110 us of simulation time; the stop time only catches a
# phase that never ends.
# shellcheck disable=SC2086
ghdl -r $STD --workdir="$WORK" tb_sdram_chip --stop-time=20ms > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of the main process); grep
# decides here, so that a run that hangs to the stop time or dies in GHDL also
# fails.
grep -q 'tb_sdram_chip: PASS' "$LOG"
echo "tb_sdram_chip: PASS"
