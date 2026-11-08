#!/usr/bin/env bash
# Icarus run of the General Sound memory testbench: compiles
# sim/tb_gs_mem.sv with sim/models/ddram_model.sv (the 2 MB DDRAM Avalon
# slave) and rtl/mem/gs_mem.sv (the DUT) using iverilog -g2012. No prepared
# upstream is needed. The last line of the output is the verdict,
# `tb_gs_mem: PASS` or `tb_gs_mem: FAIL <reason>`, and it exits non-zero on
# anything but PASS.
#
# Icarus lives in the karabas-sim image: without it this script re-executes
# itself there through tools/sim.sh:
#   tools/sim.sh sim/run_tb_gs_mem.sh     # inside the image
#   sim/run_tb_gs_mem.sh                  # from the host: hop
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_gs_mem.sh
fi

LOG=""
# Whatever fails - compilation, the run, or the check of the verdict - the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_gs_mem: FAIL the run did not print it (exit $code), see the Icarus log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p build/sim
iverilog -g2012 -o build/sim/tb_gs_mem.vvp \
    sim/tb_gs_mem.sv \
    sim/models/ddram_model.sv \
    rtl/mem/gs_mem.sv
vvp build/sim/tb_gs_mem.vvp > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of its initial block);
# grep decides here, so a run that dies inside VVP fails as well.
grep -q 'tb_gs_mem: PASS' "$LOG"
echo "tb_gs_mem: PASS"