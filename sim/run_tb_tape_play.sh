#!/usr/bin/env bash
# Icarus run of the tape player testbench: rtl/tape/tape.sv (the ZX core's
# player, with the stage 4a deviations listed in files.qip) fed by
# rtl/tape/tape_src.sv (the file from the SD image,
# sim/models/sd_img_model.sv) and the GHDL-synthesised tzxplayer.vhd (the ZX
# player's TZX engine, its lead-in raised to 8064; tape.sv sets its TZX_MS
# generic to CLOCK/1000).
#
# The fixtures are made on the host first (zxtap.py needs only python3):
# hello.tap/.tzx/.csw from tools/zxtap.py and the TAP's hex form the tb reads
# as its reference. GHDL and Icarus live in the karabas-sim image: without
# iverilog this script re-executes itself there through tools/sim.sh, passing
# --no-prepare:
#   tools/sim.sh sim/run_tb_tape_play.sh     # inside the image
#   sim/run_tb_tape_play.sh                  # from the host: prepare, hop
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
PY
fi

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_tape_play.sh --no-prepare
fi

for f in hello.tap.hex hello.tzx hello.csw; do
    if [ ! -f "build/sim/$f" ]; then
        echo "run_tb_tape_play: no build/sim/$f; run this script once on the host" >&2
        echo "tb_tape_play: FAIL no fixtures"
        exit 1
    fi
done

LOG=""
# Whatever fails - ghdl, compilation, the run, or the check of the verdict -
# the verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_tape_play: FAIL the run did not print it (exit $code), see the log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

# TZX_MS = tape.sv's CLOCK/1000 = 3500 (ce periods per millisecond)
# GHDL synthesis is minutes on this part, so it is cached: the netlist is
# rebuilt only when the VHDL or this recipe changes.
if [ ! -f build/sim/tzxplayer_syn.v ] || [ rtl/tape/tzxplayer.vhd -nt build/sim/tzxplayer_syn.v ] \
   || [ "$0" -nt build/sim/tzxplayer_syn.v ]; then
    ghdl --synth --std=93c -fsynopsys -fexplicit --out=verilog \
        -gTZX_MS=3500 rtl/tape/tzxplayer.vhd -e tzxplayer > build/sim/tzxplayer_syn.v
    # GHDL folds the bound generic into constants and drops the parameter; put
    # an inert one back so tape.sv's `#(.TZX_MS(CLOCK/1000))` override finds it.
    sed -i '0,/^module tzxplayer$/s//module tzxplayer #(parameter TZX_MS = 3500)/' \
        build/sim/tzxplayer_syn.v
    touch build/sim/tzxplayer_syn.v
fi

# Icarus has no array assignment patterns (`blk_list <= '{default:0}`), so
# the simulation copy of tape.sv spells the 128-element clear out. The RTL
# file keeps its two documented deviations. The copy holds only the `tape` module: the
# second module of the file (smart_tape) is not part of this core and its
# `.*` plus name collisions do not elaborate in Icarus. Three playback
# registers are block-local and have no reset value in tape.sv (Quartus
# powers them up as 0, Icarus starts them X and their arithmetic or
# comparisons then never change): give the copy the hardware power-up value.
python3 - <<'PY'
from pathlib import Path

src = Path("rtl/tape/tape.sv").read_text()
old = "blk_list <= '{default:0};"
assert src.count(old) == 1, "tape.sv: expected one blk_list default assignment"
marker = "\nmodule smart_tape"
assert src.count(marker) == 1
src = src[:src.index(marker)] + "\n"
# `addr` is assigned in the always block but upstream declares it as a net
# (Quartus accepts that; Verilog does not). Make it a reg in the sim copy.
oldport = "\toutput [24:0] addr,"
assert src.count(oldport) == 1, "tape.sv: expected one addr output port"
src = src.replace(oldport, "\toutput reg [24:0] addr,")
for decl, init in (("\treg [12:0] tick;", "\treg [12:0] tick = 13'd0;"),
                   ("\treg [31:0] clk_play_cnt;",
                    "\treg [31:0] clk_play_cnt = 32'd0;")):
    assert src.count(decl) == 1, "tape.sv: expected one %r" % decl
    src = src.replace(decl, init)
clear = " ".join("blk_list[%d] <= 0;" % i for i in range(128))
Path("build/sim/tape_sim.v").write_text(src.replace(old, clear))
PY

iverilog -g2012 -o build/sim/tb_tape_play.vvp \
    sim/tb_tape_play.sv \
    sim/models/sd_img_model.sv \
    build/sim/tape_sim.v \
    rtl/tape/tape_src.sv \
    rtl/tape/tape_conv.sv \
    build/sim/tzxplayer_syn.v
stdbuf -oL vvp build/sim/tb_tape_play.vvp > "$LOG" 2>&1 || true
cat "$LOG"
grep -q 'tb_tape_play: PASS' "$LOG"
echo "tb_tape_play: PASS"