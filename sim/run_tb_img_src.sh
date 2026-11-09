#!/usr/bin/env bash
# Icarus run of the img_src testbench: compiles sim/tb_img_src.sv with
# sim/models/hps_disk_model.sv (hps_io's sector transport),
# sim/models/altsyncram_model.sv (the engine's 512-byte sector buffer) and
# rtl/disk/img_src.sv (the DUT), plus the upstream hdf_ata (the engine's
# customer on the IDE bus, no rewrites). The last line of the output is the
# verdict, `tb_img_src: PASS` or `tb_img_src: FAIL <reason>`, and the script
# exits non-zero on anything but PASS.
#
# No fixtures: the bench builds its 512 KB image in SystemVerilog. Icarus
# lives in the karabas-sim image; without it this script re-executes itself
# there through tools/sim.sh:
#   tools/sim.sh sim/run_tb_img_src.sh
#   sim/run_tb_img_src.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_img_src.sh
fi

LOG=""
# Whatever fails - compilation, the run, or the check of the verdict - the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_img_src: FAIL the run did not print it (exit $code), see the Icarus log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

iverilog -g2012 -o build/sim/tb_img_src.vvp \
    sim/tb_img_src.sv \
    sim/models/hps_disk_model.sv \
    sim/models/altsyncram_model.sv \
    rtl/disk/img_src.sv \
    upstream/karabas-go-core-profi/modules/rtl/mcu/hdf_ata.v
vvp build/sim/tb_img_src.vvp > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of its initial block);
# grep decides here, so a run that dies inside VVP fails as well.
grep -q 'tb_img_src: PASS' "$LOG"
echo "tb_img_src: PASS"