#!/usr/bin/env bash
# Icarus run of the SD card SPI testbench: compiles sim/tb_sd_spi.sv with
# sys/sd_card.sv (the card, unmodified), sim/models/hps_disk_model.sv
# (hps_io's disk byte transport) and sim/models/altsyncram_model.sv (the
# card's sector buffer, an altsyncram). The last line of the output is the
# verdict, `tb_sd_spi: PASS` or `tb_sd_spi: FAIL <reason>`, and the script
# exits non-zero on anything but PASS.
#
# No fixtures: the bench builds its image in SystemVerilog. Icarus lives in
# the karabas-sim image; without it this script re-executes itself there
# through tools/sim.sh:
#   tools/sim.sh sim/run_tb_sd_spi.sh
#   sim/run_tb_sd_spi.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_sd_spi.sh
fi

LOG=""
# Whatever fails - compilation, the run, or the check of the verdict - the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_sd_spi: FAIL the run did not print it (exit $code), see the Icarus log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

iverilog -g2012 -o build/sim/tb_sd_spi.vvp \
    sim/tb_sd_spi.sv \
    sim/models/hps_disk_model.sv \
    sim/models/altsyncram_model.sv \
    sys/sd_card.sv
vvp build/sim/tb_sd_spi.vvp > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of its initial block);
# grep decides here, so a run that dies inside VVP fails as well.
grep -q 'tb_sd_spi: PASS' "$LOG"
echo "tb_sd_spi: PASS"