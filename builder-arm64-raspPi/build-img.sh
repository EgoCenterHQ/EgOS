#!/bin/bash
# EgOS - builds the Raspberry Pi 5 (arm64) image in a throwaway container
# (docker or podman). Nothing stays on the host except the builder image
# (tools only) and OUT; the arm64 emulation is registered only during the build.
#
#   builder-arm64-raspPi/build-img.sh [OUT_DIR]    default OUT_DIR: ./out
#   ENGINE=podman builder-arm64-raspPi/build-img.sh   default: docker if its daemon answers, else podman
#   SCRIPT=/path/EgOS4-arm64.sh ...                default: EgOS4-arm64.sh in this folder
#
# Needs root (sudo), --privileged (loop device, binfmt_misc, chroot) and the
# host's loop module; about 10 minutes and 30 GB of sparse space in the
# engine's storage. Flash the result with Raspberry Pi Imager ("Use custom") or dd.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$(realpath "${SCRIPT:-$HERE/EgOS4-arm64.sh}")
OUT=$(realpath -m "${1:-./out}")
IMAGE=egos-builder-arm64
[ -f "$SCRIPT" ] || { echo "Build script not found: $SCRIPT"; exit 1; }

SUDO=sudo; [ "$(id -u)" -eq 0 ] && SUDO=""
if [ -z "${ENGINE:-}" ]; then
    if command -v docker >/dev/null && $SUDO docker info >/dev/null 2>&1; then ENGINE=docker
    elif command -v podman >/dev/null; then ENGINE=podman
    else echo "Neither a running docker daemon nor podman found."; exit 1; fi
fi
echo "Engine: $ENGINE   script: $SCRIPT   output: $OUT"

mkdir -p "$OUT"
if ls "$OUT"/egos-*-arm64.img >/dev/null 2>&1; then
    echo "$OUT already holds an image: move or delete it first."; exit 1
fi

$SUDO "$ENGINE" build --network=host -q -t "$IMAGE" "$HERE" >/dev/null
start=$SECONDS
rc=0
$SUDO "$ENGINE" run --rm --privileged --network=host \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$SCRIPT:/src/EgOS4-arm64.sh:ro" \
    -v "$OUT:/out" \
    "$IMAGE" || rc=$?
echo "Build finished in $(( (SECONDS - start) / 60 )) min, exit $rc; log: $OUT/build.log"
ls -l "$OUT"/egos-*-arm64.img 2>/dev/null || true
exit $rc
