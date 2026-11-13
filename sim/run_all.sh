#!/usr/bin/env bash
# Runs every sim/run_tb_*.sh (each prints its verdict `<tb>: PASS` or
# `<tb>: FAIL <reason>` as its last line and exits non-zero on failure) and
# ends with the summary `run_all: N passed, M failed`. Exits 0 only when M=0.
# Called through tools/sim.sh:
#   tools/sim.sh sim/run_all.sh
# tb_tape_play takes ~35 minutes; tb_floppy is a few seconds of simulated disk time per
# speed combination (two of its cases wait out a six-turn search, 1.2 s of disk each) and
# its six combinations run at the same time - the wall time of the six together has not
# been timed since the bench stopped walking to an index that cannot come.
set -u
cd "$(dirname "$0")/.."

pass=0
fail=0
failed=""
for tb in sim/run_tb_*.sh; do
    echo "== $tb =="
    if "$tb"; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        failed="$failed ${tb#sim/}"
    fi
done
[ -n "$failed" ] && echo "run_all: failed:$failed"
echo "run_all: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
