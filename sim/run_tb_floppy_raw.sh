#!/usr/bin/env bash
# Icarus run of sim/tb_floppy_raw.sv: the drive model with raw tracks of three
# lengths (6400, 6250, 6016). The last line is the verdict.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v iverilog >/dev/null 2>&1; then exec tools/sim.sh sim/run_tb_floppy_raw.sh; fi
mkdir -p build/sim
ok=1
for len in 6400 6250 6016; do
    iverilog -g2012 -DLEN=$len -o build/sim/tb_floppy_raw_$len.vvp sim/tb_floppy_raw.sv rtl/disk/floppy.sv
    out=$(vvp -n build/sim/tb_floppy_raw_$len.vvp | grep tb_floppy_raw || true)
    echo "$out"
    echo "$out" | grep -q "tb_floppy_raw: PASS" || ok=0
done
if [ $ok = 1 ]; then echo "tb_floppy_raw: PASS"; else echo "tb_floppy_raw: FAIL"; exit 1; fi
