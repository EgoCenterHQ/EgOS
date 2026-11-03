# EgOS4-arm64.sh

| | |
|---|---|
| **Type** | build script, self-contained |
| **Path** | `builder-arm64-raspPi/EgOS4-arm64.sh` |
| **Output** | `egos-<version>-arm64.img`: an **already installed** image (not an installer: the Pi 5 does not boot ISO/GRUB and d-i does not support it) |
| **Hardware** | Raspberry Pi 5 (8 GB) + NVMe |
| **Base** | Debian 13 "trixie" arm64, kernel `linux-image-rpi-v8` (4K pages) |
| **Version** | `EGOS_VERSION=4.3.0`, Immich `v3.2.2`, Jellyfin `12.1` |
| **Role** | **reference** for the shared parts: sections 5b–11 and the shared part of 11b are identical in `EgOS4-amd64.sh` |

## Build environment

Recommended: throwaway container from any Linux host with docker or podman, see [builder.md](builder.md).

```bash
builder-arm64-raspPi/build-img.sh      # from the repository root -> ./out/egos-<version>-arm64.img
```

By hand: WSL2 Debian 13 (x86_64) with arm64 emulation through qemu.

```bash
mkdir -p ~/egos-arm64 && cd ~/egos-arm64      # this script only, on the WSL ext4 (NEVER /mnt/c)
sudo apt-get update
sudo apt-get install -y mmdebstrap arch-test qemu-user qemu-user-binfmt \
    e2fsprogs dosfstools mtools fdisk curl ca-certificates
sudo bash EgOS4-arm64.sh 2>&1 | tee build.log
KEEP_ROOTFS=1 sudo -E bash EgOS4-arm64.sh     # reuses rootfs/ (skips mmdebstrap, ~11 min)
```

**Writing to the NVMe**: from Windows with Raspberry Pi Imager → "Use custom" →
`\\wsl.localhost\<distro>\home\<user>\egos-arm64\egos-4.3.0-arm64.img` (NVMe through a USB adapter), or `dd`
from a native Linux. In the Pi 5 EEPROM `BOOT_ORDER` must include `6` (NVMe): `rpi-eeprom-config`.

## Resulting flow

```
1st boot → egos-growroot (grows the partition) → first-boot-setup.service
           → webapp :80 → setup-data.json → user → REBOOT
2nd boot → time-sync + DNS → docker-compose-startup.service
           → dirtree.sh → wizardall2.sh                        (egocenter.local)
```

## Global variables

| Variable | Meaning |
|---|---|
| `W` | the script's folder |
| `ROOT` / `OVL` / `KEYS` | `rootfs/`, `overlay/`, `keys/` |
| `EGOS_VERSION`, `IMMICH_VERSION`, `JELLYFIN_VERSION`, `BUILD_DATE` | as in amd64 |
| `IMG` | `egos-<version>-arm64.img` |
| `LABELID` | `45474f53` ("EGOS"): `PARTUUID=45474f53-01` (boot) and `-02` (root) |
| `BOOT_MB` | 512 |
| `KEEP_ROOTFS` | `1` = reuse the existing rootfs |

Initial checks: run as root; the folder must be on ext2/3/4 (not DrvFs `/mnt/c`, which loses owners and
permissions); commands `mmdebstrap arch-test mke2fs mkfs.vfat mcopy sfdisk curl gpg`.

## Sections

