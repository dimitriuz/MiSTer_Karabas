#!/usr/bin/env bash
# GHDL run of the SDRAM bridge testbench: analyses the sim-only sdram client model,
# the bridge units (rtl/mem/*.vhd) and sim/tb_sram_bridge.vhd, elaborates and runs
# tb_sram_bridge, then analyses rtl/replaced/memory.vhd, which instantiates the
# bridge and whose kg_sdpram/sdram are components - so it analyses on its own.
# The last line of the output is the verdict, `tb_sram_bridge: PASS` or
# `tb_sram_bridge: FAIL <reason>`, and it exits non-zero on anything but PASS.
# Called through tools/sim.sh (GHDL is in the karabas-sim:1 image):
#   tools/sim.sh sim/run_tb_sram_bridge.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# --std=93c -fsynopsys: as for the upstream units (std_logic_unsigned) and the
# replaced memory. The work library goes to build/ (gitignored); GHDL's mcode
# backend elaborates inside `ghdl -r`, there is no separate executable.
STD="--std=93c -fsynopsys"
WORK=build/sim
SRC="sim/models/sdram_model.vhd rtl/mem/cdc_fifo.vhd rtl/mem/sram_bridge.vhd
     sim/tb_sram_bridge.vhd"

LOG=""
# Whatever fails - analysis, elaboration, the run, or the check of the verdict - the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_sram_bridge: FAIL the run did not print it (exit $code), see the GHDL log above"
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
ghdl -r $STD --workdir="$WORK" tb_sram_bridge --stop-time=90ms > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of the main process); grep decides
# here, so that a run that hangs to the stop time or dies in GHDL also fails. The cases
# end at 41 ms of simulation time, so the stop time only catches a case that never
# finishes.
grep -q 'tb_sram_bridge: PASS' "$LOG"
# replaced/memory.vhd instantiates `entity work.sram_bridge` (analysed above into the
# same work) and binds kg_sdpram/sdram through component declarations.
echo "ghdl -a rtl/replaced/memory.vhd"
# shellcheck disable=SC2086
ghdl -a $STD --workdir="$WORK" rtl/replaced/memory.vhd
echo "tb_sram_bridge: PASS"
