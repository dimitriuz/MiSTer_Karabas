#!/usr/bin/env bash
# GHDL run of the no-wait system testbench: the clock unit (with the sim pll
# model), the upstream T80s with the prepare_upstream TS_O/MC_O rewrites
# (analysed from the generated tree), the no-wait controller
# rtl/mem/sdram_nowait.vhd, the SDRAM chip model with the small geometry of
# the tb_sdram_nowait run and the testbench itself. The last line of the
# output is the verdict, `tb_turbo_nowait: PASS` or `tb_turbo_nowait: FAIL
# <reason>`, and it exits non-zero on anything but PASS. Called through
# tools/sim.sh (GHDL is in the karabas-sim:1 image):
#   tools/sim.sh sim/run_tb_turbo_nowait.sh
# The upstream tree is prepared first (the sim image has no git).
set -euo pipefail

cd "$(dirname "$0")/.."

PREPARE=1
if [ "${1:-}" = "--no-prepare" ]; then PREPARE=0; shift; fi
if [ "$#" -ne 0 ]; then echo "usage: $0 [--no-prepare]" >&2; exit 2; fi

if [ "$PREPARE" = 1 ] && command -v git >/dev/null 2>&1; then
    python3 tools/prepare_upstream.py
fi

if ! command -v ghdl >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_turbo_nowait.sh --no-prepare
fi

# the T80s comes from the generated tree
T80=build/upstream/src/rtl/t80se
if [ ! -f "$T80/T80s.vhd" ]; then
    echo "run_tb_turbo_nowait: $T80 missing - run python3 tools/prepare_upstream.py first" >&2
    echo "tb_turbo_nowait: FAIL $T80 missing (run tools/prepare_upstream.py)"
    exit 1
fi

# --std=93c -fsynopsys -fexplicit: as in sim/run_tb_turbo_wait.sh (the T80
# uses std_logic_unsigned; -fexplicit resolves its operator ambiguity)
STD="--std=93c -fsynopsys -fexplicit"
WORK=build/sim
SRC="sim/models/pll_model.vhd rtl/clk/clkmux2.vhd rtl/clk/clkgate.vhd
     rtl/clk/clkdiv4.vhd rtl/replaced/clock.vhd
     sim/models/sdram_chip.vhd rtl/mem/sdram_nowait.vhd
     $T80/T80_Pack.vhd $T80/T80_MCode.vhd $T80/T80_ALU.vhd $T80/T80_Reg.vhd
     $T80/T80.vhd $T80/T80s.vhd sim/tb_turbo_nowait.vhd"

LOG=""
# Whatever fails - analysis, elaboration, the run, or the check of the verdict -
# the verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_turbo_nowait: FAIL the run did not print it (exit $code), see the GHDL log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p "$WORK"
# shellcheck disable=SC2086
ghdl -a $STD --workdir="$WORK" $SRC
# Eight phases (two DS80 modes, four turbos each) of at most 9 ms program
# time plus the 100 us init; the stop time only catches a phase that never
# ends.
# shellcheck disable=SC2086
ghdl -r $STD --workdir="$WORK" tb_turbo_nowait --stop-time=40ms "$@" > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of the main process); grep
# decides here, so that a run that hangs to the stop time or dies in GHDL also
# fails.
grep -q 'tb_turbo_nowait: PASS' "$LOG"
echo "tb_turbo_nowait: PASS"
