# Stack configuration (compose, env, JSON)

Files staged in `/usr/local/share/stack/` by section 11 of the EgOS4 scripts and copied to
`~/app/repos/` by [dirtree.sh](dirtree.md).

## docker-compose.yml

Compose project **`egos`**, based on Immich's official compose file.

| Service | Container | Image | Ports | Volumes | Notes |
|---|---|---|---|---|---|
| `immich-server` | `immich_server` | `ghcr.io/immich-app/immich-server:${IMMICH_VERSION}` | 2283 | `${UPLOAD_LOCATION}:/data`, localtime | `restart: always`, healthcheck |
| `immich-machine-learning` | `immich_machine_learning` | `…/immich-machine-learning:${IMMICH_VERSION}` | — | volume `model-cache` | for acceleration: suffix `-cuda`, `-openvino`, `-armnn`… |
| `redis` | `immich_redis` | `valkey/valkey:9` pinned by digest | — | — | healthcheck `redis-cli ping` |
| `database` | `immich_postgres` | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` by digest | — | `${DB_DATA_LOCATION}` | `--data-checksums`, `shm_size 128mb`. **Local filesystem only**, never NFS/SMB |
| `docker-proxy` | `egos-home-docker-proxy` | `tecnativa/docker-socket-proxy:0.3.0` by digest | `127.0.0.1:23750` | `/var/run/docker.sock` (ro), `egos-home/docker-proxy.cfg` (ro, replaces the image's template) | since 4.3; allows only `GET /containers/json` and `/_ping`; `cap_drop: ALL`, `no-new-privileges` |
| `egos-home` | `egos-home` | `python:3.13-alpine` by digest | 8000 (host network) | `egos-home/home.py`, `egos-home/icons` (ro) | since 4.3; user 1000, read-only, healthcheck `/health`. See [egos-home.md](egos-home.md) |
| `jellyfin` | `jellyfin` | `jellyfin/jellyfin:${JELLYFIN_VERSION}` | 8096/tcp, 7358/udp | config, cache, `Films`, `Musics`, `SerieTv→/Serie` (ro), `ROMs` (ro), **gate** `/run/egos/pool-ok→/egos-pool-ok` (ro, `create_host_path: false`) | `restart: unless-stopped`, `JELLYFIN_PublishedServerUrl=http://localhost:8096`, `host.docker.internal` |

Restart policies: the four Immich services are `always`, Jellyfin `unless-stopped` (since 4.2: a Jellyfin
held stopped by EgOS stays stopped across a reboot too). `JELLYFIN_PublishedServerUrl=http://localhost:8096` is not
correct for clients connecting from other devices.

The **gate** stops Docker from starting Jellyfin while a pool disk is missing (see [egos-storage.md](egos-storage.md)).
Without `create_host_path: false` compose would pass the bind as a legacy `Binds` entry and Docker would create the missing source.

## env.template → .env

| Key | Value | Notes |
|---|---|---|
| `TZ` | `Europe/Rome` | |
| `UPLOAD_LOCATION` | `/srv/egos/pool/immich/upload` | Immich originals, on the pool |
| `DB_DATA_LOCATION` | `__HOME__/app/immich/postgres` | **system disk** |
| `DB_USERNAME` / `DB_PASSWORD` / `DB_DATABASE_NAME` | `postgres` / `password` / `immich` | default password, to be changed |
| `IMMICH_VERSION` | `v3.2.2` | substituted at build time for `@IMMICH_VERSION@` |
| `JELLYFIN_CONFIG_LOCATION`, `JELLYFIN_CACHE_LOCATION` | `__HOME__/app/jellyfin/{config,cache}` | system disk |
| `JELLYFIN_MEDIA_LOCATION` | `/srv/egos/pool/media` | on the pool |
| `JELLYFIN_VERSION` | `12.1` | |

`__HOME__` is replaced by `dirtree.sh` with the absolute path of the home (compose does not expand `$HOME` in `.env` files).

## Wizard JSON files

| File | Origin | Contents | Used by |
|---|---|---|---|
| `jellsrv.json` | staging | `ServerName: EgoFin`, `UICulture: it`, `MetadataCountryCode: IT`, `PreferredMetadataLanguage: it` | `POST /Startup/Configuration` |
| `jellremot.json` | staging | `EnableRemoteAccess: true`, `EnableAutomaticPortMapping: false` | `POST /Startup/RemoteAccess` |
| `immichset.json` | **generated** by dirtree | `email`, `password`, `name` = setup user | `POST /api/auth/admin-sign-up` |
| `jelluser.json` | **generated** by dirtree | `Name`, `Password` = setup user | `POST /Startup/User` |

## Resulting folder layout

```
/srv/egos/
├── pool/                  mergerfs (egos-pool.service)
│   ├── media/{Films,Musics,SerieTv,ROMs,downloads}   ← Jellyfin, Samba [media], qbtt
│   └── immich/upload/                                ← Immich originals
├── local/                 branch on the system disk
└── disks/data1, data2…    one ext4 per data disk

/home/<user>/app/
├── repos/                 docker-compose.yml, .env, wizardall2.sh, *.json
│   └── egos-home/         home.py, docker-proxy.cfg, icons/
├── immich/postgres/       Immich database
├── jellyfin/{config,cache}/
├── qbtt/…                 (egos-extras enable qbtt)
└── pdf/bento/             (egos-extras enable bento)
```
