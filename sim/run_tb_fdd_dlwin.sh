#!/usr/bin/env bash
# Icarus run of the small-window download testbench: sim/tb_fdd_dlwin.sv
# against rtl/disk/fdd_src.sv alone (no store, no DDRAM - the fill port is
# answered by a toggle-ack responder inside the bench).
#
# The point of a separate bench is the compile-time switch: fdd_src keeps its
# real 2 MiB window (the store's addressing) unless FDD_DL_SMALL is defined,
# and reaching that window with 2 MiB of streamed FDI is not a simulation worth
# running. Here the window is 4 KiB (the same value the bench calls WIN) and
# the case streams 4 KiB + 320 bytes of data area, which is what the branch
# under test needs: a byte past the window has to be skipped and the download
# still has to end with its ready word. Quartus never sees the switch:
# rtl/disk/fdd_src.sv is not in the project and the define is not passed.
#
# Icarus lives in the karabas-sim image, so without it this script re-executes
# itself there through tools/sim.sh:
#   tools/sim.sh sim/run_tb_fdd_dlwin.sh   # inside the image
#   sim/run_tb_fdd_dlwin.sh                # from the host: hop
#
# The last line of the output is the verdict, `tb_fdd_dlwin: PASS` or
# `tb_fdd_dlwin: FAIL <reason>`; anything but PASS exits non-zero.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_fdd_dlwin.sh
fi
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_fdd_dlwin: FAIL the run did not print it (exit $code), see the Icarus log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p build/sim
iverilog -g2012 -DFDD_DL_SMALL -o build/sim/tb_fdd_dlwin.vvp \
    sim/tb_fdd_dlwin.sv \
    sim/models/altsyncram_model.sv \
    rtl/disk/fdd_src.sv
vvp build/sim/tb_fdd_dlwin.vvp > "$LOG" 2>&1 || true
cat "$LOG"
grep -q 'tb_fdd_dlwin: PASS' "$LOG"
echo "tb_fdd_dlwin: PASS"
