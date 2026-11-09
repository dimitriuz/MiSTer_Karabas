#!/usr/bin/env bash
# Icarus run of the tape_src testbench: compiles sim/tb_tape_src.sv with
# sim/models/sd_img_model.sv (the hps_io SD block model) and
# rtl/tape/tape_src.sv (the DUT) using iverilog -g2012. The last line of the
# output is the verdict, `tb_tape_src: PASS` or `tb_tape_src: FAIL <reason>`,
# and it exits non-zero on anything but PASS.
#
# The fixtures are made on the host first (zxtap.py needs only python3, but
# the sim image has no git and the other benches keep host prep there too):
# hello.tap/.tzx/.csw from tools/zxtap.py, and the raw byte files with their
# $readmemh hex forms. Icarus lives in the karabas-sim image: without it this
# script re-executes itself there through tools/sim.sh, passing --no-prepare:
#   tools/sim.sh sim/run_tb_tape_src.sh     # inside the image
#   sim/run_tb_tape_src.sh                  # from the host: prepare, hop
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


def raw(name, length, seed, first):
    # the sector term keeps the same offset in different sectors different;
    # the CSW magic keeps tape_src in CSW passthrough mode (the converter is
    # exercised end to end by tb_tape_play)
    magic = b"Compressed Square Wave\x1a"
    data = bytes(magic[i] if i < len(magic)
                 else ((i * seed + (i // 512) * 101 + first) & 0xFF)
                 for i in range(length))
    (out / name).with_suffix(".bin").write_bytes(data)
    (out / name).with_suffix(".hex").write_text(
        "".join("%02x\n" % b for b in data))


def hexof(name):
    data = (out / name).read_bytes()
    (out / (name + ".hex")).write_text(
        "".join("%02x\n" % b for b in data))


raw("raw3000", 3000, 37, 11)   # file A: byte 0 = 11
raw("raw100", 100, 29, 3)
raw("raw_b", 600, 53, 7)       # file B: byte 0 = 7, not A's 11
hexof("hello.tap")
hexof("hello.tzx")
hexof("hello.csw")
PY
fi

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_tape_src.sh --no-prepare
fi

for f in hello.tap.hex hello.tzx.hex hello.csw.hex raw3000.hex raw100.hex raw_b.hex; do
    if [ ! -f "build/sim/$f" ]; then
        echo "run_tb_tape_src: no build/sim/$f; run this script once on the host" >&2
        echo "tb_tape_src: FAIL no fixtures"
        exit 1
    fi
done

LOG=""
# Whatever fails - compilation, the run, or the check of the verdict - the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_tape_src: FAIL the run did not print it (exit $code), see the Icarus log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

iverilog -g2012 -o build/sim/tb_tape_src.vvp \
    sim/tb_tape_src.sv \
    sim/models/sd_img_model.sv \
    rtl/tape/tape_src.sv \
    rtl/tape/tape_conv.sv
vvp build/sim/tb_tape_src.vvp > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of its initial block);
# grep decides here, so a run that dies inside VVP fails as well.
grep -q 'tb_tape_src: PASS' "$LOG"
echo "tb_tape_src: PASS"