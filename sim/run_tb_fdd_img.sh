#!/usr/bin/env bash
# Icarus run of the floppy image store testbench: sim/tb_fdd_img.sv with
# sim/models/ddram_model.sv (the DDRAM Avalon slave, BUSY_PCT = 20) and
# sim/models/altsyncram_model.sv (the RAMs inside rtl/disk/fdd_store.sv), the
# DUT rtl/disk/fdd_store.sv and rtl/mem/ddr_arb.sv.
#
# The fixtures are made on the host first (mk_disk.py needs only python3):
# test.trd with the boot program, test.cpm, test.fdi and wide.fdi, the
# reference tracks of the cases read back from those very images with
# `mk_disk.py reffrom`, the FDI fill programs with `mk_disk.py fdistream`,
# and the hex forms the bench $readmemh-s. GHDL is not needed; Icarus lives
# in the karabas-sim image, so without it this script re-executes itself
# there through tools/sim.sh, passing --no-prepare:
#   tools/sim.sh sim/run_tb_fdd_img.sh    # inside the image
#   sim/run_tb_fdd_img.sh                 # from the host: prepare, hop
#
# vvp runs from the repository root: the bench's $readmemh paths are relative
# to it. The last line of the output is the verdict, `tb_fdd_img: PASS` or
# `tb_fdd_img: FAIL <reason>`, and the script exits non-zero on anything but
# PASS.
set -euo pipefail

cd "$(dirname "$0")/.."

PREPARE=1
if [ "${1:-}" = "--no-prepare" ]; then PREPARE=0; shift; fi
if [ "$#" -ne 0 ]; then echo "usage: $0 [--no-prepare]" >&2; exit 2; fi

OUT=build/sim/fdd_img
if [ "$PREPARE" = 1 ]; then
    mkdir -p "$OUT"
    python3 tools/mk_disk.py trd "$OUT/test.trd" --boot
    python3 tools/mk_disk.py cpm "$OUT/test.cpm"
    python3 tools/mk_disk.py fdi "$OUT/test.fdi"
    python3 tools/mk_disk.py fdi "$OUT/wide.fdi" --layout wide
    python3 tools/mk_disk.py reffrom "$OUT/ref_trd_t0s0" \
        --image "$OUT/test.trd" --kind trd --track 0 --side 0
    python3 tools/mk_disk.py reffrom "$OUT/ref_trd_t5s1" \
        --image "$OUT/test.trd" --kind trd --track 5 --side 1
    python3 tools/mk_disk.py reffrom "$OUT/ref_cpm_t3s1" \
        --image "$OUT/test.cpm" --kind cpm --track 3 --side 1
    python3 tools/mk_disk.py reffrom "$OUT/ref_cpm_t4s0" \
        --image "$OUT/test.cpm" --kind cpm --track 4 --side 0
    python3 tools/mk_disk.py reffrom "$OUT/ref_fdi_t0s1" \
        --image "$OUT/test.fdi" --kind fdi --track 0 --side 1
    python3 tools/mk_disk.py reffrom "$OUT/ref_wide_t0s0" \
        --image "$OUT/wide.fdi" --kind fdi --track 0 --side 0
    python3 tools/mk_disk.py fdistream "$OUT/fdi.prog" \
        --image "$OUT/test.fdi" 0:1
    python3 tools/mk_disk.py fdistream "$OUT/wide.prog" \
        --image "$OUT/wide.fdi" 0:0
    python3 - "$OUT" <<'PY'
import sys
from pathlib import Path

out = Path(sys.argv[1])
for name, dst in (("test.trd", "trd.hex"), ("test.cpm", "cpm.hex")):
    data = (out / name).read_bytes()
    (out / dst).write_text("".join("%02X\n" % b for b in data))
PY
fi

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_fdd_img.sh --no-prepare
fi

for f in trd.hex cpm.hex fdi.prog wide.prog ref_trd_t0s0 ref_wide_t0s0.sync; do
    if [ ! -f "$OUT/$f" ]; then
        echo "run_tb_fdd_img: no $OUT/$f; run this script once on the host" >&2
        echo "tb_fdd_img: FAIL no fixtures"
        exit 1
    fi
done

LOG=""
# Whatever fails - compilation, the run, or the check of the verdict - the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_fdd_img: FAIL the run did not print it (exit $code), see the Icarus log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p build/sim
iverilog -g2012 -o build/sim/tb_fdd_img.vvp \
    sim/tb_fdd_img.sv \
    sim/models/ddram_model.sv \
    sim/models/altsyncram_model.sv \
    rtl/disk/fdd_store.sv \
    rtl/mem/ddr_arb.sv
vvp build/sim/tb_fdd_img.vvp > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of its initial block);
# grep decides here, so a run that dies inside VVP fails as well.
grep -q 'tb_fdd_img: PASS' "$LOG"
echo "tb_fdd_img: PASS"
