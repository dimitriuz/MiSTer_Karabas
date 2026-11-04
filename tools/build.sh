#!/usr/bin/env bash
# The one-command build of the MiSTer core: regenerate build/upstream/ from
# the submodule, run the upstream-change tripwire, compile with Quartus in
# Docker. The last line is always `build: exit <code>`, so a detached poller
# can watch for it:
#   setsid nohup tools/build.sh </dev/null >build/logs/build.log 2>&1 &
#   for i in $(seq 1 30); do sleep 60; grep -q '^build: exit' build/logs/build.log && break; done
# Quartus rewrites LAST_QUARTUS_VERSION in Karabas_Profi.qsf; revert it after
# a successful build (see README).
set -uo pipefail
cd "$(dirname "$0")/.."

# The compiled-date stamp the top includes (MiSTer naming convention); the
# file is generated, not committed.
printf '`define BUILD_DATE "%s"\n' "$(date +%y%m%d)" >build_id.v

python3 tools/prepare_upstream.py && tools/check_upstream.sh && tools/qbuild.sh . Karabas_Profi
code=$?
echo "build: exit $code"
exit "$code"
