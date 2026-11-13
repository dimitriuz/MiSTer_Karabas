#!/usr/bin/env bash
# Runs every sim/run_tb_*.sh (each prints its verdict `<tb>: PASS` or
# `<tb>: FAIL <reason>` as its last line and exits non-zero on failure) and
# ends with the summary `run_all: N passed, M failed`. Exits 0 only when M=0.
# Called through tools/sim.sh:
#   tools/sim.sh sim/run_all.sh
# tb_tape_play takes ~35 minutes and tb_floppy ~73 minutes (six speed combinations of a
# disk that spins in real time, two of the cases waiting out a six-turn search), so
# budget for them.
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
