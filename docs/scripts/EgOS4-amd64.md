# EgOS4-amd64.sh

| | |
|---|---|
| **Type** | build script, self-contained (no external files) |
| **Path** | `builder-amd64/EgOS4-amd64.sh` |
| **Output** | `egos-<version>-amd64.iso` (live-build `iso-hybrid`, d-i installer in "live" mode, unattended) |
| **Base** | Debian 13 "trixie" amd64 |
| **Version** | `EGOS_VERSION=4.3.0`, Immich `v3.2.2`, Jellyfin `12.1` |
| **Lines** | ~4150 |
| **Twin** | [EgOS4-arm64.md](EgOS4-arm64.md): sections 5b–11 and the shared part of 11b are **copied verbatim** from `EgOS4-arm64.sh`. They are edited there and then copied here. |

## Usage

Recommended: throwaway container, see [builder.md](builder.md).

```bash
builder-amd64/build-iso.sh      # from the repository root -> ./out/egos-<version>-amd64.iso
```

By hand:

```bash
# on the Linux host with podman, folder holding ONLY this script
mkdir -p ~/egos-amd64 && cd ~/egos-amd64
sudo podman run -it --rm --privileged --network=host \
  -v "$PWD:/build:Z" -w /build debian:trixie bash
# inside the container
apt-get update && apt-get install -y live-build curl ca-certificates gnupg
bash EgOS4-amd64.sh 2>&1 | tee /build/build.log
```

To rebuild by hand: `lb clean` in the same folder before running again (not needed with `builder-amd64/`). At the end: `sudo chown $USER:$USER egos-*.iso`.

## Resulting flow

```
USB → automatic d-i installation → power off (remove the USB stick)
1st boot → egos-sshkeys → first-boot-setup.service → webapp :80 (setupbox.local)
           → credentials → Linux user → REBOOT
2nd boot → time-sync + DNS → docker-compose-startup.service
           → dirtree.sh → wizardall2.sh                        (egocenter.local)
```

## Global variables

| Variable | Meaning |
|---|---|
| `EGOS_VERSION` | bumped on every change that ends up in the image |
| `IMMICH_VERSION`, `JELLYFIN_VERSION` | pinned Docker image tags |
| `BUILD_DATE` | UTC build date, written to `/etc/egos-release` |
| `ISO` | name of the final file |
| `OVL` | `config/includes.chroot`: root of the files copied into the system (same name as in the arm64 script) |
| `KEYS` | folder for the apt keys |

First of all the script checks that `lb curl gpg apt-get` exist.

## Sections

