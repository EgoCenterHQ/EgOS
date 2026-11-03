#!/bin/bash
# EgOS - builds the amd64 ISO in a throwaway container (docker or podman).
# Nothing stays on the host except the builder image (tools only) and OUT:
# no chroot, no cache, no `lb clean` needed between builds.
#
#   builder-amd64/build-iso.sh [OUT_DIR]    default OUT_DIR: ./out
#   ENGINE=podman builder-amd64/build-iso.sh   default: docker if its daemon answers, else podman
#   SCRIPT=/path/EgOS4-amd64.sh ...         default: EgOS4-amd64.sh in this folder
#
# Needs root (sudo) and --privileged: live-build mounts /proc and creates
# device nodes in its chroot; a rootless engine is not enough.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$(realpath "${SCRIPT:-$HERE/EgOS4-amd64.sh}")
OUT=$(realpath -m "${1:-./out}")
IMAGE=egos-builder
[ -f "$SCRIPT" ] || { echo "Build script not found: $SCRIPT"; exit 1; }

SUDO=sudo; [ "$(id -u)" -eq 0 ] && SUDO=""
if [ -z "${ENGINE:-}" ]; then
    if command -v docker >/dev/null && $SUDO docker info >/dev/null 2>&1; then ENGINE=docker
    elif command -v podman >/dev/null; then ENGINE=podman
    else echo "Neither a running docker daemon nor podman found."; exit 1; fi
fi
echo "Engine: $ENGINE   script: $SCRIPT   output: $OUT"

mkdir -p "$OUT"
if ls "$OUT"/egos-*-amd64.iso >/dev/null 2>&1; then
    echo "$OUT already holds an ISO: move or delete it first."; exit 1
fi

$SUDO "$ENGINE" build --network=host -q -t "$IMAGE" "$HERE" >/dev/null
start=$SECONDS
rc=0
$SUDO "$ENGINE" run --rm --privileged --network=host \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$SCRIPT:/src/EgOS4-amd64.sh:ro" \
    -v "$OUT:/out" \
    "$IMAGE" || rc=$?
echo "Build finished in $(( (SECONDS - start) / 60 )) min, exit $rc; log: $OUT/build.log"
ls -l "$OUT"/egos-*-amd64.iso 2>/dev/null || true
exit $rc
