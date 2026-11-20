#!/usr/bin/env bash
# Icarus run of sim/tb_fdd_ams.sv: a real FDI through fdd_src -> fdd_store -> floppy ->
# the upstream VG93, driven by the command sequence PicoSpeccy's WD1793 logged for the
# disk (sim/data/ams_loader.trace). The FDI is not in the repository: point AMS_FDI at it
# (default: the owner's NAS copy); without it the run is skipped.
# The last line is the verdict, `tb_fdd_ams: PASS`, `tb_fdd_ams: FAIL <reason>` or
# `tb_fdd_ams: SKIP`. Env: AMS_FDI, KEEP (bytes of the data area to download, default 32768).
set -euo pipefail
cd "$(dirname "$0")/.."
FDI=${AMS_FDI:-/mnt/nas/downloads/retro/retronas/mister/games/Karabas_Profi/tests/AMS.fdi}
if [ ! -f "$FDI" ]; then echo "tb_fdd_ams: SKIP (no $FDI)"; exit 0; fi
OUT=build/sim/ams
python3 tools/ams_cmds.py sim/data/ams_loader.trace "$FDI" "$OUT" "${KEEP:-32768}"
if ! command -v iverilog >/dev/null 2>&1; then
    exec docker run --rm -v "$PWD":/work -v "$(dirname "$FDI")":"$(dirname "$FDI")":ro -w /work \
        -u "$(id -u):$(id -g)" -e HOME=/tmp -e AMS_FDI="$FDI" -e KEEP="${KEEP:-32768}" \
        karabas-sim:1 sim/run_tb_fdd_ams.sh
fi
V=upstream/karabas-go-core-profi/src/rtl/vg93
cp "$V/vg93-microcode-rom.hex" "$OUT/"
iverilog -g2012 -I "$V" -o "$OUT/tb_fdd_ams.vvp" \
    sim/tb_fdd_ams.sv sim/models/ddram_model.sv sim/models/altsyncram_model.sv \
    rtl/disk/fdd_store.sv rtl/disk/fdd_src.sv rtl/disk/td0_lzh.sv rtl/disk/floppy.sv rtl/mem/ddr_arb.sv \
    "$V"/vg93_*.v "$V/fdd_glue.v" "$V/hrdy_fdc.v"
(cd "$OUT" && stdbuf -oL vvp -n tb_fdd_ams.vvp) | tee "$OUT/tb_fdd_ams.log"
grep -q 'tb_fdd_ams: PASS' "$OUT/tb_fdd_ams.log"
