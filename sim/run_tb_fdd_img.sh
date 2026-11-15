#!/usr/bin/env bash
# Icarus run of the floppy image path testbench: sim/tb_fdd_img.sv with
# sim/models/ddram_model.sv (the DDRAM Avalon slave, BUSY_PCT = 20),
# sim/models/altsyncram_model.sv (the RAMs inside the two DUTs) and
# sim/models/hps_disk_model.sv (hps_io's sector transport), against the DUTs
# rtl/disk/fdd_store.sv, rtl/disk/fdd_src.sv and rtl/mem/ddr_arb.sv. Part A of
# the bench drives the store directly, Part B drives it through fdd_src.
#
# The fixtures are made on the host first (mk_disk.py needs only python3):
# test.trd with the boot program, test.cpm, test.fdi and wide.fdi, the
# reference tracks of the cases read back from those very images with
# `mk_disk.py reffrom`, the FDI fill programs with `mk_disk.py fdistream`, the
# small hps slot files and FDI download files of Part B, and the hex forms the
# bench $readmemh-s. GHDL is not needed; Icarus lives
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

    # ---- Part B: the two hps slot files, and the ioctl download files ----
    python3 - "$OUT" <<'PY'
import struct
import sys
from pathlib import Path

sys.path.insert(0, "tools")
import mk_disk

out = Path(sys.argv[1])

# The download files are the smallest images that still carry every shape the
# downloader transforms: two sides, the wide layout (512 B sectors plus the
# flags-0x40 sector), and a one-side image, whose blocks the store asks for at
# twice their number in the file. Then the three headers that must be refused:
# a file that ends inside the header, a wrong magic, and a cylinder count past
# the store's cap of 84.
mk_disk.fdi(out / "dl.fdi", tracks=1)
mk_disk.fdi(out / "dlw.fdi", tracks=1, layout="wide")
mk_disk.fdi(out / "dl1.fdi", tracks=2, sides=1)
img = (out / "dl.fdi").read_bytes()
(out / "dlcut").write_bytes(img[:8])
bad = bytearray(img[:32])
bad[2] = ord("X")
(out / "dlbad").write_bytes(bytes(bad))
big = bytearray(img[:32])
struct.pack_into("<H", big, 4, 200)
(out / "dlbig").write_bytes(bytes(big))
PY
    python3 tools/mk_disk.py trd "$OUT/trdh.trd" --tracks 2
    python3 tools/mk_disk.py cpm "$OUT/cpmh.cpm" --tracks 1
    python3 tools/mk_disk.py reffrom "$OUT/ref_trdh_t0s0" \
        --image "$OUT/trdh.trd" --kind trd --track 0 --side 0
    python3 tools/mk_disk.py reffrom "$OUT/ref_trdh_t0s1" \
        --image "$OUT/trdh.trd" --kind trd --track 0 --side 1
    python3 tools/mk_disk.py reffrom "$OUT/ref_cpmh_t0s0" \
        --image "$OUT/cpmh.cpm" --kind cpm --track 0 --side 0
    python3 tools/mk_disk.py reffrom "$OUT/ref_dl_t0s1" \
        --image "$OUT/dl.fdi" --kind fdi --track 0 --side 1
    python3 tools/mk_disk.py reffrom "$OUT/ref_dlw_t0s0" \
        --image "$OUT/dlw.fdi" --kind fdi --track 0 --side 0
    python3 tools/mk_disk.py reffrom "$OUT/ref_dl1_t1s0" \
        --image "$OUT/dl1.fdi" --kind fdi --track 1 --side 0
    python3 - "$OUT" <<'PY'
import sys
from pathlib import Path

out = Path(sys.argv[1])
for name, dst in (("test.trd", "trd.hex"), ("test.cpm", "cpm.hex"),
                  ("trdh.trd", "trdh.hex"), ("cpmh.cpm", "cpmh.hex"),
                  ("dl.fdi", "dl.hex"), ("dlw.fdi", "dlw.hex"),
                  ("dl1.fdi", "dl1.hex"), ("dlcut", "dlcut.hex"),
                  ("dlbad", "dlbad.hex"), ("dlbig", "dlbig.hex")):
    data = (out / name).read_bytes()
    (out / dst).write_text("".join("%02X\n" % b for b in data))
PY
fi

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_fdd_img.sh --no-prepare
fi

for f in trd.hex cpm.hex fdi.prog wide.prog ref_trd_t0s0 ref_wide_t0s0.sync \
         trdh.hex cpmh.hex dl.hex dlw.hex dl1.hex dlcut.hex dlbad.hex \
         dlbig.hex ref_dl1_t1s0.sync; do
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
    sim/models/hps_disk_model.sv \
    rtl/disk/fdd_store.sv \
    rtl/disk/fdd_src.sv \
    rtl/mem/ddr_arb.sv
vvp build/sim/tb_fdd_img.vvp > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of its initial block);
# grep decides here, so a run that dies inside VVP fails as well.
grep -q 'tb_fdd_img: PASS' "$LOG"
echo "tb_fdd_img: PASS"
