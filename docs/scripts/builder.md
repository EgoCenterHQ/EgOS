# Builders — building the ISO and the Pi image in throwaway containers

| | amd64 | arm64 (Raspberry Pi 5) |
|---|---|---|
| **Folder** | `builder-amd64/` | `builder-arm64-raspPi/` |
| **Build script** | `EgOS4-amd64.sh` | `EgOS4-arm64.sh` |
| **Host command** | `build-iso.sh` | `build-img.sh` |
| **Container image** | `egos-builder`: `debian:trixie` + `live-build curl ca-certificates gnupg` | `egos-builder-arm64`: `debian:trixie` + `mmdebstrap arch-test qemu-user qemu-user-binfmt e2fsprogs dosfstools mtools fdisk curl ca-certificates gnupg util-linux` |
| **Output** | `OUT/egos-<version>-amd64.iso` + `OUT/build.log` | `OUT/egos-<version>-arm64.img` + `OUT/build.log` |
| **Time** | ~6 min | ~10 min (arm64 emulated) |
| **Requirements** | Linux with docker (daemon running) or podman; `sudo` | the same + the host's `loop` module, ~30 GB of sparse space in the engine's storage |

## Usage

```bash
# from the repository root
builder-amd64/build-iso.sh                  # -> ./out/egos-<version>-amd64.iso
builder-arm64-raspPi/build-img.sh ~/img     # output folder of your choice
ENGINE=podman builder-amd64/build-iso.sh    # force podman (default: docker if the daemon answers)
SCRIPT=/other/EgOS4-amd64.sh builder-amd64/build-iso.sh
```

Each host command stops if the output folder already holds an ISO/image, so as not to overwrite it.

## How it works (both)

1. `docker build --network=host` (or `podman build`) creates the builder image from the folder's `Dockerfile`. It holds only
   the tools; it is rebuilt from the layer cache. `.dockerignore` keeps the build script out of the image.
2. `docker run --rm --privileged --network=host` starts a throwaway container with:
   - the build script mounted **read-only** at `/src`;
   - the output folder mounted at `/out` (the only one shared with the host).
3. Inside the container `build-in-container.sh` copies the script to `/build`, runs the build, copies **only**
   the image and the log to `/out` and gives them to the host user.
4. When the build ends the container is deleted: no chroot, rootfs, cache or `binary/` is left on the host
   (about 5 GB with the manual method), so **no `lb clean`** or `rm -rf rootfs` is needed between builds.

## arm64 specifics (`builder-arm64-raspPi/build-in-container.sh`)

- **ext4 work folder**: `EgOS4-arm64.sh` refuses any work folder that is not ext2/3/4 (it guards against
  WSL's DrvFs `/mnt/c`), and the container's own filesystem is overlayfs. The build therefore runs in a 30 GB
  sparse `/work.ext4` file, attached to a free loop device and mounted on `/build`. `/dev` in a privileged
  container is a snapshot taken at start, so if the kernel hands out a new loop device the script creates its
  node with `mknod`. On exit: unmount, `losetup -d`, file deleted.
- **arm64 emulation**: binfmt_misc belongs to the host kernel. If `qemu-aarch64` is not registered, the script
  registers it from the container's `/usr/lib/binfmt.d/qemu-aarch64.conf` (flags `OPF`: the interpreter is
  opened at registration time, so it works inside mmdebstrap's chroot) and **removes it on exit**. If it was
  already registered on the host, it is left alone. Nothing is installed on the host.
- The build itself is the unchanged `EgOS4-arm64.sh`: section 0 finds the emulation working (`arch-test arm64`).

## Notes

- Both need **root + `--privileged`**: live-build and mmdebstrap mount `/proc` and create devices in the
  chroot; the arm64 builder also needs loop devices and binfmt_misc. A rootless engine is not enough.
- Every build downloads the packages again (~1 GB amd64, more for arm64).
- Both build and run use **`--network=host`**: on some hosts the engine's bridge network cannot reach the
  internet (firewall/VPN dropping forwarded traffic, docker rules lost, DNS fallback blocked) and the build
  stops at the first `apt-get update` of the Dockerfile. With the host network the builder needs only what
  the host itself can reach.
- Verified on 2026-10-29: amd64 with podman and Docker 29.9.2 (ISO installed in a VM up to the setup page);
  arm64 with Docker 29.9.2 (all section-14 checks, image contents inspected read-only; not boot-tested,
  there is no Pi 5 emulation).
- The amd64 ISO also includes the udebs of the previous installer kernel (~33 MB more than the manual build
  with a cache): the installer uses only those of its own kernel.