| # | Section | What it does |
|---|---|---|
| 0 | Emulation | if the host is not aarch64: mounts `binfmt_misc`, restarts `systemd-binfmt` (or runs it by hand if WSL has no systemd), checks with `arch-test arm64` |
| 1 | apt keys | Raspberry Pi key taken from pi-gen (re-signed SHA-512: the one from archive.raspberrypi.com uses SHA-1 signatures rejected by apt 3.x since 2026-02-01) with fingerprint `CF8A…303E`; Docker key with fingerprint `9DC8…CD88`. Also copied to the host |
| 5b–11a | Shared | identical to amd64: `/etc/issue`, avahi, services, `setup-webapp.sh`, `webapp.py`, `deploy-compose.sh`, `dirtree.sh`, stack, `/etc/egos-release`, extras |
| 11b | Pi-specific + shared | hostapd patch for `brcmfmac` (mandatory country code, rfkill), banner, `egos-storage` and units, Cockpit page, network, NTP, **`egos-growroot`**, `egos-sshkeys`, `config.txt`, `cmdline.txt`, `fstab` |
| 12 | rootfs | `mmdebstrap --variant=important` with the packages (below); hooks: copy the overlay, install cockpit without Recommends, purge `ifupdown dhcpcd-base dmidecode`, hostname `egocenter`, `/etc/hosts`, time zone `Europe/Rome`, locale `it_IT.UTF-8`, keyboard `it`, root password, `docker` group, enable the services, disable hostapd/dnsmasq, remove the SSH keys, `resolv.conf` → stub, empty `machine-id`. Then: Docker key in the final system (security updates), aliases in `/etc/skel/.bashrc` |
| 13 | Kernel | finds the `*-rpi-v8` kernel, temporarily disables the `z50-raspi-firmware` hook (it needs `/boot/firmware` mounted), generates the initramfs, copies `kernel8.img`, `initramfs8`, the `bcm2712*` DTBs and the overlays into `/boot/firmware` |
| 14 | Checks | critical packages (also `linux-image-rpi-v8`), no second network manager, release, pinned versions, no SSH keys, `egos-sshkeys` enabled, `resolv.conf` link, aliases, Cockpit page, reattach, pool units, stack on the pool |
| 15 | Image | **without loop devices**: `mkfs.vfat -C` for the boot partition (512 MB, `EGOSBOOT`) filled with `mcopy`; `mke2fs -d` for the root (`EGOSROOT`, size = rootfs × 1.3 + 512 MB); `sfdisk` with a DOS table and fixed label-id; `dd` of the two partitions into the image; label-id check |

### Packages (section 12)

`systemd-sysv systemd-resolved systemd-timesyncd dbus udev kmod locales keyboard-configuration console-setup tzdata
initramfs-tools linux-image-rpi-v8 raspi-firmware firmware-brcm80211 wireless-regdb rfkill cloud-guest-utils e2fsprogs
dosfstools zstd hostapd dnsmasq avahi-daemon python3 iptables iw curl ca-certificates samba wsdd2 sudo htop nano less
lsof rsync openssh-server mergerfs parted attr net-tools progress git python3-requests docker-ce docker-ce-cli
containerd.io docker-buildx-plugin docker-compose-plugin` + `cockpit-ws cockpit-bridge cockpit-system`.

Repositories: Debian trixie and trixie-security, `archive.raspberrypi.com`, Docker.

### Boot files

| File | Contents |
|---|---|
| `/boot/firmware/config.txt` | `arm_64bit=1`, `kernel=kernel8.img` (4K pages: compatibility with arm64 Docker images that use jemalloc), `auto_initramfs=1`, `dtparam=pciex1` (NVMe HAT without HAT+ EEPROM) |
| `/boot/firmware/cmdline.txt` | `console=serial0,115200 console=tty1 root=PARTUUID=45474f53-02 rootfstype=ext4 fsck.repair=yes rootwait` |
| `/etc/fstab` | root `PARTUUID=…-02` ext4 `noatime`; boot `PARTUUID=…-01` vfat |

## Differences from amd64

| | amd64 | arm64 |
|---|---|---|
| Output | ISO + installer | ready-made image |
| Build | throwaway `debian:trixie` container + live-build | throwaway `debian:trixie` container (or WSL2) + mmdebstrap + qemu-user |
| Docker | `.deb` files downloaded and installed locally | apt repository during mmdebstrap |
| First boot | — | `egos-growroot` grows the root |
| Hostname/locale | from the d-i preseed | from the mmdebstrap hooks |

## Functions

No functions of its own in the script; the function in `egos-growroot.sh` is described in
[egos-growroot.md](egos-growroot.md).
