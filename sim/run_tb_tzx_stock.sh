#!/usr/bin/env bash
# Icarus run of the stock TZX path: tape_src with stock_tzx = 1 feeds the raw
# TZX to tape.sv's own engine (tzxplayer.vhd, GHDL-synthesised). A synthetic
# turbo block (0x11) followed by a text block (0x30), which the converter would
# not play at all, must come out as: pilot 2*5+1 edges of 2168, sync 668/736, 16 bit
# edges, then the 1 ms level-low edge of the pause. Same image hop as
# run_tb_tape_play.sh:
#   tools/sim.sh sim/run_tb_tzx_stock.sh     # inside the image
#   sim/run_tb_tzx_stock.sh                  # from the host
# The last line is `tb_tzx_stock: PASS` or `tb_tzx_stock: FAIL <reason>`.
set -euo pipefail
cd "$(dirname "$0")/.."
PREPARE=1
if [ "${1:-}" = "--no-prepare" ]; then PREPARE=0; shift; fi
OUT=build/sim/tzx_stock
mkdir -p "$OUT"

if [ "$PREPARE" = 1 ]; then
    python3 - <<'PY'
import struct
from pathlib import Path
out = Path("build/sim/tzx_stock")
# one turbo block: pilot 2168 x 5, sync 667/735, bits 855/1710, 8 bits, 5 ms pause, 1 byte
blk = bytes([0x11]) + struct.pack("<HHHHHHBH", 2168, 667, 735, 855, 1710, 5, 8, 5) + bytes([1, 0, 0, 0xA5])
# a trailing text block: at the end of the file the engine waits for a byte that
# never comes and never reaches the pause
(out / "turbo.tzx").write_bytes(b"ZXTape!\x1a\x01\x0d" + blk + bytes([0x30, 3]) + b"end")
for name in ("turbo.tzx",):
    d = (out / name).read_bytes()
    (out / (name + ".hex")).write_text("".join("%02x\n" % b for b in d))
    (out / (name + ".size")).write_text(str(len(d)))
PY
fi

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_tzx_stock.sh --no-prepare
fi

verdict() { code=$?; [ "$code" -ne 0 ] && echo "tb_tzx_stock: FAIL the run did not finish (exit $code)"; return $code; }
trap verdict EXIT

ghdl --synth --std=93c -fsynopsys -fexplicit --out=verilog \
    -gTZX_MS=3500 rtl/tape/tzxplayer.vhd -e tzxplayer > "$OUT/tzxplayer_syn.v"
sed -i '0,/^module tzxplayer$/s//module tzxplayer #(parameter TZX_MS = 3500)/' "$OUT/tzxplayer_syn.v"
python3 - <<'PY'
from pathlib import Path
src = Path("rtl/tape/tape.sv").read_text()
old = "blk_list <= '{default:0};"
assert src.count(old) == 1
marker = "\nmodule smart_tape"
assert src.count(marker) == 1
src = src[:src.index(marker)] + "\n"
oldport = "\toutput [24:0] addr,"
assert src.count(oldport) == 1
src = src.replace(oldport, "\toutput reg [24:0] addr,")
for decl, init in (("\treg [12:0] tick;", "\treg [12:0] tick = 13'd0;"),
                   ("\treg [31:0] clk_play_cnt;", "\treg [31:0] clk_play_cnt = 32'd0;")):
    assert src.count(decl) == 1
    src = src.replace(decl, init)
clear = " ".join("blk_list[%d] <= 0;" % i for i in range(128))
Path("build/sim/tzx_stock/tape_sim.v").write_text(src.replace(old, clear))
PY
iverilog -g2012 -o "$OUT/tb.vvp" sim/tb_tzx_stock.sv sim/models/sd_img_model.sv \
    "$OUT/tape_sim.v" rtl/tape/tape_src.sv rtl/tape/tape_conv.sv "$OUT/tzxplayer_syn.v"

run() {  # name file stock maxe tlim
    local sz; sz=$(cat "$OUT/$2.size")
    vvp "$OUT/tb.vvp" +FILE="$OUT/$2.hex" +SIZE="$sz" +STOCK="$3" \
        +MAXE="$4" +TLIM="$5" +OUT="$OUT/$1.edges" | grep -E "^mode" | sed "s/^/$1: /"
}
run turbo turbo.tzx 1 200 60000000

python3 - <<'PY'
import sys
from pathlib import Path
e = [int(l.split()[1]) for l in Path("build/sim/tzx_stock/turbo.edges").read_text().split("\n") if l][1:]
bad = []
print("edges", len(e), e)
if any(abs(x - 2168) > 1 for x in e[:11]): bad.append("pilot %s" % e[:11])
if not (abs(e[11] - 668) <= 1 and abs(e[12] - 736) <= 1): bad.append("sync %s" % e[11:13])
if len([x for x in e if 3400 <= x <= 3600]) != 1: bad.append("the 1 ms pause edge is missing")
print("tb_tzx_stock: PASS" if not bad else "tb_tzx_stock: FAIL " + "; ".join(bad))
sys.exit(1 if bad else 0)
PY
