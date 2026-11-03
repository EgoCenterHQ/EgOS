#!/bin/bash
# Runs inside a throwaway egos-builder container (--rm --privileged):
# builds in the container's own filesystem, copies only the ISO and the log
# to /out. The build script is mounted read-only at /src/EgOS4-amd64.sh.
set -euo pipefail
[ -f /src/EgOS4-amd64.sh ] || { echo "/src/EgOS4-amd64.sh not mounted"; exit 1; }
[ -d /out ] || { echo "/out not mounted"; exit 1; }
mkdir -p /build && cd /build
cp /src/EgOS4-amd64.sh .
rc=0
bash EgOS4-amd64.sh > /out/build.log 2>&1 || rc=$?
cp egos-*-amd64.iso /out/ 2>/dev/null || true
echo "exit=$rc" >> /out/build.log
chown "${HOST_UID:-0}:${HOST_GID:-0}" /out/build.log /out/egos-*-amd64.iso 2>/dev/null || true
tail -3 /out/build.log
exit $rc
