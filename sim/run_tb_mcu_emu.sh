#!/usr/bin/env bash
# Icarus run of the MCU link emulator testbench: compiles sim/tb_mcu_emu.sv
# with rtl/host/mcu_spi_master.sv and rtl/host/mcu_emu.sv (iverilog -g2012;
# mcu_emu `include`s rtl/host/osd_items.svh) against the unmodified upstream
# kg_mcu and its parts, taken from build/upstream/modules (the
# prepare_upstream.py copy of karabas-go-modules). The last line of the
# output is the verdict, `tb_mcu_emu: PASS` or `tb_mcu_emu: FAIL <reason>`,
# and it exits non-zero on anything but PASS.
#
# The upstream copy is (re)generated first with the host python3
# (prepare_upstream.py needs git for its STAMP, which the sim image has
# none). Icarus lives in the karabas-sim image: without it this script
# re-executes itself there through tools/sim.sh, passing --no-prepare (the
# image would just fail to run the prepare step again):
#   tools/sim.sh sim/run_tb_mcu_emu.sh        # inside the image
#   sim/run_tb_mcu_emu.sh                     # from the host: prepare, hop
set -euo pipefail

cd "$(dirname "$0")/.."

PREPARE=1
if [ "${1:-}" = "--no-prepare" ]; then PREPARE=0; shift; fi
if [ "$#" -ne 0 ]; then echo "usage: $0 [--no-prepare]" >&2; exit 2; fi

# prepare_upstream.py reads the upstream pins with git, which the sim image
# does not have: it runs with the host python; inside the image the existing
# build/upstream (checked below) is reused.
if [ "$PREPARE" = 1 ] && command -v git >/dev/null 2>&1; then
    python3 tools/prepare_upstream.py
fi

# Icarus is only inside the sim image: hop there and skip the re-prepare.
if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_mcu_emu.sh --no-prepare
fi

if [ ! -f build/upstream/STAMP ]; then
    echo "run_tb_mcu_emu: no build/upstream; run this script once on the host" >&2
    echo "tb_mcu_emu: FAIL no prepared upstream"
    exit 1
fi

LOG=""
# Whatever fails - compilation, the run, or the check of the verdict - the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_mcu_emu: FAIL the run did not print it (exit $code), see the Icarus log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

U=build/upstream/modules/rtl
mkdir -p build/sim
iverilog -g2012 -I rtl/host -I "$U/mcu" -o build/sim/tb_mcu_emu.vvp \
    sim/tb_mcu_emu.sv \
    rtl/host/mcu_spi_master.sv \
    rtl/host/bcd_clock.sv \
    rtl/host/mcu_emu.sv \
    "$U/mem/kg_fifo.v" \
    "$U/mem/kg_sdpram.v" \
    "$U/mcu/kg_spi_slave.v" \
    "$U/mcu/kg_burst_rx.v" \
    "$U/mcu/kg_mcu.v" \
    "$U/mcu/kg_mcu_link.v" \
    "$U/mcu/kg_mcu_ctl.v" \
    "$U/mcu/kg_mcu_hid.v" \
    "$U/mcu/kg_mcu_loader.v" \
    "$U/mcu/kg_mcu_uart.v" \
    "$U/mcu/kg_mcu_rtc.v" \
    "$U/mcu/kg_mcu_img.v" \
    "$U/ctl/kg_soft_switches.v"
vvp build/sim/tb_mcu_emu.vvp > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of its initial block);
# grep decides here, so a run that dies inside VVP fails as well.
grep -q 'tb_mcu_emu: PASS' "$LOG"
echo "tb_mcu_emu: PASS"
