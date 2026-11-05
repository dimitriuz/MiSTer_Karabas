#!/usr/bin/env bash
# GHDL run of the clock testbench: analyses the sim-only pll model, the clock units
# (rtl/clk/*.vhd, rtl/replaced/clock.vhd) and sim/tb_clock.vhd, then elaborates and runs
# tb_clock. The last line of its output is the verdict, `tb_clock: PASS` or
# `tb_clock: FAIL <reason>`, and it exits non-zero on anything but PASS.
# Called through tools/sim.sh (GHDL is in the karabas-sim:1 image):
#   tools/sim.sh sim/run_tb_clock.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# --std=93c -fsynopsys: the upstream units and the replaced clock use std_logic_unsigned.
# The work library goes to build/ (gitignored); GHDL's mcode backend elaborates inside
# `ghdl -r`, there is no separate executable. The ghdl command comes before its options.
STD="--std=93c -fsynopsys"
WORK=build/sim
SRC="sim/models/pll_model.vhd rtl/clk/clkmux2.vhd rtl/clk/clkgate.vhd
     rtl/clk/clkdiv4.vhd rtl/replaced/clock.vhd sim/tb_clock.vhd"

LOG=""
# Whatever fails — analysis, elaboration, the run, or the check of the verdict — the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_clock: FAIL the run did not print it (exit $code), see the GHDL log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p "$WORK"
# shellcheck disable=SC2086
ghdl -a $STD --workdir="$WORK" $SRC
# shellcheck disable=SC2086
ghdl -r $STD --workdir="$WORK" tb_clock --stop-time=600us > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of the main process); grep decides
# here, so that a run that hangs to the stop time or dies in GHDL also fails.
grep -q 'tb_clock: PASS' "$LOG"
echo "tb_clock: PASS"
