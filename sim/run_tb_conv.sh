#!/usr/bin/env bash
# Icarus run of the TAP/TZX to CSW converter check: rtl/tape/tape_src.sv feeds
# rtl/tape/tape_conv.sv from sim/models/sd_img_model.sv, and the converter's
# bytes are compared with the CSW file that tape.sv already loads on the
# board. Both the TAP and the TZX form must reproduce it byte for byte.
#
# Fixtures are made on the host first (zxtap.py needs only python3):
# hello.tap/.tzx/.csw, all three from tests/zx/hello.bas. Without iverilog
# the script re-executes itself in the karabas-sim image through tools/sim.sh:
#   tools/sim.sh sim/run_tb_conv.sh     # inside the image
#   sim/run_tb_conv.sh                  # from the host: prepare, hop
set -euo pipefail

cd "$(dirname "$0")/.."

PREPARE=1
if [ "${1:-}" = "--no-prepare" ]; then PREPARE=0; shift; fi
if [ "$#" -ne 0 ]; then echo "usage: $0 [--no-prepare]" >&2; exit 2; fi

if [ "$PREPARE" = 1 ]; then
    mkdir -p build/sim
    python3 tools/zxtap.py bas tests/zx/hello.bas build/sim/hello.tap --autostart 10
    python3 tools/zxtap.py tzx build/sim/hello.tap build/sim/hello.tzx
    python3 tools/zxtap.py csw build/sim/hello.tap build/sim/hello.csw
    python3 - <<'PY'
from pathlib import Path

out = Path("build/sim")
for name in ("hello.tap", "hello.tzx", "hello.csw"):
    data = (out / name).read_bytes()
    (out / (name + ".hex")).write_text("".join("%02x\n" % b for b in data))
# tb_conv compares against the CSW's length; a fixture change must be visible
# here, not as a silent pass.
size = (out / "hello.csw").stat().st_size
assert size == 17037, "tb_conv: hello.csw is %d bytes, the test expects 17037; update it" % size
PY
fi

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_conv.sh --no-prepare
fi

for f in hello.tap.hex hello.tzx.hex hello.csw.hex; do
    if [ ! -f "build/sim/$f" ]; then
        echo "run_tb_conv: no build/sim/$f; run this script once on the host" >&2
        echo "tb_conv: FAIL no fixtures"
        exit 1
    fi
done

LOG=""
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_conv: FAIL the run did not print it (exit $code), see the log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

iverilog -g2012 -o build/sim/tb_conv.vvp \
    sim/tb_conv.sv \
    sim/models/sd_img_model.sv \
    rtl/tape/tape_src.sv \
    rtl/tape/tape_conv.sv
vvp build/sim/tb_conv.vvp > "$LOG" 2>&1 || true
cat "$LOG"
grep -q 'tb_conv: PASS' "$LOG"
echo "tb_conv: PASS"