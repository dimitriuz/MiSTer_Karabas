#!/usr/bin/env bash
# Icarus run of the mount settle testbench: compiles sim/tb_mount_settle.sv
# with rtl/host/mount_settle.sv (iverilog -g2012) and runs it. The last line
# of the output is the verdict, `tb_mount_settle: PASS` or
# `tb_mount_settle: FAIL <case>`, and it exits non-zero on anything but
# PASS. Called through tools/sim.sh (Icarus is in the karabas-sim:1 image):
#   tools/sim.sh sim/run_tb_mount_settle.sh
set -euo pipefail

cd "$(dirname "$0")/.."

LOG=""
# Whatever fails - compilation, the run, or the check of the verdict - the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_mount_settle: FAIL the run did not print it (exit $code), see the Icarus log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p build/sim
iverilog -g2012 -o build/sim/tb_mount_settle.vvp \
    sim/tb_mount_settle.sv rtl/host/mount_settle.sv
vvp build/sim/tb_mount_settle.vvp > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of its initial block);
# grep decides here, so a run that dies inside VVP fails as well.
grep -q 'tb_mount_settle: PASS' "$LOG"
echo "tb_mount_settle: PASS"
