#!/usr/bin/env bash
# Icarus run of the uart_route testbench: compiles sim/tb_uart_route.sv with
# rtl/host/uart_route.sv (the DUT) using iverilog -g2012. No prepared upstream
# is needed. The last line of the output is the verdict, `tb_uart_route: PASS`
# or `tb_uart_route: FAIL <reason>`, and it exits non-zero on anything but PASS.
#
# Icarus lives in the karabas-sim image: without it this script re-executes
# itself there through tools/sim.sh:
#   tools/sim.sh sim/run_tb_uart_route.sh     # inside the image
#   sim/run_tb_uart_route.sh                  # from the host: hop
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v iverilog >/dev/null 2>&1; then
    exec tools/sim.sh sim/run_tb_uart_route.sh
fi

LOG=""
# Whatever fails - compilation, the run, or the check of the verdict - the
# verdict line stays the last line this script prints.
verdict() {
    local code=$?
    if [ "$code" -ne 0 ]; then
        echo "tb_uart_route: FAIL the run did not print it (exit $code), see the Icarus log above"
    fi
    [ -n "$LOG" ] && rm -f "$LOG"
    return $code
}
trap verdict EXIT
LOG=$(mktemp)

mkdir -p build/sim
iverilog -g2012 -o build/sim/tb_uart_route.vvp \
    sim/tb_uart_route.sv \
    rtl/host/uart_route.sv
vvp build/sim/tb_uart_route.vvp > "$LOG" 2>&1 || true
cat "$LOG"
# The testbench prints its own verdict (see the end of its initial block);
# grep decides here, so a run that dies inside VVP fails as well.
grep -q 'tb_uart_route: PASS' "$LOG"
echo "tb_uart_route: PASS"
