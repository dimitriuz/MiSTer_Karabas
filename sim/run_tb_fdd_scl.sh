#!/usr/bin/env bash
# Icarus run of sim/tb_fdd_scl.sv: a Sinclair SCL download into rtl/disk/fdd_src.sv
# (alone; the store is a responder in the bench). Fixtures from tools/scl.py.
# The last line is the verdict, `tb_fdd_scl: PASS` or `tb_fdd_scl: FAIL <reason>`.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v iverilog >/dev/null 2>&1; then exec tools/sim.sh sim/run_tb_fdd_scl.sh; fi
OUT=build/sim/scl
mkdir -p "$OUT"
python3 - "$OUT" <<'PY'
import sys, struct
sys.path.insert(0, "tools")
import scl
out = sys.argv[1]
def hexw(name, b):
    open(f"{out}/{name}", "w").write("\n".join(f"{x:02x}" for x in b) + "\n")
a = scl.sample(3, 5, 1)
hexw("a.hex", a); hexw("a.win", scl.window(a))
b = scl.scl([])
hexw("b.hex", b); hexw("b.win", scl.window(b))
c = bytearray(scl.scl([(b"big".ljust(8) + b"C" + bytes(5), b"")]))   # one entry
c[9 + 13] = 200                                                       # claim 200 sectors
c[8] = 20                                                             # 20 entries (data short)
c = bytes(c[:9]) + bytes(c[9:9 + 14]) * 20
hexw("c.hex", c)
d = bytearray(a); d[3] = 0x58
hexw("d.hex", bytes(d))
PY
iverilog -g2012 -o build/sim/tb_fdd_scl.vvp sim/tb_fdd_scl.sv \
    sim/models/altsyncram_model.sv rtl/disk/fdd_src.sv rtl/disk/td0_lzh.sv
vvp -n build/sim/tb_fdd_scl.vvp | tee build/sim/tb_fdd_scl.log
grep -q 'tb_fdd_scl: PASS' build/sim/tb_fdd_scl.log
