# EgOS

EgOS turns a small home computer into a self-hosted media centre: **Jellyfin** (films, series, music),
**Immich** (phone photo backup), a **home page** with a card for every service (`:8000`), a **Samba** share and the **Cockpit** admin console, on Debian 13 "trixie".
Disks are joined into a single **mergerfs pool** that can grow, shrink and survive a missing disk.

Two editions, each a self-contained build script with a throwaway-container builder:

| Folder | Builds | Script |
|---|---|---|
| `builder-amd64/` | ISO with a fully automatic installer, for x86-64 PCs | `EgOS4-amd64.sh` |
| `builder-arm64-raspPi/` | ready-made image for a Raspberry Pi 5 with NVMe | `EgOS4-arm64.sh` |

## Build

Requirements: Linux with **docker** (daemon running) or **podman**, and `sudo`.

```bash
builder-amd64/build-iso.sh                 # -> ./out/egos-<version>-amd64.iso + build.log   (~6 min)
builder-arm64-raspPi/build-img.sh          # -> ./out/egos-<version>-arm64.img + build.log   (~10 min)
ENGINE=podman builder-amd64/build-iso.sh   # force podman (default: docker if its daemon answers)
```

Each build runs in a throwaway `debian:trixie` container (`--privileged`: live-build and mmdebstrap need
it) and copies back only the image and the log. The arm64 builder emulates arm64 with qemu: it registers
`qemu-aarch64` in the host's binfmt_misc only for the duration of the build and needs the host's `loop`
module. The builds download from `deb.debian.org`, `download.docker.com` and (arm64)
`archive.raspberrypi.com`; the apt keys are fingerprint-checked. See
[docs/scripts/builder.md](docs/scripts/builder.md); for the manual methods,
[EgOS4-amd64.md](docs/scripts/EgOS4-amd64.md) and [EgOS4-arm64.md](docs/scripts/EgOS4-arm64.md).

## Install

**PC**: write the ISO to a USB stick, boot the PC from it on a wired network: the installation is unattended
and **erases the target disk**. **Raspberry Pi 5**: write the image to the NVMe (Raspberry Pi Imager →
"Use custom", or `dd`); the root partition grows to the whole disk at the first boot. At the first boot connect to the `SetupBox` Wi-Fi (or open
`http://setupbox.local`), create the user, and the box deploys the stack by itself.
The full guide is the manual: [docs/manual/EgOS-manual.pdf](docs/manual/EgOS-manual.pdf).

## Layout

| Path | Contents |
|---|---|
| `builder-amd64/` | `EgOS4-amd64.sh` (build script: every file installed on the box is embedded as a heredoc), `build-iso.sh` (host), `Dockerfile`, `build-in-container.sh` |
| `builder-arm64-raspPi/` | `EgOS4-arm64.sh`, `build-img.sh` (host), `Dockerfile`, `build-in-container.sh` |
| `docs/` | manual (Markdown source, HTML, PDF) and one reference page per generated script |

The two scripts share sections 5b–11 (services, webapp, stack, storage, Cockpit page) byte for byte;
`EgOS4-arm64.sh` is the reference: change it first, then copy the shared block into `EgOS4-amd64.sh`.

## Security

Read the "Security and known limits" chapter of the manual before deploying.

**WARNING: the default credentials are placeholders written in the build scripts: root password
`CHANGE_ME` (user `root`), and `YOU` / `CHANGE_ME` wherever a default user is mentioned. Every image
built from this repo has the same root password: change it before building, or right after installing.**

- Before building: replace `CHANGE_ME` in `builder-amd64/EgOS4-amd64.sh` (the two
  `d-i passwd/root-password` lines of the preseed) and in `builder-arm64-raspPi/EgOS4-arm64.sh`
  (the `echo root:CHANGE_ME | chroot "$1" chpasswd` hook).
- After installing, logged in as the user created at the first boot: `sudo passwd root` to set a new
  root password, or `sudo passwd -l root` to lock root (sudo keeps working).

## License

GPL-3.0-or-later: see [LICENSE](LICENSE). The logos of the services shown on the EgOS home page
belong to their owners and are not covered by this license: see [NOTICE](NOTICE).
