#!/usr/bin/env bash
# Icarus run of the PS/2 -> USB HID keyboard testbench: compiles
# sim/tb_ps2_hid.sv with rtl/host/ps2_hid.sv (iverilog -g2012; the module
# `include`s rtl/host/ps2_hid_table.svh, on the -I path) and runs it. The last
# line of the output is the verdict, `tb_ps2_hid: PASS` or
# `tb_ps2_hid: FAIL <reason>`, and it exits non-zero on anything but PASS.
# Called through tools/sim.sh (Icarus is in the karabas-sim:1 image):
#   tools/sim.sh sim/run_tb_ps2_hid.sh
set -euo pipefail

cd "$(dirname "$0")/.."

LOG=""
# Whatever fails - compilation, the run, or the check of the verdict - the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_ps2_hid: FAIL the run did not print it (exit $code), see the Icarus log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p build/sim
iverilog -g2012 -I rtl/host -o build/sim/tb_ps2_hid.vvp \
    sim/tb_ps2_hid.sv rtl/host/ps2_hid.sv
vvp build/sim/tb_ps2_hid.vvp > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of its initial block);
# grep decides here, so a run that dies inside VVP fails as well.
grep -q 'tb_ps2_hid: PASS' "$LOG"
echo "tb_ps2_hid: PASS"