| # | Section | What it does |
|---|---|---|
| 1 | `lb config` | trixie, amd64, d-i "live", areas `main contrib non-free non-free-firmware`, firmware in chroot and binary, hybrid ISO, volume `EGOS_4_2_3` |
| 2 | Docker key | downloads the key, converts it (`gpg --dearmor`) and **checks the fingerprint** `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` (error 2 if missing). Puts it in the overlay and prepares `docker.list` in `/usr/local/share/egos/apt/` (copied into the system by `late_command`, not used during the build) |
| 3 | Preseed | `config/includes.installer/preseed.cfg`, see below |
| 4 | Package list | `egos.list.chroot`: systemd-resolved/timesyncd, hostapd, dnsmasq, avahi, python3(+requests), iptables, iw, rfkill, wireless-regdb, curl, samba, wsdd2, sudo, openssh-server, htop, nano, less, lsof, rsync, mergerfs, parted, attr, net-tools, progress, git, zstd, cockpit-ws/bridge/system |
| 4b | Docker .debs | adds the Docker repo **in the build container**, downloads `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin` into `config/packages.chroot/` (renames `%3a` to `.`) |
| 4c | Chroot hook `0400-egos` | see [hook-live-build.md](hook-live-build.md) |
| 5 | Binary hook `0500-bootloader-default` | installer as the default entry, 5 s timeout, BIOS and UEFI |
| 5b | Console and mDNS | `/etc/issue` (URLs and IP on the login screen), `avahi-daemon.conf` with the temporary name `setupbox` |
| 6 | Services | `first-boot-setup.service`, `docker-compose-startup.service` |
| 7 | `setup-webapp.sh` | see [setup-webapp.md](setup-webapp.md) |
| 8 | `webapp.py` | see [webapp-py.md](webapp-py.md) |
| 9 | `deploy-compose.sh` | see [deploy-compose.md](deploy-compose.md) |
| 10 | `dirtree.sh` | see [dirtree.md](dirtree.md) |
| 11 | Stack staging | `/usr/local/share/stack/`: `docker-compose.yml`, `egos-home/` (since 4.3), `wizardall2.sh`, `jellsrv.json`, `jellremot.json`, `env.template` (with the versions substituted) + `/etc/egos-release`. See [stack-configuration.md](stack-configuration.md) |
| 11a | Optional extras | `/usr/local/share/stack/extras/{qbtt,bento}` + `egos-extras`. Not started. See [egos-extras.md](egos-extras.md) |
| 11b | Shared overlays | hostapd patch (`country_code=IT`, `ieee80211d=1`, `rfkill unblock wlan`, checked with grep), extra lines in `/etc/issue`, `egos-storage`, aliases, pool/guard/reattach units, udev rule, empty `/etc/motd`, docker/smbd drop-ins, Cockpit page, networkd/resolved network, NTP wait, `egos-sshkeys.service` |
| 12 | Build | `lb build` |
| 13 | Checks | see below; then renames `live-image-amd64.hybrid.iso` to `$ISO` |

### Preseed (section 3)

| Area | Setting |
|---|---|
| Language/keyboard | `it_IT.UTF-8`, keyboard `it` pc105 |
| Network | automatic interface, hostname `egocenter`, domain `lan` (not `local`: that is the mDNS domain and would cause a false avahi conflict) |
| Mirror | `deb.debian.org` |
| Clock | UTC, `Europe/Rome`, **NTP on** (the TLS pulls of the 2nd boot need it) |
| Partitioning | `regular`, `atomic` recipe, no confirmation. With several disks d-i asks for the target disk |
| Accounts | root login enabled with a fixed password (see *Known issues*), no regular user (the webapp creates it) |
| Packages | no tasks, `full-upgrade` only: everything is already in the squashfs |
| Bootloader | GRUB on the default disk |
| `late_command` | removes `ifupdown dhcpcd-base isc-dhcp-client network-manager` and `/etc/network/interfaces`; enables networkd, resolved, timesyncd, time-wait-sync, avahi, wsdd2, docker, cockpit.socket, egos-sshkeys, first-boot-setup, docker-compose-startup, egos-pool, egos-pool-guard, ssh; disables hostapd/dnsmasq; creates the `docker` group; deletes the SSH host keys; copies `docker.list`; `resolv.conf` → resolved stub |
| End | no final message, **power off** |

### Final checks (section 13)

The build fails if:

- one of the critical packages is not installed in the chroot (`docker-ce containerd.io docker-compose-plugin samba wsdd2 hostapd dnsmasq avahi-daemon cockpit-ws sudo openssh-server htop rsync mergerfs parted attr git python3-requests systemd-resolved`);
- a second network manager is installed (`network-manager modemmanager wpasupplicant ppp ifupdown dhcpcd-base`);
- there are SSH host keys in the squashfs;
- `/etc/egos-release` is missing or has a different version;
- the aliases in `/etc/skel/.bashrc`, the Cockpit page files, the udev rule or `egos-reattach.service`, or the pool/guard units are missing;
- `env.template` does not point to the pool or has no pinned versions;
- **anti-purge**: a critical package appears in `binary/live/filesystem.packages-remove` (d-i would uninstall it at the end of the installation: it happened with cockpit installed by a hook).

## Functions defined in the script itself

The main script defines no functions of its own: it is a linear sequence of sections. The functions live in the
scripts it generates (see the other documents in this folder).
