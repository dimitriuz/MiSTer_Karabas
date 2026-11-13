#!/usr/bin/env bash
# Icarus run of the floppy testbench: sim/tb_floppy.sv (the drive model's
# customer and its store model) with sim/models/altsyncram_model.sv (the four
# track buffers and the written-sector buffer), rtl/disk/floppy.sv (the DUT)
# and the real controller: upstream/karabas-go-core-profi/src/rtl/vg93/
# {vg93_*.v, fdd_glue.v, hrdy_fdc.v}, compiled as the upstream
# src/sim/run_fdc_sim.sh compiles them, so the drive is driven by the VG93
# itself and not by a model of it.
#
# The six runs are the six speed / CPU combinations of that upstream script,
# as cell cadences CELL_NUM/CELL_DEN of clk_bus (the tick is half an MFM cell,
# nominal 500 kHz): 4/225 and 14/675 are 28.125 MHz and the DS80 24.107 MHz at
# the nominal speed, 8/459 and 28/1377 the same clocks 2 % slow, 8/441 and
# 28/1323 the same clocks 2 % fast - those last two with the CPU at 3.5 MHz
# (TURBO=0).
#
# vg93_urom.v does $readmemh("vg93-microcode-rom.hex") relative to the working
# directory, so the hex is copied next to the .vvp and vvp runs from there (the
# run_fdc_sim.sh precedent).
#
# One run is a few seconds of disk spinning in real time (the 14 cases; two reads that
# have to fail cost 2.4 s of it, because the chip searches the track six times before it
# says record not found). Wall time is CPU load, not the disk: a case run alone takes a
# few minutes, the six together longer, so they run at the same time, each in its own
# .vvp and its own log, and the logs are printed in the order of the combinations
# afterwards. The six together take about 73 min of wall time (measured 2026-11-13).
#
# The last line of the output is the verdict, `tb_floppy: PASS` or
# `tb_floppy: FAIL <reason>`, and the script exits non-zero on anything but
# PASS. Without iverilog this re-executes itself in the karabas-sim image:
#   tools/sim.sh sim/run_tb_floppy.sh
#   sim/run_tb_floppy.sh
# Two environment knobs for working on a failure, both unused by the gate run:
#   RUNS="0 4 225 1;0 8 459 1"   the combinations to run, the same tuples
#                                separated by semicolons (one combination is
#                                tens of minutes of wall time, the six run at the
#                                same time);
#   CASE=9                       one case of the bench only (see its header).
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_floppy.sh
fi

V=upstream/karabas-go-core-profi/src/rtl/vg93
OUT=build/sim/floppy
# RUNS="0 4 225 1;..." overrides the six; CASE=<n> runs one bench case.
if [ -n "${RUNS:-}" ]; then
    IFS=';' read -r -a COMBOS <<< "$RUNS"
else
    COMBOS=("0 4 225 1" "1 14 675 1" "0 8 459 1" "1 28 1377 1" "0 8 441 0" "1 28 1323 0")
fi
if [ -n "${CASE:-}" ]; then CASE_OPT="+CASE=$CASE"; else CASE_OPT=""; fi
mkdir -p "$OUT"
cp "$V/vg93-microcode-rom.hex" "$OUT/"
rm -f "$OUT"/tb_floppy[0-9].vvp "$OUT"/tb_floppy[0-9].log

n=0
for P in "${COMBOS[@]}"; do
    n=$((n + 1))
    set -- $P
    {
        iverilog -g2012 -I "$V" \
            -P tb_floppy.DS80="$1" -P tb_floppy.TURBO="$4" \
            -P tb_floppy.CELL_NUM="$2" -P tb_floppy.CELL_DEN="$3" \
            -o "$OUT/tb_floppy$n.vvp" \
            sim/tb_floppy.sv \
            sim/models/altsyncram_model.sv \
            rtl/disk/floppy.sv \
            "$V"/vg93_*.v "$V/fdd_glue.v" "$V/hrdy_fdc.v" \
            && (cd "$OUT" && vvp -n "tb_floppy$n.vvp" ${CASE_OPT:+"$CASE_OPT"})
    } > "$OUT/tb_floppy$n.log" 2>&1 &
    echo "tb_floppy: run $n DS80=$1 TURBO=$4 cell=$2/$3 -> $OUT/tb_floppy$n.log"
done
wait || true

FAILED=""
n=0
for P in "${COMBOS[@]}"; do
    n=$((n + 1))
    set -- $P
    echo "== tb_floppy run $n: DS80=$1 TURBO=$4 cell=$2/$3 =="
    cat "$OUT/tb_floppy$n.log"
    if ! grep -q '^tb_floppy: PASS$' "$OUT/tb_floppy$n.log"; then
        FAILED="$FAILED run$n(DS80=$1,TURBO=$4,$2/$3)"
    fi
done

if [ -n "$FAILED" ]; then
    echo "tb_floppy: FAIL no PASS from:$FAILED"
    exit 1
fi
echo "tb_floppy: PASS"
