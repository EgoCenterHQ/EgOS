<!-- Source of the EgOS manual. Parts I and II are here; Part III (technical reference)
     is assembled by build-manual.py from ../scripts/*.md. -->

# Welcome {.part-start data-part="Part I — User guide"}

Thank you for choosing **EgOS**, the system that turns a small home computer into a personal media
centre: your photos, films, music and series, always at hand on every device in your home network,
with no subscriptions and no third-party cloud.

This booklet takes you from installation to everyday use. **Part I** is for the people who use the
box; **Part II** is for whoever administers it; **Part III** describes, script by script and function
by function, how the system is built.

## What EgOS does

| Service | What it is for | Address |
|---|---|---|
| **Home page** | one card per service, with a link to each | `http://egocenter.local:8000` |
| **Jellyfin** | watch films and series, listen to music from TV, phone, browser | `http://egocenter.local:8096` |
| **Immich** | backup and gallery for your phone's photos | `http://egocenter.local:2283` |
| **Shared folder** (Samba) | copy media files from your PC | `\\egocenter.local\media` |
| **Cockpit** | administration console and disk management | `https://egocenter.local:9090` |
| **SSH** | terminal access | `ssh user@egocenter.local` |

## Contents and requirements

| Edition | For | Installation medium |
|---|---|---|
| `egos-4.3.0-amd64.iso` | x86-64 PC, mini PC, virtual machine | USB stick (automatic installation) |
| `egos-4.3.0-arm64.img` | Raspberry Pi 5 with NVMe SSD | image written directly to the NVMe |

You also need:

- an Internet connection over an **Ethernet cable** (needed at the second boot to download the services);
- a phone or a PC for the initial setup;
- optional: one or more external USB disks for more space.

## Warnings

> **Warning** — Installing on a PC **completely erases** the target disk without asking for
> confirmation. If the computer has several disks, the installer asks which one to use: choose carefully.

> **Warning** — Adding a disk to the pool **erases everything** on it. EgOS always asks, and wants you
> to type the disk's name to confirm.

> **Note** — EgOS does not use RAID: if a data disk fails you lose the files that were on it, not those
> on the other disks. Keep a copy of important photos somewhere else.

# Installation

## On a PC (amd64)

1. Write `egos-4.3.0-amd64.iso` to a USB stick (with `dd`, balenaEtcher, Rufus in DD mode, etc.).
2. Connect the PC to the network with the **Ethernet cable**.
3. Boot the PC from the stick (BIOS or UEFI, either works).
4. The menu opens on **Start installer** and starts by itself after **5 seconds**.
5. The installation is fully automatic (about 5 minutes): Italian language, Italian keyboard,
   Europe/Rome time zone, machine name `egocenter`.
6. When it is done the PC **powers off**. Remove the stick.

## On a Raspberry Pi 5 (arm64)

1. Connect the NVMe SSD to your PC with a USB adapter.
2. Write `egos-4.3.0-arm64.img` to the NVMe with **Raspberry Pi Imager** → *Use custom*
   (or with `dd` from Linux).
3. Fit the NVMe to the Pi 5. In the EEPROM, the boot order (`BOOT_ORDER`) must include the value `6`
   (NVMe): check it with `rpi-eeprom-config`.
4. Connect the Ethernet cable and the power supply.

At the first boot the system grows its partition by itself to fill the whole NVMe.

> **Tip** — With a monitor connected, the login screen shows the box's IP address and the useful
> addresses. Handy when the `.local` name does not work.

# First boot: guided setup

At the first boot EgOS serves a small setup page. You can reach it in two ways.

## Over Wi-Fi (if the box has Wi-Fi)

1. On your phone, look for the Wi-Fi network **SetupBox** and connect.
2. The network password is `setup1234`.
3. The phone opens the "Sign in to network" page by itself; if it does not, open any `http://`
   address in the browser.

## Over the cable

From a PC on the same network open **`http://setupbox.local`**, or `http://<box IP>` (shown on the
monitor connected to the box, or in your router's page).

## Fill in the form

| Field | Used for |
|---|---|
| **Email** | Immich administrator account |
| **Username** | user for the system, Jellyfin, the shared folder and Cockpit |
| **Password** | one password for all the services above |

Press **Complete Setup**. "Setup Complete" appears: the box turns off the SetupBox network and
**reboots**.

> **Warning** — During setup the page is not protected: whoever fills it in first becomes the
> administrator. Do the first boot in a trusted environment and complete it straight away.

# Second boot: automatic preparation

After the reboot the box, now reachable as **`egocenter.local`**, works on its own:

1. it waits until the clock is synchronised and the Internet answers;
2. it creates the folders for films, music, series, ROMs, downloads and photos;
3. it prepares the shared folder with your username and password;
4. it downloads and starts Immich and Jellyfin (a few GB: on a slow line this can take a long time);
5. it creates your administrator account in Immich and Jellyfin;
6. it starts the **home page** `http://egocenter.local:8000`, with a card for every service.

If something goes wrong (for example no Internet), the preparation **retries at the next boot**.

## Before you start: create the Jellyfin libraries

Jellyfin is configured in Italian, but the libraries have to be added by hand, once:
open Jellyfin → **Dashboard** → **Libraries** → **Add Media Library**.

| Content type | Folder to choose | Where to copy the files |
|---|---|---|
| Movies | `/Films` | `media\Films` |
| Shows | `/Serie` | `media\SerieTv` |
| Music | `/Musics` | `media\Musics` |
| (optional) Other | `/ROMs` | `media\ROMs` |

# Everyday use

## Copying films, music and series

From your PC open the shared folder **media** and sign in with your username and password.

| System | Address |
|---|---|
| Windows | in File Explorer: `\\egocenter.local\media` (the box also appears under **Network**) |
| macOS | Finder → Go → Connect to Server → `smb://egocenter.local/media` |
| Linux | `smb://egocenter.local/media` in the file manager |

Organise the files like this (these are the names Jellyfin recognises best):

```
Films/Inception (2010)/Inception (2010).mkv
SerieTv/Dark (2017)/Season 01/Dark (2017) - S01E01.mkv
Musics/Artist/Album/01 - Track.flac
```

Jellyfin picks up new files by itself; you can force a scan from **Dashboard → Libraries**.

## Watching and listening

Open `http://egocenter.local:8096` in the browser, or install the **Jellyfin** app on your TV, phone or
tablet and enter `http://egocenter.local:8096` (or the box's IP) as the server.

## Phone photos

Install the **Immich** app, enter `http://egocenter.local:2283` as the server, sign in with the
**email and password** from the setup and turn on automatic backup.

## The administration console (Cockpit)

Open `https://egocenter.local:9090`. The browser reports an untrusted certificate (it is
self-signed): accept the risk to continue. Sign in with your username and password.
For disk operations click **Limited access** at the top right and enter your password again.

The **Storage pool** page is described in the next chapter. The **Overview** page shows a red banner
only when a pool disk is missing.

## The home page

Open `http://egocenter.local:8000`: one card for every service of the box, with a link to it. The page
follows Docker by itself: a container that publishes a web page gets a card within 15 seconds (the optional
services too, once enabled), a stopped one turns grey, one whose health check fails gets a yellow border.
Cockpit always has its card. Databases and other non-web ports never appear.

# Disks: the storage pool

EgOS gathers all the space into one big folder, the **pool** (`/srv/egos/pool`). At first the pool
lives on the system disk; every disk you add joins the pool **without moving anything and without
stopping the services**. Films, photos and the shared folder always see the same paths.

| Situation | Where new files go |
|---|---|
| No external disk | system disk |
| One or more disks | the disk with the most free space |
| A disk unplugged | the other disks; that disk's files are not visible until it is back |

Each disk needs at least **20 GB free** to receive new files. Once there are data disks, the system disk
no longer receives new files: if every data disk drops below 20 GB free, writes fail with a
"read-only file system" error. This is intended: the system disk never fills up.

## Adding a disk

**From Cockpit:** Storage pool → *Disks that can be added* → **Add to pool** → type the disk's name
(e.g. `/dev/sda`) → **Erase and add**.

**From a terminal:** `storage-add`, choose the disk's number, type its name to confirm.

EgOS partitions and formats the disk, then runs an **integrity test**: it writes 128 MB of random data,
reads it back and compares it, checks for kernel errors and measures the speed. A "fake" disk
(counterfeit capacity) or a faulty one is rejected and does **not** join the pool.

## Emptying the system disk

After you add a disk, the files already there stay on the system disk (visible and working).
To move them: **Empty system disk** in Cockpit, or `storage-drain`. The paths do not change and the
services keep working during the move. Files changed in the last 10 minutes are left for the next run.
You can close the page: the operation carries on on the server.

## Removing a disk

1. With the disk **still connected**: **Remove** on its row (or `storage-remove`).
2. Type the branch name (e.g. `data1`) to confirm. The disk is **not** formatted.
3. Wait for the message **YOU CAN NOW SAFELY UNPLUG THE DISK**, then unplug it.

If it was the last disk, new files go back to the system disk.

## If a disk gets disconnected

At boot EgOS waits 60 seconds for the disks, then starts anyway in **degraded** mode:

- the missing disk's files are not visible;
- **Jellyfin stays off** on purpose: otherwise its library scan would delete the missing titles
  together with their metadata and watch history;
- Immich and the shared folder keep working;
- a red banner appears in Cockpit (Overview and Storage pool) and at SSH login.

**Plug the disk back in**: it is remounted **automatically** within seconds and Jellyfin restarts.
Alternatively press **Retry missing disks** (`storage-reattach`). If the disk is gone for good,
press **Remove** on its row.

# Optional services

The image contains two extra services, **off** until you turn them on.

| Name | What it offers | Addresses |
|---|---|---|
| `qbtt` | qBittorrent + search page + automatic sorting of downloads into Films, SerieTv, Musics | `:8082` client, `:8083` search |
| `bento` | PDF tools in the browser (merge, split, compress…) | `:8080` |

```
egos-extras list             # list and status
egos-extras enable qbtt      # the first time it stops: edit the .env it names
egos-extras enable qbtt      # second time: starts
egos-extras disable qbtt     # stops (files and data stay)
```

For `qbtt`, at the first start follow the `README.md` in its folder: temporary password
(`docker logs qbittorrent-nox`), Web UI credentials, "Bypass authentication for clients on localhost" and
the command `python3 /scripts/qbt-sort.py "%K"` to run when a download completes. Torrents that contain
executables or scripts are **not** moved and get a `POTENTIALLY HARMFUL` file.

# Command quick reference

| Command | Effect |
|---|---|
| `storage-status` | pool and disk status |
| `storage-add` | add a disk (erases it) |
| `storage-drain` | move files from the system disk to the data disks |
| `storage-remove` | remove a disk safely |
| `storage-reattach` | remount disks that were plugged back in |
| `egos-extras list` | optional services |
| `cat /etc/egos-release` | installed version |
| `cd ~/app/repos && docker compose ps` | container status |
| `cd ~/app/repos && docker compose restart` | restart the stack |
| `journalctl -u egos-pool` | pool log |
| `journalctl -u docker-compose-startup` | log of the 2nd-boot preparation |

# Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| I cannot see the **SetupBox** network | the box has no Wi-Fi | use the cable: `http://setupbox.local` or the IP |
| `setupbox.local` / `egocenter.local` does not open | the device does not support mDNS | use the IP address (box monitor or router) |
| After setup Jellyfin/Immich do not answer | download in progress or no Internet | wait; check `journalctl -u docker-compose-startup`; reboot: the preparation retries |
| Jellyfin does not start, red banner | a pool disk is missing | plug it back in (cable, power) or **Retry missing disks** |
| *Another storage operation is running* | another disk operation is in progress | wait for it to end and retry |
| *UNMOUNT REFUSED* while removing | something is using the disk | **do not unplug it**; `cd ~/app/repos && docker compose down`, repeat, then `docker compose up -d` |
| *FAILED: the data read back does not match* | counterfeit or faulty disk | do not use it |
| Copy fails with "read-only file system" (EROFS) | every data disk has less than 20 GB free: by design the system disk no longer takes new files | free some space or add a disk; it does not happen with large, non-full disks |
| Cockpit: *Administrative access needed* | session with limited access | **Limited access** at the top right → password |
| `egos-extras enable` stops at once | `.env` still contains `CHANGEME` | edit the file it names and run it again |
| Pool "not mounted" | pool service stopped | **Retry missing disks**; `systemctl status egos-pool` |

# Architecture {.part-start data-part="Part II — Administrator guide"}

EgOS is produced by **two self-contained scripts** that need no external files:

| Script | Output | Build environment |
|---|---|---|
| `EgOS4-arm64.sh` | ready-made image for the Pi 5 | throwaway `debian:trixie` container + mmdebstrap + qemu-user (`builder-arm64-raspPi/`), or WSL2 Debian 13 |
| `EgOS4-amd64.sh` | ISO with automatic installer | throwaway `debian:trixie` container + live-build (`builder-amd64/`) |

The shared parts (services, webapp, stack, disk management, Cockpit page) are **byte-for-byte
identical** in the two scripts.

```
1st BOOT
  egos-sshkeys ........ unique SSH keys per box
  egos-growroot ....... (Pi only) partition grown
  egos-pool ........... mergerfs pool on /srv/egos/local
  first-boot-setup
    └► setup-webapp.sh └► webapp.py :80 └► user └► reboot

2nd BOOT
  egos-pool └► docker, smbd
  docker-compose-startup
    └► deploy-compose.sh └► dirtree.sh └► wizardall2.sh
  egos-pool-guard ..... Jellyfin off if a disk is missing

ALWAYS
  udev "egos-data*" └► egos-reattach
    └► egos-storage _autoreattach
```

## Building the images

**amd64** (from any Linux with docker or podman): a throwaway container builds the ISO in its own
filesystem and hands back only the ISO and the log.

```
builder-amd64/build-iso.sh                 # -> ./out/egos-<version>-amd64.iso
ENGINE=podman builder-amd64/build-iso.sh   # force podman
```

By hand, with podman:

```
mkdir -p ~/egos-amd64 && cd ~/egos-amd64        # the script only
sudo podman run -it --rm --privileged --network=host \
  -v "$PWD:/build:Z" -w /build debian:trixie bash
apt-get update && apt-get install -y live-build curl ca-certificates gnupg
bash EgOS4-amd64.sh 2>&1 | tee /build/build.log
```

To rebuild by hand, run `lb clean` first (not needed with `builder-amd64/`).

**arm64** (from any Linux with docker or podman): the same throwaway-container approach. The container
works in an ext4 loop file and registers the arm64 emulation (qemu, binfmt) only for the duration of the build.

```
builder-arm64-raspPi/build-img.sh          # -> ./out/egos-<version>-arm64.img
```

By hand (WSL2 Debian 13, folder on the WSL ext4, never `/mnt/c`):

```
sudo apt-get install -y mmdebstrap arch-test qemu-user qemu-user-binfmt \
    e2fsprogs dosfstools mtools fdisk curl ca-certificates
sudo bash EgOS4-arm64.sh 2>&1 | tee build.log
KEEP_ROOTFS=1 sudo -E bash EgOS4-arm64.sh       # quick rebuild
```

Both scripts **stop with an error** if a check fails: apt key fingerprints, critical packages missing
or scheduled for removal, a second network manager, SSH keys in the image, missing files, unpinned
versions.

## Versions

Every change that ends up in the image bumps `EGOS_VERSION` (in both scripts). The installed system
records the build data in `/etc/egos-release`. Docker images are pinned: Immich `v3.2.2`,
Jellyfin `12.1`, Valkey and Postgres by digest.

# Where things are

| Path | Contents |
|---|---|
| `/srv/egos/pool/media/` | Films, Musics, SerieTv, ROMs, downloads (Jellyfin, Samba, qbtt) |
| `/srv/egos/pool/immich/upload/` | Immich originals |
| `/srv/egos/local/` | pool branch on the system disk |
| `/srv/egos/disks/dataN/` | data disks (ext4, label `egos-dataN`) |
| `~/app/repos/` | `docker-compose.yml`, `.env`, wizard and JSON files |
| `~/app/repos/egos-home/` | home page: `home.py`, `docker-proxy.cfg`, `icons/` |
| `~/app/immich/postgres/` | Immich database (**always** on the system disk) |
| `~/app/jellyfin/{config,cache}/` | Jellyfin configuration |
| `/usr/local/share/stack/` | original files of the stack and the extras |
| `/var/log/egos-storage/job.log` | log of the last disk operation |

## State files

| File | Meaning |
|---|---|
| `/var/lib/setup-data.json` | setup form data (holds the password in plain text) |
| `/var/lib/setup-complete` | setup done: the webapp does not start again |
| `/var/lib/docker-compose-done` | stack prepared: the deploy does not run again |
| `/var/lib/egos-growroot-done` | (Pi) partition already grown |
| `/run/egos/pool-degraded` | list of the missing disks |
| `/run/egos/pool-ok` | present only when the pool is complete (Jellyfin does not start without it) |
| `/var/lib/egos/jellyfin-held` | Jellyfin held stopped by EgOS |
| `/run/egos/storage.lock` | lock for disk operations |
| `/etc/fstab.egos-prev` | fstab before the last change |

To **redo** the 2nd-boot preparation: `sudo rm /var/lib/docker-compose-done && sudo systemctl enable docker-compose-startup` and reboot.

> **Note** — Since 4.2.2 `wizardall2.sh` can be re-run: once Jellyfin's startup wizard is complete it
> skips it (the `/Startup/*` APIs answer 401 then) instead of waiting forever.

## Network

One manager only: **systemd-networkd** (DHCP on `eth*`/`en*`) with **systemd-resolved**. mDNS is
handled by avahi, Windows discovery by wsdd2. Wi-Fi is used only for the first-boot access point.

| Port | Service |
|---|---|
| 22 | SSH |
| 80 | setup webapp (1st boot only) |
| 139, 445 | Samba |
| 2283 | Immich |
| 8000 | home page (egos-home) |
| 8096/tcp, 7358/udp | Jellyfin |
| 9090 | Cockpit |
| 8080, 8082, 8083, 6881 | optional extras |

# Security and known limits

What to know about the security of version 4.3.0 and about what EgOS does not handle yet.

| Item | Status | What to do |
|---|---|---|
| Fixed root password, the same on every box, written in the scripts (preseed / mmdebstrap hook) | **open** | after installing: `sudo passwd root` or `sudo passwd -l root` |
| Unique SSH keys per box | **solved** (4.0) | — |
| Web setup without authentication, AP with a public password | open | do the first boot in a trusted environment |
| `setup-data.json` keeps the password in plain text | open (`.env` already 0600) | — |
| One password for system, Samba, Immich, Jellyfin, Cockpit | open | change each service's password from its own interface |
| Security updates | partial: Docker repository kept (4.0), no `unattended-upgrades` | `sudo apt update && sudo apt upgrade` regularly |
| No firewall | open | restrict 22/445/9090 to the LAN |
| `DB_PASSWORD=password` for the Immich database (not exposed on any port) | open | — |
| SSH with password, `X11Forwarding yes`, no fail2ban | open | key-only access, `X11Forwarding no` |
| Samba/wsdd2/LLMNR also listening on the Docker bridges | open | `interfaces` + `bind interfaces only` in `smb.conf` |
| Immich database backup | missing | schedule a `pg_dump` to the pool |
| fstab written atomically and validated | **solved** (4.0) | — |
| Home page reads Docker | **limited** (4.3): through a proxy on 127.0.0.1:23750 that allows only `GET /containers/json` (names, images, ports, labels; no environment variables, logs or commands) | — |
| Disk unplugged **while** the box is running | not handled | the mount stays "dead" until reattach or reboot |


# Release notes

| Version | Date | Main changes |
|---|---|---|
| **4.3.0** | 2026-11-03 | home page **egos-home** on `:8000` in the base stack: one card per container, read from Docker through a proxy that allows only the container list |
| 4.2.3 | 2026-10-29 | qbt-sort warning file in English (`POTENTIALLY HARMFUL`) |
| 4.2.2 | 2026-10-29 | `wizardall2.sh` can be re-run (skips Jellyfin's startup wizard once completed) |
| 4.2.1 | 2026-10-29 | **automatic** reattach when a disk is plugged back in; operation lock; missing-disk warning on Cockpit Overview and at SSH login |
| 4.2.0 | 2026-10-28 | pool present from the first boot; `drain`; 60 s wait and degraded boot; Jellyfin gate; immutable mount points |
| 4.1.0 | 2026-10-28 | Cockpit **Storage pool** page; non-interactive mode and jobs in `egos-storage` |
| 4.0.0 | 2026-10-28 | PC and Raspberry Pi editions aligned; versioning; sudo, SSH, Cockpit, mergerfs; networkd only; NTP; verified Docker keys; optional extras |
