#!/usr/bin/env bash
# Icarus run of the diagnostic stock TZX path: tape_src with stock_tzx = 1 feeds
# the raw TZX to tape.sv's own engine (tzxplayer.vhd, GHDL-synthesised), whose
# OSD knobs pilot_sel / pause_keep are checked on the pulse stream:
#   pilot_sel 1 -> 8063 pilot edges of 2168, pilot_sel 2 -> 8065 (hello.tzx),
#   pause_keep 0/1 on a short synthetic turbo block: the 1 ms level-low edge
#   after the last bit is there / is gone, and tape_mode is 2 (stock) at all.
# Pilots are long: about 4 minutes of simulation per 16k edges. Same image
# hop as run_tb_tape_play.sh:
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
    python3 tools/zxtap.py bas tests/zx/hello.bas "$OUT/hello.tap" --autostart 10
    python3 tools/zxtap.py tzx "$OUT/hello.tap" "$OUT/hello.tzx"
    python3 - <<'PY'
import struct
from pathlib import Path
out = Path("build/sim/tzx_stock")
# one turbo block: pilot 2168 x 5, sync 667/735, bits 855/1710, 8 bits, 5 ms pause, 1 byte
blk = bytes([0x11]) + struct.pack("<HHHHHHBH", 2168, 667, 735, 855, 1710, 5, 8, 5) + bytes([1, 0, 0, 0xA5])
# a trailing text block: at the end of the file the engine waits for a byte that
# never comes and never reaches the pause
(out / "turbo.tzx").write_bytes(b"ZXTape!\x1a\x01\x0d" + blk + bytes([0x30, 3]) + b"end")
for name in ("hello.tzx", "turbo.tzx"):
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

run() {  # name file sel keep stock maxe tlim
    local sz; sz=$(cat "$OUT/$2.size")
    vvp "$OUT/tb.vvp" +FILE="$OUT/$2.hex" +SIZE="$sz" +SEL="$3" +KEEP="$4" +STOCK="$5" \
        +MAXE="$6" +TLIM="$7" +OUT="$OUT/$1.edges" | grep -E "^mode" | sed "s/^/$1: /"
}
run sel1 hello.tzx 1 0 1 8100 1800000000
run sel2 hello.tzx 2 0 1 8100 1800000000
run keep0 turbo.tzx 0 0 1 200 60000000
run keep1 turbo.tzx 0 1 1 200 60000000

python3 - <<'PY'
import sys
from pathlib import Path
d = Path("build/sim/tzx_stock")
def edges(n):
    return [int(l.split()[1]) for l in (d / (n + ".edges")).read_text().split("\n") if l]
bad = []
def pilot(n):
    e = edges(n)[1:]            # the first interval is the start-up gap
    k = 0
    while k < len(e) and abs(e[k] - 2168) <= 1: k += 1
    return k, e[k:k + 2]
for n, want in (("sel1", 8063), ("sel2", 8065)):
    k, sync = pilot(n)
    print(n, "pilot edges", k, "then", sync)
    if abs(k - want) > 2: bad.append("%s pilot %d want %d" % (n, k, want))
    if not (600 < sync[0] < 700 and 700 < sync[1] < 780): bad.append(n + " sync " + str(sync))
def tail(n):
    e = edges(n); return e[-3:]
for n, forced in (("keep0", True), ("keep1", False)):
    e = edges(n)
    # 5 pilot-ish + 2 sync + 16 bit edges (+1 forced-low edge 1 ms after the last bit)
    last = [x for x in e if 3400 <= x <= 3600]
    print(n, "edges", len(e), "1 ms edges", len(last), "tail", e[-3:])
    if bool(last) != forced: bad.append("%s 1 ms edge %s, want %s" % (n, bool(last), forced))
print("tb_tzx_stock: PASS" if not bad else "tb_tzx_stock: FAIL " + "; ".join(bad))
sys.exit(1 if bad else 0)
PY
