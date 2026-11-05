#!/usr/bin/env bash
# GHDL run of the turbo-wait system testbench: the clock unit (with the sim
# pll model), the upstream T80s (analysed from the prepare_upstream output),
# the SDRAM bridge (with cdc_fifo and the sim sdram client model) and the
# testbench itself. The last line of the output is the verdict,
# `tb_turbo_wait: PASS` or `tb_turbo_wait: FAIL <reason>`, and it exits non-zero
# on anything but PASS. Called through tools/sim.sh (GHDL is in the
# karabas-sim:1 image):
#   tools/sim.sh sim/run_tb_turbo_wait.sh
# Extra arguments reach ghdl -r, e.g. the RED run without the wait path:
#   tools/sim.sh sim/run_tb_turbo_wait.sh -gWAIT_EN=false
set -euo pipefail

cd "$(dirname "$0")/.."

# the T80s comes from the generated tree; the sim image has no git, so the
# mirror must already exist (tools/prepare_upstream.py, run by tools/build.sh)
T80=build/upstream/src/rtl/t80se
if [ ! -f "$T80/T80s.vhd" ]; then
    echo "run_tb_turbo_wait: $T80 missing - run python3 tools/prepare_upstream.py first" >&2
    echo "tb_turbo_wait: FAIL $T80 missing (run tools/prepare_upstream.py)"
    exit 1
fi

# --std=93c -fsynopsys: as for the upstream units (the T80 uses
# std_logic_unsigned) and the replaced clock. -fexplicit: T80.vhd compares
# std_logic_vectors with both std_logic_1164 and std_logic_unsigned visible, the
# ambiguity GHDL only resolves under the explicit-conversion rules.
STD="--std=93c -fsynopsys -fexplicit"
WORK=build/sim
SRC="sim/models/pll_model.vhd rtl/clk/clkmux2.vhd rtl/clk/clkgate.vhd
     rtl/replaced/clock.vhd rtl/mem/cdc_fifo.vhd rtl/mem/sram_bridge.vhd
     sim/models/sdram_model.vhd
     $T80/T80_Pack.vhd $T80/T80_MCode.vhd $T80/T80_ALU.vhd $T80/T80_Reg.vhd
     $T80/T80.vhd $T80/T80s.vhd sim/tb_turbo_wait.vhd"

LOG=""
# Whatever fails - analysis, elaboration, the run, or the check of the verdict -
# the verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_turbo_wait: FAIL the run did not print it (exit $code), see the GHDL log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p "$WORK"
# shellcheck disable=SC2086
ghdl -a $STD --workdir="$WORK" $SRC
# The four phases need their startup windows plus at most 16 ms of program
# time; the stop time only catches a phase that never ends.
# shellcheck disable=SC2086
ghdl -r $STD --workdir="$WORK" tb_turbo_wait --stop-time=60ms "$@" > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of the main process); grep
# decides here, so that a run that hangs to the stop time or dies in GHDL also
# fails.
grep -q 'tb_turbo_wait: PASS' "$LOG"
echo "tb_turbo_wait: PASS"
