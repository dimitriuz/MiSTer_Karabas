#!/usr/bin/env bash
# Run a command in the karabas-sim simulation image at /work (the repo mounted
# read-write, host uid). Usage: tools/sim.sh <command> [args...]
# Builds tools/sim/Dockerfile into the image (karabas-sim:1) if it is missing.
# Exits with the command's exit code. Env overrides: SIM_IMAGE, SIM_DOCKERFILE.
set -euo pipefail

: "${SIM_IMAGE:=karabas-sim:1}"
: "${SIM_DOCKERFILE:=tools/sim/Dockerfile}"

if [ $# -lt 1 ]; then
    echo "usage: tools/sim.sh <command> [args...]" >&2
    exit 2
fi
if ! docker image inspect "$SIM_IMAGE" >/dev/null 2>&1; then
    if [ ! -f "$SIM_DOCKERFILE" ]; then
        echo "sim.sh: image $SIM_IMAGE missing and no $SIM_DOCKERFILE" >&2
        exit 2
    fi
    echo "sim.sh: building $SIM_IMAGE from $SIM_DOCKERFILE" >&2
    docker build -t "$SIM_IMAGE" -f "$SIM_DOCKERFILE" "$(dirname "$SIM_DOCKERFILE")"
fi
exec docker run --rm \
    -v "$PWD":/work -w /work \
    -u "$(id -u):$(id -g)" -e HOME=/tmp \
    "$SIM_IMAGE" "$@"
