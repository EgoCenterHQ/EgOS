#!/bin/bash
# Runs inside a throwaway egos-builder-arm64 container (--rm --privileged).
# The build script is mounted read-only at /src/EgOS4-arm64.sh; only the image
# and the log are copied to /out.
#  - EgOS4-arm64.sh requires an ext2/3/4 work folder (it refuses DrvFs/9p and
#    the container's overlayfs): the build runs in an ext4 file on a loop device.
#  - arm64 emulation: qemu-aarch64 is registered in the host kernel's binfmt_misc
#    only for the duration of the build, and removed on exit (if it was not
#    there before). Nothing is installed on the host.
set -uo pipefail
[ -f /src/EgOS4-arm64.sh ] || { echo "/src/EgOS4-arm64.sh not mounted"; exit 1; }
[ -d /out ] || { echo "/out not mounted"; exit 1; }

REG=/proc/sys/fs/binfmt_misc
mountpoint -q $REG || mount -t binfmt_misc binfmt_misc $REG
ADDED=0
if [ ! -e $REG/qemu-aarch64 ]; then
    cat /usr/lib/binfmt.d/qemu-aarch64.conf > $REG/register && ADDED=1
fi
echo "binfmt qemu-aarch64: $(head -2 $REG/qemu-aarch64 | tr '\n' ' ') (added=$ADDED)"

cleanup() {
    cd /
    umount /build 2>/dev/null
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null
    rm -f /work.ext4
    if [ "$ADDED" = 1 ]; then echo -1 > $REG/qemu-aarch64 && echo "binfmt qemu-aarch64 removed"; fi
}
trap cleanup EXIT

truncate -s 30G /work.ext4 && mkfs.ext4 -q /work.ext4 || exit 1
# /dev in a privileged container is a snapshot taken at start: create the
# node of the free loop device if the kernel allocated a new one
# losetup -f prints "/dev/loopN (lost)" when the node is missing here: keep the name only
LOOP=$(losetup -f) || { echo "no free loop device"; exit 1; }
LOOP=${LOOP%% *}
[ -b "$LOOP" ] || mknod "$LOOP" b 7 "${LOOP#/dev/loop}"
losetup "$LOOP" /work.ext4 || { echo "losetup $LOOP failed"; exit 1; }
mkdir -p /build && mount "$LOOP" /build || { echo "mount $LOOP failed"; exit 1; }
echo "work dir: $LOOP on /build ($(stat -f -c %T /build))"

cp /src/EgOS4-arm64.sh /build/ && cd /build
rc=0
bash EgOS4-arm64.sh > /out/build.log 2>&1 || rc=$?
cp egos-*-arm64.img /out/ 2>/dev/null || true
echo "exit=$rc" >> /out/build.log
chown "${HOST_UID:-0}:${HOST_GID:-0}" /out/build.log /out/egos-*-arm64.img 2>/dev/null || true
tail -3 /out/build.log
exit $rc
