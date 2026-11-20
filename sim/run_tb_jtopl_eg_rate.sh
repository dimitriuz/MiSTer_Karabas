#!/usr/bin/env bash
# jtopl's own envelope-rate test on the jtopl files as prepared for the core (JTOPL_REWRITES in
# tools/prepare_upstream.py). Prepares into build/upstream_jtopl, so a build running on
# build/upstream is not disturbed. Called through tools/sim.sh (iverilog is in the image; the
# image has no git, so the host prepares first).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/upstream_jtopl
if [ "${1:-}" != "--no-prepare" ]; then
    python3 tools/prepare_upstream.py --out "$OUT" >/dev/null
    exec tools/sim.sh sim/run_tb_jtopl_eg_rate.sh --no-prepare
fi
D=$OUT/src/rtl/sound/jtopl
mkdir -p build/sim
iverilog -g2012 -s test -o build/sim/jtopl_eg_rate sim/tb_jtopl_eg_rate.v $D/jtopl_eg_ctrl.v $D/jtopl_eg_step.v $D/jtopl_eg_pure.v
(cd build/sim && vvp ./jtopl_eg_rate) 2>&1 | tee build/sim/jtopl_eg_rate.log
grep -q 'tb_jtopl_eg_rate: PASS' build/sim/jtopl_eg_rate.log
