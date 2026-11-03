# EgOS 4.3.0 documentation

## Instruction manual (booklet)

| File | Use |
|---|---|
| [manual/EgOS-manual.pdf](manual/EgOS-manual.pdf) | A5 booklet, for reading on screen |
| [manual/EgOS-manual-booklet.pdf](manual/EgOS-manual-booklet.pdf) | for printing: A4 landscape duplex (short edge), fold in half and staple |
| [manual/EgOS-manual.html](manual/EgOS-manual.html) | the same content, in the browser |
| [manual/manual.md](manual/manual.md) | source of Parts I (use) and II (administration) |
| [manual/build-manual.py](manual/build-manual.py) | regenerates HTML and PDF; Part III is taken from `scripts/*.md` |

Regenerating after a change:

```bash
cd docs/manual
python3 -m venv venv && venv/bin/pip install markdown weasyprint pypdf   # once
venv/bin/python build-manual.py            # --no-pdf for the HTML only
```

## One document per script

### Build

| Document | Script |
|---|---|
| [EgOS4-arm64.md](scripts/EgOS4-arm64.md) | `builder-arm64-raspPi/EgOS4-arm64.sh` — Raspberry Pi 5 image (reference for the shared parts) |
| [EgOS4-amd64.md](scripts/EgOS4-amd64.md) | `builder-amd64/EgOS4-amd64.sh` — ISO with automatic installer |
| [builder.md](scripts/builder.md) | `build-iso.sh`, `build-img.sh` — building ISO and Pi image in throwaway containers (docker/podman) |
| [hook-live-build.md](scripts/hook-live-build.md) | `0400-egos.hook.chroot`, `0500-bootloader-default.hook.binary` |

### First and second boot

| Document | Script |
|---|---|
| [setup-webapp.md](scripts/setup-webapp.md) | `setup-webapp.sh` — access point, portal, user creation |
| [webapp-py.md](scripts/webapp-py.md) | `webapp.py` — setup form |
| [egos-growroot.md](scripts/egos-growroot.md) | `egos-growroot.sh` (Pi only) |
| [deploy-compose.md](scripts/deploy-compose.md) | `deploy-compose.sh` |
| [dirtree.md](scripts/dirtree.md) | `dirtree.sh` — folders, credentials, `.env`, Samba |
| [wizardall2.md](scripts/wizardall2.md) | `wizardall2.sh` — Immich and Jellyfin setup through their APIs |
| [stack-configuration.md](scripts/stack-configuration.md) | `docker-compose.yml`, `env.template`, JSON files |
| [egos-home.md](scripts/egos-home.md) | `home.py` + `docker-proxy.cfg` — home page with one card per container |

### Storage

| Document | Script |
|---|---|
| [egos-storage.md](scripts/egos-storage.md) | `egos-storage` — mergerfs pool, every function |
| [cockpit-storage-pool.md](scripts/cockpit-storage-pool.md) | Cockpit page "Storage pool" (`egos-storage.js`) |
| [systemd-udev-units.md](scripts/systemd-udev-units.md) | systemd units, drop-ins, udev rule, network |

### Optional services

| Document | Script |
|---|---|
| [egos-extras.md](scripts/egos-extras.md) | `egos-extras` and the qbtt/bento stacks |
| [torrent_web.md](scripts/torrent_web.md) | `torrent_web.py` |
| [qbt-sort.md](scripts/qbt-sort.md) | `qbt-sort.py` |
| [audiotags.md](scripts/audiotags.md) | `audiotags.py` |
