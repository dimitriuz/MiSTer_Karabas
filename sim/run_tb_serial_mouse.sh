#!/usr/bin/env bash
# GHDL run of the serial-mouse testbench (sim/tb_serial_mouse.vhd) against the
# upstream chip with the core's select rewrite applied: the rewrite is taken
# from tools/prepare_upstream.py (SERIAL_MOUSE_REWRITES), applied to the
# upstream file by the host python3 into build/sim/serial_mouse_rewritten.vhd,
# so the bench runs exactly what the build compiles. It then runs the same
# bench against the UNMODIFIED upstream file and requires it to FAIL: that is
# the proof the bench sees the bug the rewrite fixes (CP/M mouse unreadable,
# board 2026-11-18). The last line of the output is the verdict,
# `tb_serial_mouse: PASS` or `tb_serial_mouse: FAIL <reason>`, and the script
# exits non-zero on anything but PASS. GHDL lives in the karabas-sim image;
# without it this script re-executes itself there through tools/sim.sh
# (passing --no-prepare, the image has no git for the host-side step):
#   tools/sim.sh sim/run_tb_serial_mouse.sh
#   sim/run_tb_serial_mouse.sh
set -euo pipefail

cd "$(dirname "$0")/.."

PREPARE=1
if [ "${1:-}" = "--no-prepare" ]; then PREPARE=0; shift; fi
if [ "$#" -ne 0 ]; then echo "usage: $0 [--no-prepare]" >&2; exit 2; fi

UP=upstream/karabas-go-core-profi/src/rtl/mouse
WORK=build/sim/serial_mouse
STD="--std=93c -fsynopsys"

if [ "$PREPARE" = 1 ] && command -v python3 >/dev/null 2>&1; then
    mkdir -p "$WORK"
    python3 - <<'PY'
import sys
sys.path.insert(0, "tools")
import prepare_upstream as m
src = open("upstream/karabas-go-core-profi/src/rtl/mouse/serial_mouse.vhd",
           errors="replace").read()
open("build/sim/serial_mouse/serial_mouse_rewritten.vhd", "w").write(
    m.apply_serial_mouse_rewrites(src))
PY
fi

if ! command -v ghdl >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_serial_mouse.sh --no-prepare
fi

if [ ! -f "$WORK/serial_mouse_rewritten.vhd" ]; then
    echo "run_tb_serial_mouse: no rewritten chip; run this script once on the host" >&2
    echo "tb_serial_mouse: FAIL no rewritten serial_mouse.vhd"
    exit 1
fi

LOG=""
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_serial_mouse: FAIL the run did not print it (exit $code), see the GHDL log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

run() {   # run <label> <chip file>: prints the log, returns the bench's own verdict
    local label=$1 chip=$2
    rm -rf "$WORK/lib_$label"; mkdir -p "$WORK/lib_$label"
    # shellcheck disable=SC2086
    ghdl -a $STD --workdir="$WORK/lib_$label" "$UP/hw_int.vhd" "$chip" sim/tb_serial_mouse.vhd
    # shellcheck disable=SC2086
    ghdl -r $STD --workdir="$WORK/lib_$label" tb_serial_mouse --stop-time=200us > "$LOG" 2>&1 || true
    sed -e 's/^/  /' "$LOG" | grep -E "FAIL|PASS|case|start" || true
    grep -q 'tb_serial_mouse: PASS' "$LOG"
}

echo "== the rewritten chip (what the build compiles) =="
run rewritten "$WORK/serial_mouse_rewritten.vhd"
echo "== the unmodified upstream chip (must FAIL: the mutant) =="
if run upstream "$UP/serial_mouse.vhd"; then
    echo "tb_serial_mouse: FAIL the bench passes on the unmodified upstream chip, it does not see the bug"
    exit 1
fi
echo "tb_serial_mouse: PASS"
