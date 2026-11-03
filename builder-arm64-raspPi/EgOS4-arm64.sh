#!/bin/bash
# =============================================================================
# EgOS4-arm64.sh — SELF-CONTAINED SCRIPT: no external files required.
# Target: Raspberry Pi 5 (8GB) + NVMe. Debian 13 (trixie) arm64.
# Produces egos-<version>-arm64.img (ALREADY-INSTALLED image, not an ISO/installer):
#   the Pi 5 does not boot ISO/GRUB and d-i does not support the Pi 5.
# EgOS logic (webapp, services, dirtree, samba, wsdd2, stack) IDENTICAL to amd64.
#
# BUILD ENVIRONMENT: WSL2 Debian 13 trixie (x86_64), arm64 emulation via qemu
#   trixie: qemu-user (static binaries) + qemu-user-binfmt (registration);
#   qemu-user-static is only transitional
#   - build directory on the WSL ext4 (e.g. ~/egos-arm64), NEVER /mnt/c:
#     DrvFs/9p does not keep Unix owner/permissions -> corrupted rootfs
#   - systemd enabled in WSL recommended (/etc/wsl.conf: [boot] systemd=true)
#
# USAGE in a throwaway container (any Linux host with docker or podman):
#   builder-arm64-raspPi/build-img.sh [OUT_DIR]   # -> OUT_DIR/egos-<version>-arm64.img + build.log
# The container works in an ext4 loop file and registers qemu-aarch64 binfmt
# only for the duration of the build (see build-in-container.sh).
#
# USAGE (WSL Debian shell):
#   mkdir -p ~/egos-arm64 && cd ~/egos-arm64    # ONLY this script
#   sudo apt-get update
#   sudo apt-get install -y mmdebstrap arch-test qemu-user qemu-user-binfmt \
#       e2fsprogs dosfstools mtools fdisk curl ca-certificates
#   sudo bash EgOS4-arm64.sh 2>&1 | tee build.log
#   KEEP_ROOTFS=1 sudo -E bash EgOS4-arm64.sh   # reuses a rootfs/ built by THIS script version:
#   skips mmdebstrap (~11 min), reapplies the overlay and redoes kernel/DTB and .img
#
# FLASH: WSL cannot access the physical NVMe. From Windows:
#   Raspberry Pi Imager -> "Use custom" -> \\wsl.localhost\<distro>\home\<user>\egos-arm64\egos-4.0.0-arm64.img
#   (NVMe attached via a USB adapter). Alternatively dd from a native Linux system.
#   Pi 5 EEPROM: BOOT_ORDER must include 6 (NVMe) -> `rpi-eeprom-config`
#
# RESULTING FLOW:
#   1st boot -> egos-growroot (grows rootfs) -> first-boot-setup.service
#              -> webapp :80 -> setup-data.json -> user -> REBOOT
#   2nd boot -> time-sync + DNS -> docker-compose-startup.service
#              -> dirtree.sh -> wizardall2.sh              (egocenter.local)
#
# SERVICES: webapp :80 (1st boot only) | Immich :2283 | Jellyfin :8096 + 7358/udp
#          Cockpit :9090 (https, login with the user created in setup) | Samba
#
# NB rebuild: the script recreates rootfs/ and the .img from scratch.
# v2: + net-tools, progress; SSH host keys generated at 1st boot
#     (egos-sshkeys.service), no longer included in the image;
#     egos-storage: lists disks only (no zram), model last,
#     abort if the system disk cannot be determined.
# v4 (4.0.0): reference = production Pi egocenter as of 2026-10-28
#     + versioning: EGOS_VERSION below, /etc/egos-release, banner, .img name;
#       Immich/Jellyfin images pinned to the versions running in prod
#     + Jellyfin binds SerieTv (/Serie, ro) and ROMs (ro), as in prod;
#       dirtree/egos-storage create SerieTv, ROMs, downloads
#     + egos-storage link also points the Samba share to the pool;
#       fstab written atomically and validated (2026-10-24 incident)
#     + optional stacks, NOT started: qbtt, bento (egos-extras)
#     + packages used in prod: git, python3-requests
#     - packages dropped: wireless-tools, ifupdown, dhcpcd-base, dmidecode
#       (prod extras not taken: network-manager, modemmanager, wpasupplicant,
#       ppp, ffmpeg, v4l-utils, python3-pip, zip)
#     ~ Docker key fingerprint-checked; Docker repo kept in the
#       final system so docker-ce receives security updates
# v4.1.0: Tailscale and the Caddy extra removed from the image
#     + Cockpit page "Storage pool" (/usr/share/cockpit/egos-storage) driving
#       egos-storage, which gains a non-interactive mode (--json, --disk,
#       --branch, --confirm, --yes) and `job` (runs as a systemd unit)
#     ~ egos-storage: hot add/remove via user.mergerfs.branches (srcmounts is
#       read-only in Debian 13's mergerfs); add fails loudly if the disk
#       could not join the pool; storage-* aliases also in ~/.bashrc
# v4.3.0: egos-home in the base stack: home page on :8000 with one card per
#   container (read from Docker through a socket proxy limited to the
#   container list), Cockpit card, egos.home.* labels
# v4.2.3: qbt-sort warning file in English ("POTENTIALLY HARMFUL", was Italian)
# v4.2.2: wizardall2.sh can be re-run: it skips the Jellyfin Startup wizard
#   once StartupWizardCompleted is true (the Startup API answers 401 then, and
#   the old wait for a 200 never ended when deploy-compose retried at boot)
# v4.2.1: automatic reattach when a missing pool disk is plugged back in
#   (udev rule -> egos-reattach.service, Jellyfin restarted); storage changes
#   serialised by a lock; disk-missing warning in /etc/motd = Cockpit Overview
#   banner + SSH login (and on the Storage pool page, as before)
# v4.2.0: the pool exists from the 1st boot (no more storage-link)
#     + egos-pool.service: mergerfs over /srv/egos/local (system disk) + the data
#       disks; local takes new files only while no data disk exists (then =NC)
#     + the stack (.env, Samba) points to /srv/egos/pool from the start
#     + disk missing at boot: wait 60s, then pool "degraded" with the disks
#       present; Jellyfin held stopped (egos-pool-guard) until reattach
#     + egos-storage reattach / drain; empty mount points made immutable
#     ~ fstab pool line dropped (migrated on the first start of egos-pool)
# =============================================================================
set -e

W="$(cd "$(dirname "$0")" && pwd)"
ROOT="$W/rootfs"
OVL="$W/overlay"
KEYS="$W/keys"
# --- versioning: bump EGOS_VERSION on every change that ends up in the image ---
EGOS_VERSION="4.3.0"
IMMICH_VERSION="v3.2.2"        # ghcr.io/immich-app/immich-server tag (prod 2026-10-28)
JELLYFIN_VERSION="12.1"        # jellyfin/jellyfin tag (prod 2026-10-28)
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IMG="$W/egos-${EGOS_VERSION}-arm64.img"
LABELID=45474f53            # "EGOS": PARTUUID=45474f53-01 (boot) / -02 (root)
BOOT_MB=512
KEEP_ROOTFS="${KEEP_ROOTFS:-0}"   # 1 = reuse existing rootfs/ (skips sec. 12)

# --- WSL environment prerequisites ---
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo"; exit 1; }
FST=$(stat -f -c %T "$W")
case "$FST" in
    ext2/ext3) ;;
    *) echo "ERROR: $W is on '$FST'. Use a directory on the WSL ext4 (not /mnt/c)"; exit 1 ;;
esac

# --- required commands (command:package) ---
MISSING=""
for c in mmdebstrap:mmdebstrap arch-test:arch-test mke2fs:e2fsprogs \
         mkfs.vfat:dosfstools mcopy:mtools sfdisk:fdisk curl:curl gpg:gnupg; do
    command -v "${c%%:*}" >/dev/null || MISSING="$MISSING ${c#*:}"
done
if [ -n "$MISSING" ]; then
    echo "ERROR: missing commands. Run:"
    echo "  apt-get update && apt-get install -y$MISSING ca-certificates qemu-user qemu-user-binfmt"
    exit 1
fi

[ "$KEEP_ROOTFS" = 1 ] || rm -rf "$ROOT"
rm -rf "$OVL" "$W/boot.part" "$W/root.part" "$W/firmware.tmp" "$IMG"
echo "EgOS $EGOS_VERSION arm64 - build $BUILD_DATE"
mkdir -p "$OVL" "$KEYS"

# -----------------------------------------------------------------------------
# 0. Check aarch64 emulation (build on an x86 host)
# -----------------------------------------------------------------------------
if [ "$(uname -m)" != "aarch64" ]; then
    [ -e /proc/sys/fs/binfmt_misc/status ] \
        || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
    if ! arch-test arm64 >/dev/null 2>&1; then
        # WSL with systemd: service; WSL without systemd: run the binary by hand
        # (reads the rules installed by qemu-user-binfmt in /usr/lib/binfmt.d)
        systemctl restart systemd-binfmt 2>/dev/null \
            || /usr/lib/systemd/systemd-binfmt 2>/dev/null || true
    fi
    if ! arch-test arm64 >/dev/null 2>&1; then
        echo "ERROR 0: arm64 emulation missing."
        echo "  ls /proc/sys/fs/binfmt_misc/ :"; ls /proc/sys/fs/binfmt_misc/
        echo "  binfmt.d rules:"; ls /usr/lib/binfmt.d/ 2>/dev/null
        echo "  check: apt-get install qemu-user qemu-user-binfmt"; exit 1
    fi
fi
echo "0 ok: arm64 executable"

# -----------------------------------------------------------------------------
# 1. Repo keys: Raspberry Pi (Pi 5 kernel/firmware) + Docker
# -----------------------------------------------------------------------------
# The key served by archive.raspberrypi.com has SHA-1 binding signatures:
# sqv (apt 3.x) rejects them since 2026-02-01 -> "Signing key ... is not bound".
# RPi-Distro re-signed the same key with SHA-512: copy in pi-gen.
RPI_KEY_URL="https://raw.githubusercontent.com/RPi-Distro/pi-gen/676ba8a7476bd5923e5b677473b11ba52b21c6bd/stage0/files/raspberrypi.gpg"
RPI_FPR="CF8A1AF502A2AA2D763BAE7E82B129927FA3303E"

curl -fsSL "$RPI_KEY_URL" -o "$KEYS/raspberrypi.gpg"
gpg --show-keys --with-colons --with-fingerprint "$KEYS/raspberrypi.gpg" \
    | grep -q "^fpr:::::::::$RPI_FPR:" \
    || { echo "ERROR 1: fingerprint $RPI_FPR missing from the downloaded key"; exit 1; }

# Docker: armored key, converted to binary (apt 3.x + signed-by)
DOCKER_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
curl -fsSL https://download.docker.com/linux/debian/gpg -o "$KEYS/docker.asc"
rm -f "$KEYS/docker.gpg"
gpg --dearmor -o "$KEYS/docker.gpg" "$KEYS/docker.asc"
[ -s "$KEYS/docker.gpg" ] || { echo "ERROR 1: docker dearmor failed"; exit 1; }
gpg --show-keys --with-colons --with-fingerprint "$KEYS/docker.gpg" \
    | grep -q "^fpr:::::::::$DOCKER_FPR:" \
    || { echo "ERROR 1: fingerprint $DOCKER_FPR missing from the Docker key"; exit 1; }

# apt may resolve signed-by in the rootfs or on the host: key present in both
mkdir -p /etc/apt/keyrings
cp "$KEYS/raspberrypi.gpg" "$KEYS/docker.gpg" /etc/apt/keyrings/
echo "1 ok: keys verified (RPi $RPI_FPR, Docker $DOCKER_FPR)"

# -----------------------------------------------------------------------------
# 5b. Console: if a monitor is connected, the login prompt shows the mDNS URL
#     and the machine IP (\4 = agetty escape for IPv4). Helps the
#     ethernet case when mDNS is not available on the client.
# -----------------------------------------------------------------------------
mkdir -p "$OVL"/etc

cat > "$OVL"/etc/issue <<ISSUE_EOF
EgOS ${EGOS_VERSION} - Debian GNU/Linux 13 \\n \\l

  Setup / web access: http://egocenter.local    IP: \4

ISSUE_EOF

# -----------------------------------------------------------------------------
# 5b. mDNS: fixed name "setupbox.local" ONLY during the 1st-boot setup,
#     to reach the dashboard by name over Ethernet too while the
#     hostname/credentials are not yet known to the user.
#     When setup ends, setup-webapp.sh comments out host-name= and restarts
#     avahi: from the 2nd boot the mDNS name is the system one (egocenter.local).
# -----------------------------------------------------------------------------
mkdir -p "$OVL"/etc/avahi

cat > "$OVL"/etc/avahi/avahi-daemon.conf <<'AVAHI_EOF'
[server]
host-name=setupbox
use-ipv4=yes
use-ipv6=yes

[publish]
publish-addresses=yes
AVAHI_EOF

# -----------------------------------------------------------------------------
# 6. systemd services
# -----------------------------------------------------------------------------
mkdir -p "$OVL"/etc/systemd/system

cat > "$OVL"/etc/systemd/system/first-boot-setup.service <<'FBS_EOF'
[Unit]
Description=Initial Setup Webapp
After=network.target
Wants=network.target
ConditionPathExists=!/var/lib/setup-complete

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-webapp.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
FBS_EOF

cat > "$OVL"/etc/systemd/system/docker-compose-startup.service <<'DCS_EOF'
[Unit]
Description=Deploy Docker Compose stack after first-boot setup
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service
ConditionPathExists=/var/lib/setup-complete
ConditionPathExists=!/var/lib/docker-compose-done

[Service]
Type=oneshot
# waits up to 120s for DNS; the "-" ignores a timeout (the wizard's set -e decides later)
ExecStartPre=-/usr/bin/timeout 120 /bin/sh -c 'until getent hosts deb.debian.org >/dev/null; do sleep 2; done'
ExecStart=/usr/local/bin/deploy-compose.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
DCS_EOF

# -----------------------------------------------------------------------------
# 7. setup-webapp.sh (1st boot)
#    PATCH vs lcbuild.txt:
#    a) QUOTED heredoc: in your lcbuild the unquoted <<EOF expanded $(...) and
#       $VAR at write time, corrupting the embedded script
#    b) req.4: `systemctl reboot` instead of `shutdown -h now`
# -----------------------------------------------------------------------------
mkdir -p "$OVL"/usr/local/bin

cat > "$OVL"/usr/local/bin/setup-webapp.sh <<'SETUPWEB_EOF'
#!/bin/bash

WIFI=$(find /sys/class/net -maxdepth 1 -name 'wl*' -o -name 'wlan*' | head -1 | xargs basename 2>/dev/null || true)
ETH=$(find /sys/class/net -maxdepth 1 -name 'en*' -o -name 'eth*' | head -1 | xargs basename 2>/dev/null || true)

# --- WiFi AP (only if hardware exists) ---
if [ -n "$WIFI" ] && [ -d "/sys/class/net/$WIFI" ]; then
    ip link set "$WIFI" down 2>/dev/null || true
    ip addr flush dev "$WIFI" 2>/dev/null || true
    ip addr add 192.168.50.1/24 dev "$WIFI"
    ip link set "$WIFI" up

    cat > /etc/hostapd/hostapd.conf <<HEOF
interface=$WIFI
driver=nl80211
ssid=SetupBox
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=setup1234
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
HEOF

    systemctl start hostapd || true

    cat > /etc/dnsmasq.d/setup.conf <<HhEOF
interface=$WIFI
bind-interfaces
dhcp-range=192.168.50.10,192.168.50.50,255.255.255.0,12h
dhcp-option=3,192.168.50.1
dhcp-option=6,192.168.50.1
# captive portal: EVERY name resolves to the box -> Android/Apple/Windows probes
# get the webapp and the OS opens the "Sign in to network" popup by itself
address=/#/192.168.50.1
no-resolv
address=/setupbox.local/192.168.50.1
HhEOF

    systemctl start dnsmasq || true

    iptables -t nat -I PREROUTING -i "$WIFI" -p tcp --dport 80 -j DNAT --to-destination 192.168.50.1:80 2>/dev/null || true
    iptables -t nat -I PREROUTING -i "$WIFI" -p tcp --dport 443 -j DNAT --to-destination 192.168.50.1:80 2>/dev/null || true
fi

# --- Ethernet ---
if [ -n "$ETH" ]; then
    ip link set "$ETH" up 2>/dev/null || true
fi

# --- mDNS ---
cat > /etc/avahi/services/http.service <<hhhEOF
<?xml version="1.0"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">SetupBox</name>
  <service>
    <type>_http._tcp</type>
    <port>80</port>
  </service>
</service-group>
hhhEOF

systemctl restart avahi-daemon || true

# --- Start webapp ---
/usr/local/bin/webapp.py &
WEBAPP_PID=$!

# --- Wait for submission ---
while [ ! -f /var/lib/setup-data.json ]; do
    sleep 2
done

kill $WEBAPP_PID 2>/dev/null || true

# --- Create user from submitted data ---
USER=$(python3 -c "import json; print(json.load(open('/var/lib/setup-data.json'))['user'])")
PASS=$(python3 -c "import json; print(json.load(open('/var/lib/setup-data.json'))['password'])")
EMAIL=$(python3 -c "import json; print(json.load(open('/var/lib/setup-data.json'))['email'])")

useradd -m -s /bin/bash "$USER" || true
echo "$USER:$PASS" | chpasswd
usermod -aG sudo "$USER" 2>/dev/null || usermod -aG wheel "$USER" 2>/dev/null || true
usermod -aG docker "$USER" 2>/dev/null || true

echo "$EMAIL" > "/home/$USER/.email"
chown "$USER:$USER" "/home/$USER/.email"

# --- Clean up the setup environment: it must NOT survive later boots ---
systemctl stop hostapd dnsmasq 2>/dev/null || true
rm -f /etc/dnsmasq.d/setup.conf /etc/hostapd/hostapd.conf /etc/avahi/services/http.service
# drop the temporary mDNS name: from now on avahi uses the hostname (egocenter.local)
sed -i 's/^host-name=.*/#&/' /etc/avahi/avahi-daemon.conf
systemctl restart avahi-daemon || true

# --- Disable self and reboot (req.4) ---
touch /var/lib/setup-complete
systemctl disable first-boot-setup.service
systemctl reboot
SETUPWEB_EOF
chmod +x "$OVL"/usr/local/bin/setup-webapp.sh

# -----------------------------------------------------------------------------
# 8. Python webapp (final message updated: reboot, not shutdown)
# -----------------------------------------------------------------------------
cat > "$OVL"/usr/local/bin/webapp.py <<'WEBAPP_EOF'
#!/usr/bin/env python3
import json
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs

HTML = """<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>System Setup</title>
    <style>
        * { box-sizing: border-box; }
        body { font-family: system-ui, sans-serif; background: #1a1a1a; color: #fff; display: flex; justify-content: center; align-items: center; min-height: 100vh; margin: 0; padding: 1rem; }
        .card { background: #2a2a2a; padding: 2rem; border-radius: 12px; width: 100%; max-width: 400px; }
        h1 { margin: 0 0 1.5rem; font-size: 1.5rem; }
        label { display: block; margin-bottom: 0.25rem; font-size: 0.875rem; color: #aaa; }
        input { width: 100%; padding: 0.75rem; margin-bottom: 1rem; border: 1px solid #444; border-radius: 6px; background: #1a1a1a; color: #fff; }
        button { width: 100%; padding: 0.875rem; background: #0af; border: none; border-radius: 6px; color: #fff; font-weight: 600; cursor: pointer; }
        .info { margin-top: 1rem; font-size: 0.875rem; color: #888; text-align: center; }
    </style>
</head>
<body>
    <div class="card">
        <h1>System Setup</h1>
        <form method="POST" action="/">
            <label>Email</label>
            <input type="email" name="email" required placeholder="you@example.com">
            <label>Username</label>
            <input type="text" name="user" required placeholder="username">
            <label>Password</label>
            <input type="password" name="password" required placeholder="password">
            <button type="submit">Complete Setup</button>
        </form>
        <div class="info">Connect to <strong>SetupBox</strong> WiFi or visit <strong>http://setupbox.local</strong></div>
    </div>
</body>
</html>
"""

class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-type', 'text/html')
        self.end_headers()
        self.wfile.write(HTML.encode('utf-8'))

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        data = parse_qs(self.rfile.read(length).decode())
        result = {
            'email': data.get('email', [''])[0],
            'user': data.get('user', [''])[0],
            'password': data.get('password', [''])[0]
        }
        with open('/var/lib/setup-data.json', 'w') as f:
            json.dump(result, f)
        self.send_response(200)
        self.send_header('Content-type', 'text/html')
        self.end_headers()
        self.wfile.write(b'<html><body style="background:#1a1a1a;color:#fff;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;font-family:sans-serif;"><div style="text-align:center;"><h1>Setup Complete</h1><p>The system will now reboot and deploy the stack.</p></div></body></html>')

httpd = HTTPServer(('0.0.0.0', 80), Handler)
httpd.serve_forever()
WEBAPP_EOF
chmod +x "$OVL"/usr/local/bin/webapp.py

# -----------------------------------------------------------------------------
# 9. deploy-compose.sh (2nd boot) — copied AS IS from the project
# -----------------------------------------------------------------------------
cat > "$OVL"/usr/local/bin/deploy-compose.sh <<'DEPLOY_EOF'
#!/bin/bash
set -e
[ -f /var/lib/setup-data.json ] || { echo "No setup data"; exit 1; }

/usr/local/bin/dirtree.sh
# dirtree execs wizardall2.sh: if the wizard fails, set -e stops here
# and the service retries at the next boot (flag not touched)

touch /var/lib/docker-compose-done
systemctl disable docker-compose-startup.service
DEPLOY_EOF
chmod +x "$OVL"/usr/local/bin/deploy-compose.sh

# -----------------------------------------------------------------------------
# 10. dirtree.sh — PATCHED for requirement 3:
#     immichset.json and jelluser.json are no longer copied from STAGE but
#     GENERATED from /var/lib/setup-data.json (webapp credentials).
#     json.dump handles escaping (more robust than sed on a template).
#     The rest is identical to your dirtree.sh.
# -----------------------------------------------------------------------------
cat > "$OVL"/usr/local/bin/dirtree.sh <<'DIRTREE_EOF'
#!/bin/bash
set -e

STAGE="/usr/local/share/stack"
U=$(python3 -c "import json; print(json.load(open('/var/lib/setup-data.json'))['user'])")
H="/home/$U"

[ -d "$H" ] || { echo "Home of $U not found"; exit 1; }

# media and photos live on the storage pool (egos-pool.service) from the start:
# adding a disk later never moves data. Without the pool, stop: the folders
# would end up under an empty mount point.
POOL=/srv/egos/pool
findmnt -rno TARGET "$POOL" >/dev/null || { echo "Storage pool $POOL not mounted"; exit 1; }

mkdir -p "$H/app/repos"
mkdir -p "$POOL/media/Films"
mkdir -p "$POOL/media/Musics"
mkdir -p "$POOL/media/SerieTv"
mkdir -p "$POOL/media/ROMs"
mkdir -p "$POOL/media/downloads"
mkdir -p "$POOL/immich/upload"
mkdir -p "$H/app/jellyfin/config"
mkdir -p "$H/app/jellyfin/cache"
mkdir -p "$H/app/immich/postgres"
chown -R "$U:$U" "$POOL/media" "$POOL/immich"

# cp (not mv): if the service fails and restarts at the next boot, the sources are still there
cp "$STAGE/docker-compose.yml" "$H/app/repos/"
cp "$STAGE/wizardall2.sh"      "$H/app/repos/"
cp "$STAGE/jellsrv.json"       "$H/app/repos/"
cp "$STAGE/jellremot.json"     "$H/app/repos/"
# -T: on a retry the folder already exists, copy over it (not into it)
cp -rT "$STAGE/egos-home"      "$H/app/repos/egos-home"

# REQ.3: generate the credential json files for the wizardall2.sh POSTs
# from the credentials collected by the webapp at 1st boot
python3 - "$H" <<'PY'
import json, sys
h = sys.argv[1]
d = json.load(open('/var/lib/setup-data.json'))
json.dump({"email": d["email"], "password": d["password"], "name": d["user"]},
          open(h + "/app/repos/immichset.json", "w"))
json.dump({"Name": d["user"], "Password": d["password"]},
          open(h + "/app/repos/jelluser.json", "w"))
PY

# generate .env with absolute paths: compose does NOT expand $HOME inside .env
sed "s|__HOME__|$H|g" "$STAGE/env.template" > "$H/app/repos/.env"

chmod +x "$H/app/repos/wizardall2.sh"
chown -R "$U:$U" "$H/app"

# --- SMB: upload media from any device (\\egocenter.local\media) ---
# SMBCONF heredoc NOT quoted: $H and $U expand at runtime.
# cat > and smbpasswd -a are idempotent when the service retries at the next boot.
PASS=$(python3 -c "import json; print(json.load(open('/var/lib/setup-data.json'))['password'])")

cat > /etc/samba/smb.conf <<SMBCONF
[global]
   server string = EgoCenter
   server min protocol = SMB2
   map to guest = never

[media]
   path = $POOL/media
   valid users = $U
   read only = no
   create mask = 0664
   directory mask = 0775
SMBCONF

printf '%s\n%s\n' "$PASS" "$PASS" | smbpasswd -s -a "$U"

cat > /etc/avahi/services/smb.service <<'SMBAV'
<?xml version="1.0"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">EgoCenter</name>
  <service>
    <type>_smb._tcp</type>
    <port>445</port>
  </service>
</service-group>
SMBAV

systemctl restart smbd avahi-daemon
# wsdd2 has BindsTo on the smbd unit: stopping smbd stops it and BindsTo
# does not propagate the restart. Explicit restart; || true because discovery
# is cosmetic and its failure must not block the stack (set -e).
systemctl restart wsdd2 || true

echo "PATHS CREATED - starting compose wizard"
cd "$H/app/repos"
exec ./wizardall2.sh
DIRTREE_EOF
chmod +x "$OVL"/usr/local/bin/dirtree.sh

# -----------------------------------------------------------------------------
# 11. Staging /usr/local/share/stack (expected by dirtree.sh) — embedded files.
#     NB: immichset.json and jelluser.json are NOT embedded (see point 10):
#     so the default credentials (YOU / CHANGE_ME) do not end up in the ISO.
# -----------------------------------------------------------------------------
mkdir -p "$OVL"/usr/local/share/stack

cat > "$OVL"/usr/local/share/stack/docker-compose.yml <<'COMPOSE_EOF'
#
# egos stack: Immich (photos) + Jellyfin (media)
# Requires Docker Compose v2 (docker-compose-plugin, official Docker repo)
#
# Based on Immich's OFFICIAL docker-compose.yml:
# https://github.com/immich-app/immich/blob/main/docker/docker-compose.yml
#

name: egos

services:

  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}
    volumes:
      - ${UPLOAD_LOCATION}:/data
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    ports:
      - '2283:2283'
    depends_on:
      - redis
      - database
    restart: always
    healthcheck:
      disable: false

  immich-machine-learning:
    container_name: immich_machine_learning
    # For ML hardware acceleration: append -[armnn, cuda, rocm, openvino, rknn]
    # to the image tag, e.g. ${IMMICH_VERSION:-release}-cuda
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}
    volumes:
      - model-cache:/cache
    env_file:
      - .env
    restart: always
    healthcheck:
      disable: false

  redis:
    container_name: immich_redis
    image: docker.io/valkey/valkey:9@sha256:8436e10bc65c94886a91d4415b6a6dfa9cb5a306fb3b996e5bb67cd2b4854193
    healthcheck:
      test: redis-cli ping || exit 1
    restart: always

  database:
    container_name: immich_postgres
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: '--data-checksums'
    volumes:
      # WARNING (Immich docs): path on a local POSIX filesystem (ext4/zfs/xfs/btrfs),
      # NEVER on an NFS/SMB network share.
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    shm_size: 128mb
    restart: always
    healthcheck:
      disable: false

  jellyfin:
    image: jellyfin/jellyfin:${JELLYFIN_VERSION:-latest}
    container_name: jellyfin
    ports:
      - 8096:8096/tcp
      - 7358:7358/udp
    volumes:
      - ${JELLYFIN_CONFIG_LOCATION}:/config
      - ${JELLYFIN_CACHE_LOCATION}:/cache
      # paths consistent with the dir tree created by dirtree.sh
      - type: bind
        source: ${JELLYFIN_MEDIA_LOCATION}/Films
        target: /Films
      - type: bind
        source: ${JELLYFIN_MEDIA_LOCATION}/Musics
        target: /Musics
      - type: bind
        source: ${JELLYFIN_MEDIA_LOCATION}/SerieTv
        target: /Serie
        read_only: true
      - type: bind
        source: ${JELLYFIN_MEDIA_LOCATION}/ROMs
        target: /ROMs
        read_only: true
      # pool gate: /run/egos/pool-ok exists only while every pool disk is present
      # (egos-pool.service). create_host_path: false = docker must NOT create it
      # (compose would otherwise pass it as a legacy bind, which docker creates):
      # with a disk missing Jellyfin cannot start, not even docker's own restart
      # at boot, so its library scan never sees missing titles
      - type: bind
        source: /run/egos/pool-ok
        target: /egos-pool-ok
        read_only: true
        bind:
          create_host_path: false
    restart: 'unless-stopped'
    environment:
      - JELLYFIN_PublishedServerUrl=http://localhost:8096
    extra_hosts:
      - 'host.docker.internal:host-gateway'

  # EgOS home page (http://<box>:8000): one card per container, read from Docker
  # through docker-proxy, which allows ONLY GET /containers/json (docker-proxy.cfg:
  # no inspect = no environment variables, no logs, no POST)
  docker-proxy:
    container_name: egos-home-docker-proxy
    image: docker.io/tecnativa/docker-socket-proxy:0.3.0@sha256:9e4b9e7517a6b660f2cc903a19b257b1852d5b3344794e3ea334ff00ae677ac2
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./egos-home/docker-proxy.cfg:/usr/local/etc/haproxy/haproxy.cfg.template:ro
    ports:
      - '127.0.0.1:23750:2375'
    # not read_only: the image writes its haproxy.cfg next to the template at start
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    labels:
      - egos.home.enable=false
    restart: unless-stopped

  egos-home:
    container_name: egos-home
    image: docker.io/library/python:3.13-alpine@sha256:7984cf56ceaddebe4fefeb75d64000b9f45d8b77b11a09b24524da6cdc3af0c8
    # host network: the port probes on 127.0.0.1 see the system's ports
    network_mode: host
    user: '1000:1000'
    read_only: true
    environment:
      - PORT=8000
      - FALLBACK_HOST=egocenter.local
      - DOCKER_API=http://127.0.0.1:23750
    volumes:
      - ./egos-home/home.py:/app/home.py:ro
      - ./egos-home/icons:/app/icons:ro
    command: ['python', '-u', '/app/home.py']
    depends_on:
      - docker-proxy
    labels:
      - egos.home.enable=false
    healthcheck:
      test: ['CMD', 'python', '-c', "import urllib.request as u; u.urlopen('http://127.0.0.1:8000/health', timeout=3)"]
      interval: 60s
      timeout: 5s
      retries: 3
    restart: unless-stopped

volumes:
  model-cache:
COMPOSE_EOF

cat > "$OVL"/usr/local/share/stack/wizardall2.sh <<'WIZARD_EOF'
#!/bin/bash
# mentality 0 errors
set -e
cd "$(dirname "$0")"   # the curl -d @file.json calls use relative paths

echo "Starting compose"
docker compose -f docker-compose.yml up -d

echo "Waiting for Jellyfin to be ready (/health)..."
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8096/health)" = "200" ]; do
  echo -n "."; sleep 1
done
echo

echo "Waiting for Immich to be ready (/api/server/ping)..."
until curl -fsS -m 2 http://localhost:2283/api/server/ping 2>/dev/null | grep -q pong; do
  echo -n "."; sleep 1
done
echo
echo "Server up"

echo "IMMICH USERSET"
curl -fsS -X POST "http://localhost:2283/api/auth/admin-sign-up" \
     -H "Content-Type: application/json" \
     -d @immichset.json \
  || echo "(admin-sign-up failed: admin probably already created in a previous run, continuing)"
echo
echo "ok IMMICH"

# the Startup API answers 401 once the wizard is complete: on a re-run
# (deploy-compose retries at every boot until this script succeeds) waiting
# for a 200 there would never end, so ask Jellyfin whether it is done
until INFO=$(curl -fsS http://localhost:8096/System/Info/Public); do
  echo -n "."; sleep 1
done
if printf '%s' "$INFO" | grep -q '"StartupWizardCompleted":true'; then
echo "Jellyfin Startup wizard already completed in a previous run, skipping it"
else
echo "Waiting for the Jellyfin Startup wizard to be reachable..."
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8096/Startup/Configuration)" = "200" ]; do
  echo -n "."; sleep 1
done
echo

echo "JELL SRVSET - server name, country and language"
curl -fsS -X POST "http://localhost:8096/Startup/Configuration" \
     -H "Content-Type: application/json" \
     -d @jellsrv.json

# GET on the user wizard is required before the POST
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8096/Startup/User)" = "200" ]; do
  echo -n "."; sleep 1
done
echo
echo "JELL USERSET - admin user and password"
curl -fsS -X POST "http://localhost:8096/Startup/User" \
     -H "Content-Type: application/json" \
     -d @jelluser.json

echo
echo "JELL ACCESSET"
curl -fsS -X POST "http://localhost:8096/Startup/RemoteAccess" \
     -H "Content-Type: application/json" \
     -d @jellremot.json

echo
echo "--- Complete ---"
curl -fsS -X POST "http://localhost:8096/Startup/Complete"
fi

echo "--- Verify ---"
curl -s "http://localhost:8096/System/Info/Public"
echo
echo "ALL OK"
WIZARD_EOF
chmod +x "$OVL"/usr/local/share/stack/wizardall2.sh

cat > "$OVL"/usr/local/share/stack/jellsrv.json <<'JELLSRV_EOF'
{
  "ServerName":"EgoFin",
  "UICulture":"it",
  "MetadataCountryCode":"IT",
  "PreferredMetadataLanguage":"it"
}
JELLSRV_EOF

cat > "$OVL"/usr/local/share/stack/jellremot.json <<'JELLREMOT_EOF'
{
  "EnableRemoteAccess":true,
  "EnableAutomaticPortMapping":false
}
JELLREMOT_EOF

# --- egos-home (4.3): home page with one card per container, http://<box>:8000 ---
#     home.py reads the container list through docker-proxy (tecnativa/docker-socket-proxy
#     with docker-proxy.cfg: ONLY GET /containers/json and /_ping are allowed, so no
#     container environment variables or logs). Copied to ~/app/repos/egos-home by dirtree.sh.
mkdir -p "$OVL"/usr/local/share/stack/egos-home/icons
cat > "$OVL"/usr/local/share/stack/egos-home/home.py <<'EGOSHOME_PY_EOF'
#!/usr/bin/env python3
"""EgOS home: pagina con i servizi del box.

Le schede vengono dai container Docker (letti tramite un docker-socket-proxy
in sola lettura) più una piccola lista fissa per i servizi che non sono
container (Cockpit). Una scheda per container: la porta è quella indicata
dalla label egos.home.port oppure la prima porta pubblicata che risponde come
pagina web (HTTP o HTTPS). Database, BitTorrent ecc. non rispondono in HTTP e
quindi non compaiono.

Label facoltative sui container (tutte egos.home.*):
  enable=false   nasconde il container
  name, desc     nome e descrizione della scheda
  port, scheme   porta e schema (http/https) da usare
  path           percorso (predefinito /)
  url            link completo al posto di host:porta (es. un dominio pubblico)
  icon           nome del file in icons/ senza .svg
  order          ordinamento (numero, predefinito 50)

Gira con network_mode: host, quindi prova le stesse porte del sistema.
Solo libreria standard.
"""
import html
import json
import os
import re
import socket
import ssl
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PORT = int(os.getenv("PORT", "8000"))
ICONS = Path(__file__).with_name("icons")
FALLBACK_HOST = os.getenv("FALLBACK_HOST", "egocenter.local")
DOCKER_API = os.getenv("DOCKER_API", "http://127.0.0.1:23750").rstrip("/")
PROBE_TTL = 600          # secondi: quanto vale il risultato della prova di una porta
LABEL = "egos.home."

# servizi che non sono container: id, nome, descrizione, porta, schema, percorso
STATIC = [
    ("cockpit", "Cockpit", "Amministrazione", 9090, "https", "/"),
]

# valori predefiniti per le immagini note (si cercano nel nome dell'immagine):
# chiave, id/icona, nome, descrizione, ordine
KNOWN = [
    ("immich-server",   "immich",          "Immich",          "Foto e video",         10),
    ("jellyfin",        "jellyfin",        "Jellyfin",        "Film, serie e musica", 20),
    ("qbittorrent",     "qbittorrent",     "qBittorrent",     "Download torrent",     40),
    ("torrent-web",     "torrent-web",     "Ricerca torrent", "Cerca e scarica",      41),
    ("bentopdf",        "bentopdf",        "BentoPDF",        "Strumenti PDF",        50),
    ("multi-scrobbler", "multi-scrobbler", "Multi-scrobbler", "Scrobbling musica",    60),
]

HOST_RE = re.compile(r"^(\[[0-9a-fA-F:.]+\]|[A-Za-z0-9.-]+)(:\d+)?$")
ID_RE = re.compile(r"[^a-z0-9-]+")

_probe_cache = {}        # porta -> (schema o None, istante)
_known_ports = {}        # nome container -> (porta, schema) visti quando era acceso
_lock = threading.Lock()


# --- prove di rete -----------------------------------------------------------
def is_open(port, timeout=0.4):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout):
            return True
    except OSError:
        return False


def _speaks_http(port, tls, timeout=1.0):
    req = b"HEAD / HTTP/1.0\r\nHost: localhost\r\n\r\n"
    try:
        with socket.create_connection(("127.0.0.1", port), timeout) as raw:
            raw.settimeout(timeout)
            if tls:
                ctx = ssl.create_default_context()
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
                with ctx.wrap_socket(raw, server_hostname="localhost") as s:
                    s.sendall(req)
                    return s.recv(5) == b"HTTP/"
            raw.sendall(req)
            return raw.recv(5) == b"HTTP/"
    except (OSError, ssl.SSLError):
        return False


def web_scheme(port):
    """'http', 'https' o None se la porta non risponde come pagina web."""
    now = time.monotonic()
    with _lock:
        hit = _probe_cache.get(port)
    if hit and now - hit[1] < PROBE_TTL:
        return hit[0]
    scheme = "http" if _speaks_http(port, False) else ("https" if _speaks_http(port, True) else None)
    with _lock:
        _probe_cache[port] = (scheme, now)
    return scheme


# --- Docker ------------------------------------------------------------------
def docker_containers():
    """Elenco dei container dal proxy; None se il proxy non risponde."""
    try:
        with urllib.request.urlopen(DOCKER_API + "/containers/json?all=1", timeout=3) as r:
            return json.load(r)
    except (OSError, ValueError):
        return None


def known_for(image):
    img = image.lower()
    for key, sid, name, desc, order in KNOWN:
        if key in img:
            return sid, name, desc, order
    return None


def card_from_container(c):
    labels = c.get("Labels") or {}
    lab = {k[len(LABEL):]: v for k, v in labels.items() if k.startswith(LABEL)}
    if lab.get("enable", "").lower() in ("false", "0", "no"):
        return None
    cname = (c.get("Names") or ["/?"])[0].lstrip("/")
    running = c.get("State") == "running"
    status = c.get("Status", "")
    known = known_for(c.get("Image", ""))

    port = scheme = None
    if lab.get("port", "").isdigit():
        port = int(lab["port"])
        scheme = lab.get("scheme") or (web_scheme(port) if running else None) or "http"
    elif running:
        ports = sorted({p["PublicPort"] for p in c.get("Ports") or []
                        if p.get("Type") == "tcp" and p.get("PublicPort")
                        and p.get("IP", "0.0.0.0") in ("0.0.0.0", "::", "")})
        for p in ports:
            s = web_scheme(p)
            if s:
                port, scheme = p, lab.get("scheme") or s
                break
    if port is None and lab.get("url") is None:
        # un container fermo non pubblica porte: si usa quella vista quando era acceso
        with _lock:
            seen = _known_ports.get(cname)
        if not seen:
            return None
        port, scheme = seen
    elif port is not None and running:
        with _lock:
            _known_ports[cname] = (port, scheme)

    sid = ID_RE.sub("-", (lab.get("icon") or (known[0] if known else cname)).lower()).strip("-")
    order = lab.get("order", "")
    return {
        "id": "c-" + ID_RE.sub("-", cname.lower()),
        "icon": sid,
        "name": lab.get("name") or (known[1] if known else cname),
        "desc": lab.get("desc") or (lab["url"].split("://", 1)[-1].split("/", 1)[0] if lab.get("url")
                                    else known[2] if known else c.get("Image", "").split("@")[0]),
        "order": int(order) if order.lstrip("-").isdigit() else (known[3] if known else 50),
        "port": port,
        "scheme": scheme or "http",
        "path": lab.get("path") or "/",
        "url": lab.get("url"),
        "state": "on" if running and "(unhealthy)" not in status else ("warn" if running else "off"),
    }


def services():
    """(schede, docker_ok): container + servizi fissi, ordinati."""
    cs = docker_containers()
    cards = []
    if cs is not None:
        with ThreadPoolExecutor(8) as ex:
            cards = [x for x in ex.map(card_from_container, cs) if x]
    with ThreadPoolExecutor(len(STATIC)) as ex:
        opens = list(ex.map(lambda s: is_open(s[3]), STATIC))
    for (sid, name, desc, port, scheme, path), up in zip(STATIC, opens):
        cards.append({"id": "s-" + sid, "icon": sid, "name": name, "desc": desc, "order": 90,
                      "port": port, "scheme": scheme, "path": path, "url": None,
                      "state": "on" if up else "off"})
    cards.sort(key=lambda x: (x["order"], x["name"].lower()))
    return cards, cs is not None


# --- pagina ------------------------------------------------------------------
def request_host(header):
    m = HOST_RE.match(header or "")
    return m.group(1) if m else FALLBACK_HOST


def icon_html(card):
    if (ICONS / (card["icon"] + ".svg")).is_file():
        return f'<img src="/icons/{card["icon"]}.svg" alt="" width="40" height="40">'
    # nessuna icona: iniziale su un colore ricavato dal nome
    hue = sum(map(ord, card["name"])) * 37 % 360
    letter = html.escape(card["name"][:1].upper() or "?")
    return (f'<svg class="auto" viewBox="0 0 40 40" width="40" height="40" aria-hidden="true">'
            f'<rect width="40" height="40" rx="9" fill="hsl({hue} 55% 45%)"/>'
            f'<text x="20" y="27" text-anchor="middle" font-size="20" font-weight="600" '
            f'fill="#fff" font-family="system-ui, sans-serif">{letter}</text></svg>')


def render(host):
    cards, docker_ok = services()
    up = sum(c["state"] != "off" for c in cards)
    out = []
    for c in cards:
        url = c["url"] or f'{c["scheme"]}://{host}:{c["port"]}{c["path"]}'
        tail = "↗" if c["url"] else f':{c["port"]}'
        off = c["state"] == "off"
        out.append(
            f'<a class="card {c["state"]}" id="{c["id"]}" href="{html.escape(url)}"'
            f'{" aria-disabled=\"true\" tabindex=\"-1\"" if off else ""}>'
            f'{icon_html(c)}'
            f'<span class="txt"><span class="name">{html.escape(c["name"])}</span>'
            f'<span class="desc">{html.escape(c["desc"])}</span></span>'
            f'<span class="port">{tail}</span></a>'
        )
    warn = "" if docker_ok else '<p class="banner">Docker non raggiungibile: mostro solo i servizi fissi.</p>'
    return PAGE.format(host=html.escape(host), up=up, total=len(cards), cards="\n".join(out),
                       banner=warn, ids=html.escape(json.dumps(sorted(c["id"] for c in cards))))


def api_status():
    cards, docker_ok = services()
    return {"docker": docker_ok, "services": {c["id"]: c["state"] for c in cards}}


class Handler(BaseHTTPRequestHandler):
    server_version = "egos-home"

    def send(self, code, ctype, body, cache="no-store"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            body = render(request_host(self.headers.get("Host"))).encode()
            self.send(200, "text/html; charset=utf-8", body)
        elif path == "/api/status":
            self.send(200, "application/json", json.dumps(api_status()).encode())
        elif path.startswith("/icons/") and re.fullmatch(r"/icons/[a-z0-9-]+\.svg", path):
            f = ICONS / path[len("/icons/"):]
            if f.is_file():
                self.send(200, "image/svg+xml", f.read_bytes(), "max-age=86400")
            else:
                self.send(404, "text/plain", b"not found")
        elif path == "/health":
            self.send(200, "text/plain", b"ok")
        else:
            self.send(404, "text/plain", b"not found")

    def log_message(self, fmt, *args):
        pass


PAGE = """<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>EgOS Home</title>
<style>
:root {{
  --bg: #f4f5f7; --card: #ffffff; --border: #dfe2e7; --text: #1b1f24;
  --muted: #5f6b7a; --accent: #2f6fd6; --ok: #1f9d55; --warn: #b7791f; --shadow: 0 1px 2px rgba(0,0,0,.06);
}}
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    --bg: #14171c; --card: #1d2229; --border: #2c333d; --text: #e6e9ee;
    --muted: #96a1b0; --accent: #6ea2ff; --ok: #3ccf7e; --warn: #e0a84a; --shadow: none;
  }}
}}
:root[data-theme="dark"] {{
  --bg: #14171c; --card: #1d2229; --border: #2c333d; --text: #e6e9ee;
  --muted: #96a1b0; --accent: #6ea2ff; --ok: #3ccf7e; --warn: #e0a84a; --shadow: none;
}}
* {{ box-sizing: border-box; }}
body {{
  margin: 0; background: var(--bg); color: var(--text);
  font: 15px/1.4 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
}}
main {{ max-width: 960px; margin: 0 auto; padding: 28px 16px; }}
header {{ display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin-bottom: 18px; }}
h1 {{ font-size: 20px; margin: 0; font-weight: 650; }}
h1 small {{ color: var(--muted); font-weight: 400; font-size: 14px; margin-left: 6px; }}
.count {{ color: var(--muted); font-size: 13px; white-space: nowrap; }}
.count b {{ color: var(--ok); }}
.banner {{ margin: 0 0 14px; padding: 8px 12px; border: 1px solid var(--warn); border-radius: 8px; color: var(--warn); font-size: 13px; }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 10px; }}
.card {{
  display: flex; align-items: center; gap: 12px; padding: 10px 12px;
  background: var(--card); border: 1px solid var(--border); border-radius: 10px;
  color: inherit; text-decoration: none; box-shadow: var(--shadow);
  transition: border-color .15s, transform .15s, opacity .2s, filter .2s;
}}
.card:hover {{ border-color: var(--accent); transform: translateY(-1px); }}
.card:focus-visible {{ outline: 2px solid var(--accent); outline-offset: 2px; }}
.card img, .card svg.auto {{ flex: none; width: 40px; height: 40px; object-fit: contain; }}
.txt {{ display: flex; flex-direction: column; min-width: 0; flex: 1; }}
.name {{ font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
.desc {{ color: var(--muted); font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
.port {{ color: var(--muted); font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; white-space: nowrap; }}
.card.off {{ opacity: .35; filter: grayscale(1); pointer-events: none; box-shadow: none; }}
.card.off .port::after {{ content: " · spento"; font-family: system-ui, sans-serif; }}
.card.warn {{ border-color: var(--warn); }}
.card.warn .port::after {{ content: " · non sano"; color: var(--warn); font-family: system-ui, sans-serif; }}
@media (max-width: 460px) {{
  .grid {{ grid-template-columns: 1fr 1fr; gap: 8px; }}
  .card {{ flex-direction: column; text-align: center; gap: 6px; padding: 12px 8px; }}
  .txt {{ align-items: center; width: 100%; }}
  .card.off .port::after, .card.warn .port::after {{ content: ""; }}
}}
</style>
</head>
<body>
<main>
  <header>
    <h1>EgOS<small>{host}</small></h1>
    <span class="count"><b id="up">{up}</b> attivi su {total}</span>
  </header>
  {banner}
  <nav class="grid" data-ids="{ids}">
{cards}
  </nav>
</main>
<script>
const grid = document.querySelector(".grid");
const ids = JSON.parse(grid.dataset.ids);
setInterval(async () => {{
  try {{
    const st = await (await fetch("/api/status", {{cache: "no-store"}})).json();
    const now = Object.keys(st.services).sort();
    // container comparsi o spariti, o Docker tornato/perso: si ricarica la pagina
    if (JSON.stringify(now) !== JSON.stringify(ids) || (!st.docker) !== !!document.querySelector(".banner")) {{
      location.reload(); return;
    }}
    let up = 0;
    for (const [id, state] of Object.entries(st.services)) {{
      const el = document.getElementById(id);
      if (!el) continue;
      if (state !== "off") up++;
      el.classList.remove("on", "off", "warn");
      el.classList.add(state);
      if (state === "off") {{ el.setAttribute("aria-disabled", "true"); el.setAttribute("tabindex", "-1"); }}
      else {{ el.removeAttribute("aria-disabled"); el.removeAttribute("tabindex"); }}
    }}
    document.getElementById("up").textContent = up;
  }} catch (e) {{}}
}}, 15000);
</script>
</body>
</html>
"""

if __name__ == "__main__":
    print(f"egos-home in ascolto su :{PORT}, Docker via {DOCKER_API}", flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
EGOSHOME_PY_EOF

cat > "$OVL"/usr/local/share/stack/egos-home/docker-proxy.cfg <<'EGOSHOME_CFG_EOF'
# haproxy template for tecnativa/docker-socket-proxy (mounted read-only over the
# image's own template). EgOS allows ONLY the container list and ping: the
# image's CONTAINERS=1 would also allow /containers/<id>/json (environment
# variables, i.e. passwords) and /containers/<id>/logs.
global
    log stdout format raw daemon "${LOG_LEVEL}"
    pidfile /run/haproxy.pid
    maxconn 100

defaults
    mode http
    log global
    option httplog
    option dontlognull
    option http-server-close
    timeout http-request 10s
    timeout connect 10s
    timeout client 1m
    timeout server 1m
    errorfile 403 /usr/local/etc/haproxy/errors/403.http

backend dockerbackend
    server dockersocket $SOCKET_PATH

frontend dockerfrontend
    bind ${BIND_CONFIG}
    http-request allow if METH_GET { path,url_dec -m reg -i ^(/v[0-9.]+)?/containers/json$ }
    http-request allow if METH_GET { path,url_dec -m reg -i ^(/v[0-9.]+)?/_ping$ }
    http-request deny
    default_backend dockerbackend
EGOSHOME_CFG_EOF

cat > "$OVL"/usr/local/share/stack/egos-home/icons/bentopdf.svg <<'EGOSHOME_SVG_EOF'
<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 85.18 165.94">
<path d="M56.7848 80.9116L0 25.6211L24.8434 1.43151C26.8037 -0.47717 29.9814 -0.47717 31.9414 1.43151L85.177 53.2662L56.7848 80.9116Z" fill="#A5B4FC"/>
<path d="M-1.30805e-05 80.7335L21.2939 101.467L42.5878 80.7335L21.2939 60L-1.30805e-05 80.7335Z" fill="#E0E7FF"/>
<path d="M56.7848 83L81.6279 107.19C83.5881 109.098 83.5881 112.192 81.6279 114.101L28.3925 165.936L0 138.29L56.7848 83Z" fill="#6366F1"/>
</svg>
EGOSHOME_SVG_EOF
cat > "$OVL"/usr/local/share/stack/egos-home/icons/cockpit.svg <<'EGOSHOME_SVG_EOF'
<svg xmlns="http://www.w3.org/2000/svg" xml:space="preserve" viewBox="0 0 512 512"><path d="M256 0C114.8 0 0 114.8 0 256s114.8 256 256 256 256-114.8 256-256S397.2 0 256 0m0 38.4c120.1-.2 217.5 97 217.7 217v.6c.1 120.1-97.1 217.5-217.2 217.6h-.6c-120 .2-217.4-97-217.6-217v-.6c-.2-120 97-217.4 217-217.6zm85.7 112.7c-10.5-.4-26.3 7.9-40.5 22l-30.7 30.5-91.9-30.9-18 18.5 69.4 52.7-15.5 15.4c-5.1 5.1-9.7 10.7-13.6 16.8l-41.8-3.1-10.2 10.3 41.5 30.8 30.4 41.5 10.2-10.2-3.1-42.2c5.2-3.4 10.6-7.7 15.8-12.9l16.3-16.2 53.2 69.8 18.5-17.9-31-92.4 29.7-29.5c19-18.9 27.7-41 19.6-49.5-2.2-2.3-5.2-3.5-8.3-3.5"/></svg>
EGOSHOME_SVG_EOF
cat > "$OVL"/usr/local/share/stack/egos-home/icons/immich.svg <<'EGOSHOME_SVG_EOF'
<svg xmlns="http://www.w3.org/2000/svg" xml:space="preserve" viewBox="0 0 512 512"><path d="M238.8 155.5c33.5 29.7 60.5 61.5 77.9 91.5 29.9-53.4 49.8-116.9 50.1-157.3v-.8c0-59.8-59.7-83.1-111.1-83.1S144.6 29 144.6 88.8V92c28.7 12.8 62.6 35.6 94.2 63.5" style="fill:#fa2921"/><path d="M55.9 318.6c21-23.3 53.1-48.6 89.4-69.9 38.6-22.7 77.2-38.6 111.1-45.8-41.6-44.9-95.8-83.5-134.1-96.2-.3-.1-.5-.2-.7-.2-57-18.7-97.6 30.9-113.5 79.8S-4.1 299.1 52.8 317.6c.8.2 1.8.6 3.1 1" style="fill:#ed79b5"/><path d="M503.9 185.4C488 136.6 447.4 87 390.5 105.5c-.8.3-1.8.6-3.1 1-3.3 31.2-14.4 70.5-31.2 109.1-17.9 41.1-39.8 76.6-62.9 102.4 60 11.9 126.5 11.3 165.1-1 .3-.1.5-.2.7-.2 57-18.6 60.6-82.5 44.8-131.4" style="fill:#ffb400"/><path d="M205 366.3c-9.7-43.7-12.8-85.3-9.3-119.8-55.5 25.7-109 65.3-133 97.8-.2.2-.3.4-.5.6-35.2 48.4-.6 102.3 41 132.5s103.5 46.4 138.7-1.9c.5-.7 1.1-1.5 1.9-2.6-15.6-27.1-29.7-65.5-38.8-106.6" style="fill:#1e83f7"/><path d="M448.8 341.9c-30.7 6.5-71.5 8.1-113.4 4-44.6-4.3-85.1-14.2-116.8-28.2 7.2 60.8 28.4 123.8 51.9 156.7.2.2.3.4.5.6 35.2 48.4 97.1 32.2 138.7 1.9 41.6-30.2 76.2-84.1 41-132.5-.5-.6-1.1-1.4-1.9-2.5" style="fill:#18c249"/></svg>
EGOSHOME_SVG_EOF
cat > "$OVL"/usr/local/share/stack/egos-home/icons/jellyfin.svg <<'EGOSHOME_SVG_EOF'
<svg xmlns="http://www.w3.org/2000/svg" xml:space="preserve" viewBox="0 0 512 512"><linearGradient id="a" x1="97.508" x2="522.069" y1="308.135" y2="63.019" gradientTransform="matrix(1 0 0 -1 0 514)" gradientUnits="userSpaceOnUse"><stop offset="0" style="stop-color:#aa5cc3"/><stop offset="1" style="stop-color:#00a4dc"/></linearGradient><path d="M256 196.2c-22.4 0-94.8 131.3-83.8 153.4s156.8 21.9 167.7 0-61.3-153.4-83.9-153.4" style="fill:url(#a)"/><linearGradient id="b" x1="94.193" x2="518.754" y1="302.394" y2="57.278" gradientTransform="matrix(1 0 0 -1 0 514)" gradientUnits="userSpaceOnUse"><stop offset="0" style="stop-color:#aa5cc3"/><stop offset="1" style="stop-color:#00a4dc"/></linearGradient><path d="M256 0C188.3 0-29.8 395.4 3.4 462.2s472.3 66 505.2 0S323.8 0 256 0m165.6 404.3c-21.6 43.2-309.3 43.8-331.1 0S211.7 101.4 256 101.4 443.2 361 421.6 404.3" style="fill:url(#b)"/></svg>
EGOSHOME_SVG_EOF
cat > "$OVL"/usr/local/share/stack/egos-home/icons/multi-scrobbler.svg <<'EGOSHOME_SVG_EOF'
<svg xmlns="http://www.w3.org/2000/svg" xml:space="preserve" id="Layer_1" x="0" y="0" version="1.1" viewBox="0 0 512 512"><style>.st0{fill:#c34a36}</style><path d="M307.8 262c3.5-31.4-21.1-58-51.8-58-18.2 0-34.3 9.4-43.6 23.6h-18.2c9.4-20.4 28.7-35.5 51.8-38.8V80c0-44.2-35.8-80-80-80H20C9 0 0 9 0 20v472c0 11 9 20 20 20h146c44.2 0 80-35.8 80-80V323.3c-23.1-3.4-42.4-18.4-51.8-38.9h18.2c10.4 15.8 29.1 25.7 49.8 23.3 24.4-2.8 42.9-21.5 45.6-45.7M61.2 377.6c0 4.4-3.6 8-8 8s-8-3.6-8-8V134.4c0-4.4 3.6-8 8-8s8 3.6 8 8zm44.5 58.2c0 4.4-3.6 8-8 8s-8-3.6-8-8V76.2c0-4.4 3.6-8 8-8s8 3.6 8 8zM256 277.6c-9.1 0-16.9-5.6-20.1-13.6h-85.7v113.6c0 4.4-3.6 8-8 8s-8-3.6-8-8V134.4c0-4.4 3.6-8 8-8s8 3.6 8 8V248h85.7c3.7-9.3 13.7-15.4 24.7-13.2 8.2 1.7 14.8 8.3 16.5 16.5 3 14-7.6 26.3-21.1 26.3" class="st0"/><path d="M492 0H346c-44.2 0-80 35.8-80 80v108.7c30.2 4.5 54 28.8 57.6 59.3h38.2V134.9c0-4 2.7-7.7 6.6-8.3 5-.8 9.4 3 9.4 7.9v242.7c0 4-2.7 7.7-6.6 8.3-5 .8-9.4-3-9.4-7.9V264h-38.2c-3.6 30.5-27.4 54.8-57.6 59.3V432c0 44.2 35.8 80 80 80h146c11 0 20-9 20-20V20c0-11-9-20-20-20m-69.7 435.8c0 4.4-3.6 8-8 8s-8-3.6-8-8V76.2c0-4.4 3.6-8 8-8s8 3.6 8 8zm44.5-58.2c0 4.4-3.6 8-8 8s-8-3.6-8-8V134.4c0-4.4 3.6-8 8-8s8 3.6 8 8z" class="st0"/></svg>
EGOSHOME_SVG_EOF
cat > "$OVL"/usr/local/share/stack/egos-home/icons/qbittorrent.svg <<'EGOSHOME_SVG_EOF'
<svg xmlns="http://www.w3.org/2000/svg" xml:space="preserve" viewBox="0 0 1024 1024"><linearGradient id="a" x1="-446.298" x2="-445.875" y1="1052.924" y2="1052.156" gradientTransform="matrix(992 0 0 -992 442993 1044565)" gradientUnits="userSpaceOnUse"><stop offset="0" style="stop-color:#72b4f5"/><stop offset="1" style="stop-color:#356ebf"/></linearGradient><circle cx="512" cy="512" r="496" style="fill-rule:evenodd;clip-rule:evenodd;fill:url(#a);stroke:#daefff;stroke-width:32"/><path d="M712.9 332.4c44.4 0 78.9 15.2 103.4 45.7 24.7 30.2 37 73.1 37 128.7 0 55.5-12.4 98.8-37.3 129.6-24.7 30.7-59 46-103.1 46-22 0-42.2-4-60.5-12-18.1-8.2-33.3-20.8-45.7-37.6H603l-10.8 43.5h-36.7V196h51.2v116.6c0 26.1-.8 49.6-2.5 70.4h2.5c23.9-33.7 59.3-50.6 106.2-50.6m-7.4 42.9c-35 0-60.2 10.1-75.6 30.2-15.4 20-23.1 53.7-23.1 101.2s7.9 81.6 23.8 102.1c15.8 20.4 41.2 30.5 76.2 30.5 31.5 0 54.9-11.4 70.4-34.3 15.4-23 23.1-56.1 23.1-99.1q0-66-23.1-98.4c-15.5-21.4-39.4-32.2-71.7-32.2" style="fill-rule:evenodd;clip-rule:evenodd;fill:#fff"/><path d="M317.3 639.5c34.2 0 59-9.2 74.7-27.5 15.6-18.3 24-49.2 25-92.6V508c0-47.3-8-81.4-24.1-102.1-16-20.8-41.5-31.2-76.2-31.2-30 0-53.1 11.7-69.1 35.2-15.8 23.2-23.8 56.2-23.8 98.8s7.8 75.1 23.5 97.5c15.8 22.1 39.1 33.2 70 33.3m-7.7 42.8c-43.6 0-77.7-15.3-102.1-46-24.5-30.7-36.7-73.4-36.7-128.4 0-55.3 12.3-98.5 37-129.6s59-46.6 103.1-46.6q69.45 0 106.8 52.5h2.8l7.4-46.3h40.4v490h-51.2V683.3c0-20.6 1.1-38.1 3.4-52.5h-4c-23.8 34.4-59.4 51.5-106.9 51.5" style="fill-rule:evenodd;clip-rule:evenodd;fill:#c8e8ff"/></svg>
EGOSHOME_SVG_EOF
cat > "$OVL"/usr/local/share/stack/egos-home/icons/torrent-web.svg <<'EGOSHOME_SVG_EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="64" height="64" rx="14" fill="#2f6fd6"/><circle cx="28" cy="28" r="13" fill="none" stroke="#fff" stroke-width="5"/><path d="M38 38l12 12" stroke="#fff" stroke-width="6" stroke-linecap="round"/><path d="M28 21v12m-5-4l5 5 5-5" fill="none" stroke="#fff" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round"/></svg>
EGOSHOME_SVG_EOF

cat > "$OVL"/usr/local/share/stack/env.template <<'ENVTPL_EOF'
# ============================================================
# TEMPLATE: dirtree.sh replaces __HOME__ with the user's real
# home and writes it as .env in ~/app/repos/
# Do not use $HOME here: compose does NOT expand it.
# ============================================================

# ---- General ----
TZ=Europe/Rome

# ---- Immich ----
UPLOAD_LOCATION=/srv/egos/pool/immich/upload
# MUST be on a local POSIX filesystem, not NFS/SMB
DB_DATA_LOCATION=__HOME__/app/immich/postgres
DB_USERNAME=postgres
DB_PASSWORD=password
DB_DATABASE_NAME=immich
IMMICH_VERSION=@IMMICH_VERSION@

# ---- Jellyfin ----
JELLYFIN_CONFIG_LOCATION=__HOME__/app/jellyfin/config
JELLYFIN_CACHE_LOCATION=__HOME__/app/jellyfin/cache
JELLYFIN_MEDIA_LOCATION=/srv/egos/pool/media
JELLYFIN_VERSION=@JELLYFIN_VERSION@
ENVTPL_EOF
sed -i -e "s|@IMMICH_VERSION@|$IMMICH_VERSION|" -e "s|@JELLYFIN_VERSION@|$JELLYFIN_VERSION|" \
    "$OVL"/usr/local/share/stack/env.template

# --- release file: lets you compare a running box with the script that built it ---
cat > "$OVL"/etc/egos-release <<RELEASE_EOF
EGOS_VERSION=$EGOS_VERSION
EGOS_ARCH=arm64
EGOS_BUILD_DATE=$BUILD_DATE
EGOS_BUILD_SCRIPT=EgOS4-arm64.sh
IMMICH_VERSION=$IMMICH_VERSION
JELLYFIN_VERSION=$JELLYFIN_VERSION
RELEASE_EOF

# -----------------------------------------------------------------------------
# 11a. Optional stacks (prod-only services as of 2026-10-28), NOT started.
#      Staged in /usr/local/share/stack/extras/<name>; `egos-extras enable <name>`
#      copies one to the same path it has in prod, creates its .env and starts it.
#      caddy, reactive-resume and nginx-proxy-manager are not included (see reports).
# -----------------------------------------------------------------------------
X="$OVL"/usr/local/share/stack/extras
mkdir -p "$X"/qbtt/scripts "$X"/bento "$OVL"/usr/local/bin

# --- qbtt: qBittorrent-nox + torrent-web (prod version, with music sort) ---
cat > "$X"/qbtt/docker-compose.yml <<'QBTT_COMPOSE_EOF'
services:
  torrent-web:
    build:
      context: .
      dockerfile: dockerfile
    image: torrent-web:latest
    container_name: torrent-web
    restart: unless-stopped
    ports:
      - "${WEB_PORT}:${WEB_PORT}"
    env_file: .env
    depends_on:
      - qbittorrent-nox
    # To reach a qBittorrent installed on the host, .env can use
    # QBIT_URL=http://host.docker.internal:8082
    extra_hosts:
      - "host.docker.internal:host-gateway"

  # ------------------------------------------------------------------
  # qBittorrent-nox (official image).
  # In .env: QBIT_URL=http://qbittorrent-nox:<QBT_WEBUI_PORT>
  # When a torrent finishes it runs /scripts/qbt-sort.py, which moves
  # it to /Films, /Musics or /SerieTv (log: /config/qbt-sort.log).
  # ------------------------------------------------------------------
  qbittorrent-nox:
    image: qbittorrentofficial/qbittorrent-nox:${QBT_VERSION}
    container_name: qbittorrent-nox
    restart: unless-stopped
    environment:
      - PUID=${PUID:-1000}
      - PGID=${PGID:-1000}
      - TZ=${TZ:-UTC}
      - QBT_LEGAL_NOTICE=${QBT_LEGAL_NOTICE}
      - QBT_TORRENTING_PORT=${QBT_TORRENTING_PORT}
      - QBT_WEBUI_PORT=${QBT_WEBUI_PORT}
    ports:
      # bittorrent traffic
      - "${QBT_TORRENTING_PORT}:${QBT_TORRENTING_PORT}/tcp"
      - "${QBT_TORRENTING_PORT}:${QBT_TORRENTING_PORT}/udp"
      # Web UI
      - "${QBT_WEBUI_PORT}:${QBT_WEBUI_PORT}/tcp"
    stop_grace_period: 30m
    tmpfs:
      - /tmp
    volumes:
      - ${QBT_CONFIG_PATH}:/config
      - ./scripts:/scripts:ro
      - ${QBT_DOWNLOADS_PATH}:/downloads
      - ${QBT_FILMS_PATH}:/Films
      - ${QBT_MUSICS_PATH}:/Musics
      - ${QBT_SERIETV_PATH}:/SerieTv
QBTT_COMPOSE_EOF
cat > "$X"/qbtt/dockerfile <<'QBTT_DOCKERFILE_EOF'
FROM python:3.13-slim

ENV PYTHONUNBUFFERED=1 \
    WEB_HOST=0.0.0.0 \
    WEB_PORT=8083

WORKDIR /app
COPY torrent_web.py .

# non-root user
RUN useradd --system --uid 1000 --no-create-home app
USER app

EXPOSE 8083

HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
  CMD python3 -c "import os,socket; socket.create_connection(('127.0.0.1', int(os.environ.get('WEB_PORT','8083'))), 3)"

CMD ["python3", "torrent_web.py"]
QBTT_DOCKERFILE_EOF
cat > "$X"/qbtt/.dockerignore <<'QBTT_DOCKERIGNORE_EOF'
# only the app goes into the image (no .env, qBittorrent data, media or git)
*
!torrent_web.py
!dockerfile
QBTT_DOCKERIGNORE_EOF
cat > "$X"/qbtt/README.md <<'QBTT_README_EOF'
# qbittorrent-nox-easywebapp

A small LAN web page to search torrents through qBittorrent, plus a qBittorrent-nox
container that automatically sorts finished downloads into `Films`, `Musics` and `SerieTv`.

- **torrent-web**: paste one or more searches (one per line), filter the results
  (type, seeders, size, text) and add them to qBittorrent with one click.
  Python standard library only, protected by an optional password.
- **qbittorrent-nox**: official `qbittorrentofficial/qbittorrent-nox` image.
  When a torrent finishes, `scripts/qbt-sort.py` moves it (via the Web API, so seeding
  continues) to:
  - `/Musics/Artist/Album/` if it is mostly audio (Jellyfin layout). Artist and album
    come from the audio tags (MP3, FLAC, Ogg, Opus, M4A; "feat." is ignored), then
    from a `Artist - Album` torrent name, otherwise `Unknown Artist`. An existing album
    folder is not merged: the new one becomes `Album (2)`.

  If a torrent contains executables or scripts (`.exe`, `.bat`, `.scr`, `.ps1`, `.sh`, …,
  also `song.mp3.exe`) it is **not moved**: it stays in `downloads/`, the script logs a
  `WARN` line and leaves a file named `POTENTIALLY HARMFUL` in the torrent's folder,
  listing them.
  - `/SerieTv` if the names look like episodes (`S01E02`, `1x02`, `Season 1`, …)
  - `/Films/Title (Year)/` otherwise

Based on the official qBittorrent-nox Docker image:
[qbittorrent/docker-qbittorrent-nox (main)](https://github.com/qbittorrent/docker-qbittorrent-nox/tree/main)
· qBittorrent itself: [qbittorrent/qBittorrent](https://github.com/qbittorrent/qBittorrent).

## Setup

```sh
cp .env.example .env        # then change passwords and ports
mkdir -p qbittorrent/config downloads media/Films media/Musics media/SerieTv
docker compose up -d --build
```

On the first start qBittorrent prints a temporary Web UI password:

```sh
docker logs qbittorrent-nox
```

Open `http://SERVER-IP:<QBT_WEBUI_PORT>`, log in with `admin` and that password, then in
**Tools → Options**:

1. **Web UI → Authentication**: set the user and password you put in `.env`
   (`QBIT_USER` / `QBIT_PASS`). Tick *Bypass authentication for clients on localhost*
   (the sort script uses it).
2. **Downloads → Run external program → Run on torrent finished**:
   ```
   python3 /scripts/qbt-sort.py "%K"
   ```
3. **Search** tab: install the search plugins you want (the web page uses the enabled ones).

Then open the page at `http://SERVER-IP:<WEB_PORT>`.

## Notes

- The sort log is `qbittorrent/config/qbt-sort.log`. Test without moving anything:
  `docker exec qbittorrent-nox python3 /scripts/qbt-sort.py <hash> --dry-run`
- `PUID`/`PGID` (default 1000) must be able to write the `media/` folders.
- To use a qBittorrent already installed on the host, remove the `qbittorrent-nox`
  service and set `QBIT_URL=http://host.docker.internal:<port>` in `.env`.
QBTT_README_EOF
cat > "$X"/qbtt/torrent_web.py <<'QBTT_WEB_EOF'
#!/usr/bin/env python3
"""
torrent_web.py - Small LAN web page to search torrents with qBittorrent

Paste one or more searches (one per line), the page runs them through qBittorrent's
search engine and shows the results; one click adds them to the downloads.

Uses only the Python standard library (no extra pip/apt packages).

Start:
    python3 torrent_web.py
    then open from another device:  http://SERVER-IP:8083

Configuration (environment variables or the CONFIG section):
    QBIT_URL      qBittorrent Web UI address              (default http://localhost:8082)
    QBIT_USER     Web UI user
    QBIT_PASS     Web UI password
    WEB_HOST      address to listen on                    (default 0.0.0.0)
    WEB_PORT      port of the page                        (default 8083)
    WEB_PASSWORD  if set, the page asks for user/password (any user name)
"""

import base64
import hmac
import http.cookiejar
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ----------------------------- CONFIG -----------------------------
QBIT_URL = os.getenv("QBIT_URL", "http://localhost:8082").rstrip("/")
QBIT_USER = os.getenv("QBIT_USER", "")
QBIT_PASS = os.getenv("QBIT_PASS", "")

WEB_HOST = os.getenv("WEB_HOST", "0.0.0.0")
WEB_PORT = int(os.getenv("WEB_PORT", "8083"))
WEB_PASSWORD = os.getenv("WEB_PASSWORD", "")   # empty = no password

SEARCH_TIMEOUT = 60
# ------------------------------------------------------------------


class QbitError(Exception):
    pass


class QBittorrent:
    """Minimal client for the qBittorrent Web API (standard library only)."""

    def __init__(self, url, user, password):
        self.url, self.user, self.password = url, user, password
        self.lock = threading.Lock()
        self._new_session()

    def _new_session(self):
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        self.opener.addheaders = [("Referer", self.url), ("Origin", self.url)]
        self.logged_in = False

    def _request(self, path, data=None, params=None, timeout=30):
        url = f"{self.url}/api/v2/{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        body = urllib.parse.urlencode(data).encode() if data is not None else None
        try:
            with self.opener.open(url, data=body, timeout=timeout) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")
        except urllib.error.URLError as e:
            raise QbitError(f"qBittorrent not reachable at {self.url} ({e.reason}). "
                            "Is it running with the Web UI enabled?")

    def login(self):
        with self.lock:
            if self.logged_in:
                return
            status, text = self._request("auth/login",
                                         {"username": self.user, "password": self.password})
            if text.strip() == "Ok.":
                self.logged_in = True
                return
            # login ok without "Ok." body (qBittorrent 5.2+) or localhost auth bypass
            if self._request("app/version")[0] == 200:
                self.logged_in = True
                return
            if status == 403:
                raise QbitError("qBittorrent blocked access after too many failed attempts: "
                                "restart it or wait.")
            raise QbitError("qBittorrent login failed: check QBIT_USER and QBIT_PASS.")

    def api(self, path, data=None, params=None, timeout=30):
        self.login()
        status, text = self._request(path, data, params, timeout)
        if status == 403:              # session expired: log in again once
            self.logged_in = False
            self.login()
            status, text = self._request(path, data, params, timeout)
        if status >= 400:
            raise QbitError(f"qBittorrent error {status} on {path}: {text.strip()[:200]}")
        return text

    def enabled_plugins(self):
        return [p["name"] for p in json.loads(self.api("search/plugins")) if p.get("enabled")]

    def search(self, text, category="all"):
        job = json.loads(self.api("search/start", {"pattern": text, "plugins": "enabled",
                                                   "category": category}))["id"]
        try:
            start = time.time()
            while time.time() - start < SEARCH_TIMEOUT:
                status = json.loads(self.api("search/status", params={"id": job}))
                if status and status[0].get("status") == "Stopped":
                    break
                time.sleep(1)
            data = json.loads(self.api("search/results", params={"id": job, "limit": 0}))
        finally:
            for p in ("search/stop", "search/delete"):
                try:
                    self.api(p, {"id": job})
                except QbitError:
                    pass

        results = []
        for r in data.get("results", []):
            results.append({
                "title": r.get("fileName", ""),
                "seeders": max(int(r.get("nbSeeders") or 0), 0),
                "leechers": max(int(r.get("nbLeechers") or 0), 0),
                "mb": round(max(int(r.get("fileSize") or 0), 0) / 1048576, 1),
                "site": r.get("siteUrl", ""),
                "page": r.get("descrLink", ""),
                "link": r.get("fileUrl", ""),
            })
        results.sort(key=lambda x: x["seeders"], reverse=True)
        return results

    def add(self, link):
        self.api("torrents/add", {"urls": link})


QB = QBittorrent(QBIT_URL, QBIT_USER, QBIT_PASS)


PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Torrent search</title>
<style>
  :root {
    --bg: #f4f2ee; --card: #ffffff; --ink: #1d1c1a; --muted: #6d6a64; --line: #e3dfd8;
    --accent: #2f6f5e; --accent-ink: #ffffff; --warn: #a2462c; --chip: #ece8e1;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #151514; --card: #1f1f1d; --ink: #ecebe7; --muted: #9b978f; --line: #33322f;
            --accent: #6cbfa6; --accent-ink: #0f1513; --warn: #e48a6d; --chip: #2a2a27; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--ink);
         font: 15px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 960px; margin: 0 auto; padding: 24px 16px 64px; }
  h1 { font-size: 22px; margin: 0 0 4px; letter-spacing: -.01em; }
  .sub { color: var(--muted); margin: 0 0 20px; font-size: 14px; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px; }
  textarea { width: 100%; min-height: 120px; resize: vertical; padding: 10px 12px; border-radius: 8px;
             border: 1px solid var(--line); background: var(--bg); color: var(--ink); font: inherit; }
  .filters { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; margin: 12px 0; }
  label { display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: var(--muted); }
  input, select { padding: 8px 10px; border-radius: 8px; border: 1px solid var(--line);
                  background: var(--bg); color: var(--ink); font: inherit; }
  .row { display: flex; flex-wrap: wrap; gap: 12px; align-items: center; justify-content: space-between; }
  .check { flex-direction: row; align-items: center; gap: 8px; color: var(--ink); font-size: 14px; }
  button { cursor: pointer; border: 0; border-radius: 8px; font: inherit; font-weight: 600; }
  .primary { background: var(--accent); color: var(--accent-ink); padding: 10px 20px; }
  .primary:disabled { opacity: .5; cursor: default; }
  .status { font-size: 13px; color: var(--muted); margin: 12px 2px 0; min-height: 1.4em; }
  .status.err { color: var(--warn); }
  section.group { margin-top: 22px; }
  section.group h2 { font-size: 16px; margin: 0 0 8px; display: flex; gap: 8px; align-items: baseline; }
  section.group h2 small { color: var(--muted); font-weight: 400; font-size: 13px; }
  .result { display: grid; grid-template-columns: 1fr auto; gap: 4px 12px; padding: 10px 12px;
            border-top: 1px solid var(--line); align-items: center; }
  .result:first-of-type { border-top: 0; }
  .title { word-break: break-word; }
  .meta { display: flex; flex-wrap: wrap; gap: 6px; font-size: 12px; color: var(--muted); }
  .chip { background: var(--chip); border-radius: 999px; padding: 1px 8px; }
  .chip.seed { color: var(--accent); font-weight: 600; }
  .meta a { color: var(--muted); }
  .download { grid-row: 1 / span 2; grid-column: 2; background: var(--chip); color: var(--ink); padding: 8px 14px; }
  .download.ok { background: var(--accent); color: var(--accent-ink); }
  .download.err { color: var(--warn); }
  .empty { color: var(--muted); padding: 10px 12px; font-size: 14px; }
</style>
</head>
<body>
<main>
  <h1>Torrent search</h1>
  <p class="sub" id="plugins">Connecting to qBittorrent…</p>

  <div class="card">
    <textarea id="queries" placeholder="One search per line&#10;e.g. debian 12 netinst"></textarea>
    <div class="filters">
      <label>Type
        <select id="type">
          <option value="all">All</option><option value="movies">Movies</option>
          <option value="tv">TV shows</option><option value="music">Music</option>
          <option value="games">Games</option><option value="anime">Anime</option>
          <option value="software">Software</option><option value="books">Books</option>
        </select>
      </label>
      <label>Results per search <input id="top" type="number" min="1" max="50" value="5"></label>
      <label>Minimum seeders <input id="seed" type="number" min="0" value="1"></label>
      <label>Must contain <input id="filter" placeholder="e.g. 1080p"></label>
      <label>Max MB <input id="maxmb" type="number" min="0" placeholder="no limit"></label>
    </div>
    <div class="row">
      <label class="check"><input type="checkbox" id="auto"> Download the best result of each search right away</label>
      <button class="primary" id="go">Search</button>
    </div>
    <div class="status" id="status"></div>
  </div>

  <div id="results"></div>
</main>

<script>
const $ = id => document.getElementById(id);

async function api(path, body) {
  const r = await fetch(path, {
    method: body ? "POST" : "GET",
    headers: body ? {"Content-Type": "application/json"} : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = await r.json().catch(() => ({error: "Invalid response from the server"}));
  if (!r.ok || data.error) throw new Error(data.error || ("Error " + r.status));
  return data;
}

function status(msg, error) { const s = $("status"); s.textContent = msg; s.className = "status" + (error ? " err" : ""); }

function safeLink(u) { return /^https?:\/\//i.test(u || "") ? u : null; }

async function download(btn, link) {
  btn.disabled = true; btn.textContent = "…";
  try { await api("/api/add", {link}); btn.textContent = "Added"; btn.className = "download ok"; }
  catch (e) { btn.textContent = "Error"; btn.className = "download err"; btn.title = e.message; btn.disabled = false; }
}

function showGroup(query, results) {
  const sec = document.createElement("section"); sec.className = "group";
  const h = document.createElement("h2"); h.textContent = query;
  const n = document.createElement("small"); n.textContent = results.length + " results";
  h.append(" ", n); sec.append(h);
  const card = document.createElement("div"); card.className = "card"; card.style.padding = "0";
  if (!results.length) {
    const v = document.createElement("div"); v.className = "empty"; v.textContent = "No results with these filters.";
    card.append(v);
  }
  const buttons = [];
  for (const r of results) {
    const row = document.createElement("div"); row.className = "result";
    const t = document.createElement("div"); t.className = "title"; t.textContent = r.title;
    const meta = document.createElement("div"); meta.className = "meta";
    const chip = (txt, cls) => { const c = document.createElement("span"); c.className = "chip " + (cls || ""); c.textContent = txt; return c; };
    meta.append(chip(r.seeders + " seed", "seed"), chip(r.leechers + " leech"), chip(r.mb ? r.mb + " MB" : "? MB"));
    const page = safeLink(r.page);
    if (page) { const a = document.createElement("a"); a.href = page; a.target = "_blank"; a.rel = "noopener noreferrer";
                a.textContent = new URL(page).hostname; meta.append(a); }
    const b = document.createElement("button"); b.className = "download"; b.textContent = "Download";
    b.onclick = () => download(b, r.link);
    row.append(t, b, meta); card.append(row); buttons.push(b);
  }
  sec.append(card); $("results").append(sec);
  return buttons;
}

$("go").onclick = async () => {
  const queries = $("queries").value.split("\n").map(s => s.trim()).filter(s => s && !s.startsWith("#"));
  if (!queries.length) { status("Enter at least one search.", true); return; }
  $("go").disabled = true; $("results").innerHTML = "";
  const filter = $("filter").value.trim().toLowerCase();
  const maxmb = parseFloat($("maxmb").value) || 0;
  const minSeed = parseInt($("seed").value) || 0;
  const top = parseInt($("top").value) || 5;
  try {
    for (let i = 0; i < queries.length; i++) {
      const q = queries[i];
      status(`Search ${i + 1} of ${queries.length}: ${q}…`);
      let res;
      try { res = (await api("/api/search", {query: q, type: $("type").value})).results; }
      catch (e) { status(`Error on "${q}": ${e.message}`, true); continue; }
      res = res.filter(r => r.seeders >= minSeed)
               .filter(r => !filter || r.title.toLowerCase().includes(filter))
               .filter(r => !maxmb || (r.mb && r.mb <= maxmb))
               .slice(0, top);
      const buttons = showGroup(q, res);
      if ($("auto").checked && buttons.length) await download(buttons[0], res[0].link);
    }
    if (!$("status").classList.contains("err")) status("Done.");
  } finally { $("go").disabled = false; }
};

api("/api/plugins").then(d => {
  $("plugins").textContent = d.plugins.length ? "Enabled plugins: " + d.plugins.join(", ")
    : "No search plugin enabled in qBittorrent.";
}).catch(e => { $("plugins").textContent = e.message; $("plugins").style.color = "var(--warn)"; });
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "TorrentWeb/1.0"

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} - {fmt % args}")

    def _authorized(self):
        if not WEB_PASSWORD:
            return True
        h = self.headers.get("Authorization", "")
        if h.startswith("Basic "):
            try:
                _, _, pwd = base64.b64decode(h[6:]).decode().partition(":")
                if hmac.compare_digest(pwd.encode(), WEB_PASSWORD.encode()):
                    return True
            except Exception:
                pass
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Torrent search"')
        self.end_headers()
        return False

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _json_body(self):
        # blocks forms from other sites (CSRF): a form cannot send application/json
        if self.headers.get_content_type() != "application/json":
            raise ValueError("Content-Type must be application/json")
        n = int(self.headers.get("Content-Length") or 0)
        if n > 100_000:
            raise ValueError("request too large")
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        if not self._authorized():
            return
        path = urllib.parse.urlsplit(self.path).path
        if path in ("/", "/index.html"):
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if path == "/api/plugins":
            try:
                return self._send(200, {"plugins": QB.enabled_plugins()})
            except QbitError as e:
                return self._send(502, {"error": str(e)})
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._authorized():
            return
        try:
            path = urllib.parse.urlsplit(self.path).path
            data = self._json_body()
            if path == "/api/search":
                q = str(data.get("query", "")).strip()
                if not q:
                    return self._send(400, {"error": "empty search"})
                return self._send(200, {"results": QB.search(q, str(data.get("type") or "all"))})
            if path == "/api/add":
                link = str(data.get("link", "")).strip()
                if not link.startswith(("magnet:", "http://", "https://")):
                    return self._send(400, {"error": "invalid link"})
                QB.add(link)
                return self._send(200, {"ok": True})
            self._send(404, {"error": "not found"})
        except QbitError as e:
            self._send(502, {"error": str(e)})
        except (ValueError, json.JSONDecodeError) as e:
            self._send(400, {"error": f"invalid request: {e}"})


def main():
    srv = ThreadingHTTPServer((WEB_HOST, WEB_PORT), Handler)
    print(f"Page running at http://{WEB_HOST}:{WEB_PORT}  (qBittorrent: {QBIT_URL})")
    if not WEB_PASSWORD:
        print("Warning: no password set, anyone on the LAN can use the page (WEB_PASSWORD).")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nClosed.")


if __name__ == "__main__":
    main()
QBTT_WEB_EOF
cat > "$X"/qbtt/scripts/qbt-sort.py <<'QBTT_SORT_EOF'
#!/usr/bin/env python3
"""
qbt-sort.py - sorts completed torrents into /Films, /Musics, /SerieTv.
Music goes to /Musics/<Artist>/<Album>/ (Jellyfin layout), artist and album
read from the audio tags (audiotags.py) or, failing that, from the torrent name.

Run by qBittorrent ("Run external program on torrent finished"):
    python3 /scripts/qbt-sort.py "%K"
(%K = torrent ID, also valid for v2 torrents; %I is "-" for v2 torrents)

Uses the Web API (localhost, no login: "bypass_local_auth"; port from QBT_WEBUI_PORT
or from qBittorrent.conf) and torrents/setLocation,
so qBittorrent moves the files itself and keeps seeding from the new location.

Test without moving anything:  python3 qbt-sort.py <hash> --dry-run
"""
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from collections import Counter
from datetime import datetime

from audiotags import read_tags

LOG = "/config/qbt-sort.log"
CONF = "/config/qBittorrent/config/qBittorrent.conf"


def webui_port():
    """QBT_WEBUI_PORT does not reach the script (the image's doas clears the environment):
    if missing, read it from qBittorrent.conf."""
    if os.getenv("QBT_WEBUI_PORT"):
        return os.environ["QBT_WEBUI_PORT"]
    try:
        with open(CONF) as f:
            for line in f:
                if line.startswith("WebUI\\Port="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return "8082"


API = "http://127.0.0.1:%s/api/v2/" % webui_port()

DEST = {"video_movie": "/Films", "video_series": "/SerieTv", "audio": "/Musics"}

EXT_VIDEO = {"mkv", "mp4", "avi", "m4v", "mov", "wmv", "mpg", "mpeg", "ts", "m2ts", "webm", "flv", "vob", "divx"}
EXT_AUDIO = {"mp3", "flac", "m4a", "aac", "ogg", "opus", "wav", "wma", "alac", "ape", "aiff", "dsf"}
# executables and scripts: never expected in a film/series/music torrent
EXT_RISKY = {"exe", "msi", "scr", "bat", "cmd", "com", "pif", "cpl", "dll", "sys", "lnk", "reg",
             "vbs", "vbe", "js", "jse", "wsf", "wsh", "hta", "ps1", "psm1", "jar", "apk",
             "app", "dmg", "pkg", "deb", "rpm", "sh", "run"}
WARNING_FILE = "POTENTIALLY HARMFUL"

# S01E02, S01, 1x02, Season 1/Stagione 2, "Complete Series", Ep 01
# (season/stagione only when followed by a number: "The Four Seasons" is a movie)
RE_SERIES = re.compile(
    r"(\bS\d{1,2}\s?E\d{1,3}\b|\bS\d{1,2}\b|\b\d{1,2}x\d{2,3}\b|"
    r"\bseasons?[ ._\-]?\d{1,2}\b|\bstagion[ei][ ._\-]?\d{1,2}\b|"
    r"complete.?series|serie\s?(tv|completa)|\bep(isode)?\s?\d{1,3}\b)",
    re.IGNORECASE,
)

# "Title.2018.1080p..." -> title + year (takes the last year: "Blade.Runner.2049.2017")
RE_YEAR = re.compile(r"^(.+)[ ._\-\(\[]((?:19|20)\d{2})(?=$|[ ._\-\)\]])")
# no year: cut at the first quality/rip tag
RE_TAG = re.compile(
    r"[ ._\-\(\[](2160p|1080p|720p|576p|480p|4k|uhd|bluray|blu-ray|bdrip|brrip|web-?dl|webrip|"
    r"hdtv|dvdrip|x264|x265|h\.?264|h\.?265|hevc|ita|eng|multi)\b",
    re.IGNORECASE,
)


def movie_folder(name):
    """'BlacKkKlansman.2018.1080p.BluRay' -> 'BlacKkKlansman (2018)'"""
    if "." in name and name.rsplit(".", 1)[1].lower() in EXT_VIDEO:
        name = name.rsplit(".", 1)[0]
    m = RE_YEAR.match(name)
    if m:
        title, year = m.group(1), m.group(2)
    else:
        title, year = RE_TAG.split(name, 1)[0], None
    title = re.sub(r"[._]+", " ", title)
    title = re.sub(r'[\\/:*?"<>|\[\]\(\)]', "", title).strip(" -")
    if not title:
        title = re.sub(r'[\\/:*?"<>|]', "", name).strip()
    return "%s (%s)" % (title, year) if year else title


UNKNOWN_ARTIST = "Unknown Artist"
VARIOUS_ARTISTS = "Various Artists"

# "Artist feat. X", "Artist (ft. X)", "Artist Featuring X" -> "Artist"
# ("&", "," and "x" are not split: "Simon & Garfunkel" is one artist)
RE_FEAT = re.compile(r"\s*[\(\[]?\s*\b(feat\.?|ft\.?|featuring)\s.*$", re.IGNORECASE)
# "Artist - Album (2019) [FLAC 24-96]" -> ("Artist", "Album (2019)")
RE_ARTIST_ALBUM = re.compile(r"^(.+?)\s+[-–—]\s+(.+)$")


def clean_name(name):
    """Make a tag usable as a folder name ("AC/DC" -> "AC-DC")."""
    name = re.sub(r"[\\/]", "-", name or "")
    name = re.sub(r'[:*?"<>|\x00-\x1f]', "", name)
    name = re.sub(r"\s+", " ", name).strip(" .")
    return name[:150].strip(" .")


def main_artist(artist):
    return RE_FEAT.sub("", artist).strip() or artist


def names_from_title(name):
    """Fallback: (artist, album) from "Artist - Album (Year) [FLAC]"."""
    name = re.sub(r"\s*\[[^\]]*\]", "", name).replace("_", " ").strip()
    m = RE_ARTIST_ALBUM.match(name)
    if m:
        return main_artist(m.group(1).strip()), m.group(2).strip()
    return None, name or None


def music_names(t, files):
    """(artist, album) folder names for an audio torrent: majority of the
    tags of its tracks, then the torrent name, then Unknown Artist."""
    albumartists, artists, albums = Counter(), Counter(), Counter()
    tracks = 0
    for f in files:
        ext = f["name"].rsplit(".", 1)[-1].lower() if "." in f["name"] else ""
        if ext not in EXT_AUDIO or f.get("progress", 1) < 1:
            continue
        tracks += 1
        tags = read_tags(os.path.join(t["save_path"], f["name"]))
        if tags["albumartist"]:
            albumartists[main_artist(tags["albumartist"])] += 1
        if tags["artist"]:
            artists[main_artist(tags["artist"])] += 1
        if tags["album"]:
            albums[tags["album"]] += 1

    artist = album = None
    if albumartists:
        artist = albumartists.most_common(1)[0][0]
    elif artists:
        top, n = artists.most_common(1)[0]
        # no album artist and no clear majority among many artists: a compilation
        artist = VARIOUS_ARTISTS if len(artists) >= 3 and n * 2 < tracks else top
    if albums:
        top, n = albums.most_common(1)[0]
        if n >= 0.8 * sum(albums.values()):
            album = top

    root = root_folder(files) or t["name"]
    title_artist, title_album = names_from_title(root)
    if not album:
        # no album tag, or several albums (e.g. a discography): use the torrent's name
        album = title_album
    artist = clean_name(artist or title_artist) or UNKNOWN_ARTIST
    album = clean_name(album) or clean_name(t["name"]) or "Unknown Album"
    return artist, album


def free_name(parent, name, own=None):
    """name, or "name (2)", "name (3)"... if parent/name already exists
    and is not where this torrent already is (own)."""
    candidate, i = name, 1
    while True:
        path = os.path.join(parent, candidate)
        if not os.path.exists(path) or path == own:
            return candidate
        i += 1
        candidate = "%s (%d)" % (name, i)


def risky_files(files):
    """Names of the torrent's executables/scripts ("track.mp3.exe" included)."""
    return [f["name"] for f in files
            if "." in f["name"] and f["name"].rsplit(".", 1)[1].lower() in EXT_RISKY]


def mark_risky(name, risky, folder, dry=False):
    """Log a warning and, if the torrent has its own folder, leave a
    WARNING_FILE in it listing the suspicious files."""
    if not risky:
        return
    log("WARN  '%s': %d potentially harmful file(s): %s"
        % (name, len(risky), ", ".join(risky[:5]) + (" ..." if len(risky) > 5 else "")))
    if dry or folder is None:
        return
    try:
        with open(os.path.join(folder, WARNING_FILE), "w") as f:
            f.write("qbt-sort: this torrent contains executables or scripts.\n"
                    "Do not open them unless you know exactly what they are.\n\n")
            f.write("\n".join(risky) + "\n")
        log("WARN  '%s': created %s" % (name, os.path.join(folder, WARNING_FILE)))
    except OSError as e:
        log("ERROR '%s': cannot create %s in %s: %r" % (name, WARNING_FILE, folder, e))


def log(msg):
    line = "%s  %s" % (datetime.now().strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line)
    try:
        with open(LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def api(path, data=None):
    body = urllib.parse.urlencode(data).encode() if data is not None else None
    with urllib.request.urlopen(API + path, body, timeout=30) as r:
        return r.read().decode()


def torrent_info(hash_):
    info = json.loads(api("torrents/info?" + urllib.parse.urlencode({"hashes": hash_})))
    return info[0] if info else None


def wait_for_move(hash_, max_seconds=3600):
    """Wait until qBittorrent has finished moving the files (e.g. from /downloads/temp)."""
    t = torrent_info(hash_)
    for _ in range(max_seconds // 5):
        if t is None or t["state"] != "moving":
            break
        time.sleep(5)
        t = torrent_info(hash_)
    return t


def root_folder(files):
    """Name of the torrent's top folder, if all files are inside a single one."""
    roots = {f["name"].split("/", 1)[0] for f in files}
    if len(roots) == 1 and all("/" in f["name"] for f in files):
        return roots.pop()
    return None


def classify(name, files):
    size = {"video": 0, "audio": 0}
    series_videos = 0
    for f in files:
        ext = f["name"].rsplit(".", 1)[-1].lower() if "." in f["name"] else ""
        if ext in EXT_VIDEO:
            size["video"] += f["size"]
            if RE_SERIES.search(os.path.basename(f["name"])):
                series_videos += 1
        elif ext in EXT_AUDIO:
            size["audio"] += f["size"]

    if size["video"] == 0 and size["audio"] == 0:
        return None
    if size["audio"] > size["video"]:
        return "audio"
    if RE_SERIES.search(name) or series_videos >= 2:
        return "video_series"
    return "video_movie"


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    hash_ = sys.argv[1]
    dry = "--dry-run" in sys.argv

    # with the temp folder enabled the torrent may still be moving
    t = wait_for_move(hash_)
    if t is None:
        log("ERROR torrent %s not found" % hash_)
        return 1
    files = json.loads(api("torrents/files?" + urllib.parse.urlencode({"hash": hash_})))

    risky = risky_files(files)
    if risky:
        # never move a torrent with executables/scripts: it stays in /downloads
        root = root_folder(files)
        mark_risky(t["name"], risky, os.path.join(t["save_path"], root) if root else None, dry)
        log("HOLD  '%s': not moved because of the files above, stays in %s"
            % (t["name"], t["save_path"]))
        return 0

    kind = classify(t["name"], files)
    if kind is None:
        log("SKIP  '%s': no video/audio files, stays in %s" % (t["name"], t["save_path"]))
        return 0

    dest = DEST[kind]
    rename = None   # (old, new) top folder of the torrent
    artist_dir = None
    if kind == "video_movie":
        root = root_folder(files)
        if root is None and len(files) == 1:
            # single-file movie: give it a "Title (Year)" folder
            dest = os.path.join(dest, movie_folder(t["name"]))
        elif root is not None and movie_folder(root) != root:
            # movie already in a folder: rename it to "Title (Year)"
            rename = (root, movie_folder(root))
    elif kind == "audio":
        # /Musics/<Artist>/<Album>/...
        artist, album = music_names(t, files)
        dest = artist_dir = os.path.join(dest, artist)
        root = root_folder(files)
        if root is None:
            # loose files: the album folder is created by setLocation
            dest = os.path.join(dest, free_name(dest, album, t["save_path"].rstrip("/")))
        else:
            own = os.path.join(t["save_path"], root) if t["save_path"].rstrip("/") == dest else None
            album = free_name(dest, album, own)
            if album != root:
                rename = (root, album)
    if t["save_path"].rstrip("/") == dest and rename is None:
        log("SKIP  '%s': already in %s" % (t["name"], dest))
        return 0
    if not os.path.isdir(DEST[kind]):
        log("ERROR '%s': folder %s not mounted in the container" % (t["name"], DEST[kind]))
        return 1

    final = os.path.join(dest, rename[1]) if rename else dest
    if dry:
        log("DRY   '%s' -> %s" % (t["name"], final))
        return 0

    if artist_dir and not os.path.isdir(artist_dir):
        # artist folder: create it if missing
        os.makedirs(artist_dir, exist_ok=True)
        log("MKDIR %s" % artist_dir)
    if rename:
        api("torrents/renameFolder", {"hash": hash_, "oldPath": rename[0], "newPath": rename[1]})
    if t["save_path"].rstrip("/") != dest:
        api("torrents/setLocation", {"hashes": hash_, "location": dest})
    # wait for the move to finish, only to log it
    time.sleep(5)
    t2 = wait_for_move(hash_)
    if t2 is not None and t2["save_path"].rstrip("/") != dest:
        # setLocation answers ok even if the move then fails (e.g. permissions)
        log("ERROR '%s': move to %s failed, stays in %s (state: %s)"
            % (t["name"], dest, t2["save_path"], t2["state"]))
        return 1
    log("MOVE  '%s' -> %s (state: %s)" % (t["name"], final, t2["state"] if t2 else "removed"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # never make qBittorrent fail because of this script
        log("ERROR %s: %r" % (sys.argv[1:], e))
        sys.exit(1)
QBTT_SORT_EOF
chmod +x "$X"/qbtt/scripts/qbt-sort.py
cat > "$X"/qbtt/scripts/audiotags.py <<'QBTT_TAGS_EOF'
"""
audiotags.py - minimal reader for albumartist / artist / album, used by qbt-sort.py.

Standard library only (the qBittorrent image has no mutagen).
Formats: MP3 (ID3v2.2/2.3/2.4 + ID3v1), FLAC, Ogg Vorbis, Opus, M4A/MP4;
anything else returns empty tags.
read_tags(path) -> {"albumartist": str|None, "artist": str|None, "album": str|None}
"""
import struct

KEYS = ("albumartist", "artist", "album")


def _empty():
    return dict.fromkeys(KEYS)


def _clean(s):
    s = (s or "").replace("\x00", "/").strip(" /")
    return s or None


# ---------------------------------------------------------------- ID3
ID3_MAP = {
    "TPE2": "albumartist", "TPE1": "artist", "TALB": "album",   # v2.3 / v2.4
    "TP2": "albumartist", "TP1": "artist", "TAL": "album",      # v2.2
}


def _syncsafe(b):
    return (b[0] << 21) | (b[1] << 14) | (b[2] << 7) | b[3]


def _id3_text(data):
    if not data:
        return None
    enc, raw = data[0], data[1:]
    codec = {0: "latin-1", 1: "utf-16", 2: "utf-16-be", 3: "utf-8"}.get(enc, "latin-1")
    if enc in (1, 2) and len(raw) % 2:
        raw = raw[:-1]
    text = raw.decode(codec, "replace")
    # v2.4 multi-value: separated by NUL -> keep the first value
    return _clean(text.split("\x00")[0])


def read_id3v2(f):
    tags = _empty()
    f.seek(0)
    head = f.read(10)
    if len(head) < 10 or head[:3] != b"ID3":
        return tags, 0
    ver, flags, size = head[3], head[5], _syncsafe(head[6:10])
    body = f.read(size)
    if flags & 0x80 and ver < 4:            # whole-tag unsynchronisation (v2.2/2.3)
        body = body.replace(b"\xff\x00", b"\xff")
    pos = 0
    if flags & 0x40 and ver >= 3:           # extended header
        ext = body[:4]
        pos = _syncsafe(ext) if ver == 4 else struct.unpack(">I", ext)[0] + 4
    idlen, hlen = (3, 6) if ver == 2 else (4, 10)
    while pos + hlen <= len(body):
        fid = body[pos:pos + idlen]
        if not fid.strip(b"\x00"):
            break                           # padding
        if ver == 2:
            fsize = int.from_bytes(body[pos + 3:pos + 6], "big")
        elif ver == 4:
            fsize = _syncsafe(body[pos + 4:pos + 8])
        else:
            fsize = struct.unpack(">I", body[pos + 4:pos + 8])[0]
        data = body[pos + hlen:pos + hlen + fsize]
        key = ID3_MAP.get(fid.decode("latin-1", "replace"))
        if key and not tags[key]:
            if ver == 4 and body[pos + 9] & 0x02:   # per-frame unsynchronisation
                data = data.replace(b"\xff\x00", b"\xff")
            tags[key] = _id3_text(data)
        pos += hlen + fsize
    return tags, 10 + size


def read_id3v1(f):
    tags = _empty()
    try:
        f.seek(-128, 2)
    except OSError:
        return tags
    b = f.read(128)
    if b[:3] == b"TAG":
        dec = lambda x: _clean(x.split(b"\x00")[0].decode("latin-1"))
        tags["artist"], tags["album"] = dec(b[33:63]), dec(b[63:93])
    return tags


# ---------------------------------------------------------------- Vorbis comments
VORBIS_MAP = {"ALBUMARTIST": "albumartist", "ALBUM ARTIST": "albumartist",
              "ARTIST": "artist", "ALBUM": "album"}


def _vorbis_comments(b):
    tags = _empty()
    try:
        vlen = struct.unpack("<I", b[:4])[0]
        pos = 4 + vlen
        n = struct.unpack("<I", b[pos:pos + 4])[0]
        pos += 4
        for _ in range(n):
            ln = struct.unpack("<I", b[pos:pos + 4])[0]
            kv = b[pos + 4:pos + 4 + ln].decode("utf-8", "replace")
            pos += 4 + ln
            k, _, v = kv.partition("=")
            key = VORBIS_MAP.get(k.upper())
            if key and not tags[key]:
                tags[key] = _clean(v)
    except (struct.error, IndexError):
        pass
    return tags


def read_flac(f, start):
    f.seek(start)
    if f.read(4) != b"fLaC":
        return _empty()
    while True:
        h = f.read(4)
        if len(h) < 4:
            return _empty()
        last, btype, size = h[0] & 0x80, h[0] & 0x7F, int.from_bytes(h[1:4], "big")
        if btype == 4:
            return _vorbis_comments(f.read(size))
        f.seek(size, 1)
        if last:
            return _empty()


def read_ogg(f, max_bytes=16 << 20):
    """Rebuild the 2nd logical packet (comment header) from Ogg pages.
    The packet can span many pages when it embeds cover art."""
    f.seek(0)
    packets, cur = [], b""
    while f.tell() < max_bytes:
        h = f.read(27)
        if len(h) < 27 or h[:4] != b"OggS":
            break
        segs = f.read(h[26])
        for s in segs:
            cur += f.read(s)
            if s < 255:
                packets.append(cur)
                cur = b""
        if len(packets) >= 2:
            break
    for p in packets[1:2]:
        if p[:7] == b"\x03vorbis":
            return _vorbis_comments(p[7:])
        if p[:8] == b"OpusTags":
            return _vorbis_comments(p[8:])
    return _empty()


# ---------------------------------------------------------------- MP4 / M4A
MP4_MAP = {b"aART": "albumartist", b"\xa9ART": "artist", b"\xa9alb": "album"}
MP4_CONTAINERS = {b"moov", b"udta", b"meta", b"ilst"}


def read_mp4(f):
    tags = _empty()
    f.seek(0, 2)
    end = f.tell()

    def walk(start, stop, depth):
        pos = start
        while pos + 8 <= stop and depth < 6:
            f.seek(pos)
            h = f.read(8)
            size, typ = struct.unpack(">I", h[:4])[0], h[4:8]
            hdr = 8
            if size == 1:
                size, hdr = struct.unpack(">Q", f.read(8))[0], 16
            elif size == 0:
                size = stop - pos
            if size < hdr:
                return
            if typ in MP4_CONTAINERS:
                skip = 4 if typ == b"meta" else 0      # meta has version+flags
                walk(pos + hdr + skip, pos + size, depth + 1)
            elif typ in MP4_MAP:
                b = f.read(min(size - hdr, 4096))
                # child 'data' atom: size(4) 'data'(4) type(4) locale(4) value
                if b[4:8] == b"data":
                    dlen = struct.unpack(">I", b[:4])[0]
                    key = MP4_MAP[typ]
                    if not tags[key]:
                        tags[key] = _clean(b[16:dlen].decode("utf-8", "replace"))
            pos += size

    walk(0, end, 0)
    return tags


# ---------------------------------------------------------------- entry point
def read_tags(path):
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    try:
        with open(path, "rb") as f:
            if ext in ("m4a", "mp4", "aac", "alac", "m4b"):
                return read_mp4(f)
            if ext in ("ogg", "opus", "oga"):
                return read_ogg(f)
            tags, end = read_id3v2(f)           # MP3, but FLAC can also start with ID3
            if ext == "flac":
                return read_flac(f, end)
            if not (tags["artist"] or tags["albumartist"]):
                v1 = read_id3v1(f)
                for k in KEYS:
                    tags[k] = tags[k] or v1[k]
            return tags
    except (OSError, struct.error, ValueError):
        return _empty()


if __name__ == "__main__":
    import sys
    for p in sys.argv[1:]:
        print(p.rsplit("/", 1)[-1], read_tags(p))
QBTT_TAGS_EOF
cat > "$X"/qbtt/env.example <<'QBTT_ENV_EOF'
# --- web page ---
WEB_PORT=8083
# password to open the page (recommended)
WEB_PASSWORD=CHANGEME

# --- qBittorrent in the compose container ---
QBIT_URL=http://qbittorrent-nox:8082
QBIT_USER=CHANGEME
QBIT_PASS=CHANGEME

QBT_VERSION=5.2.4-1
QBT_LEGAL_NOTICE=confirm
QBT_WEBUI_PORT=8082
QBT_TORRENTING_PORT=6881
PUID=__UID__
PGID=__GID__

QBT_CONFIG_PATH=./qbittorrent/config
QBT_DOWNLOADS_PATH=__MEDIA__/downloads
QBT_FILMS_PATH=__MEDIA__/Films
QBT_MUSICS_PATH=__MEDIA__/Musics
QBT_SERIETV_PATH=__MEDIA__/SerieTv
TZ=Europe/Rome
QBTT_ENV_EOF


# --- bento: BentoPDF (PDF tools in the browser) :8080 ---
cat > "$X"/bento/bento.yml <<'BENTO_COMPOSE_EOF'
services:
  bentopdf:
    image: ghcr.io/alam00000/bentopdf-simple:latest
    container_name: bentopdf
    restart: unless-stopped
    ports:
      - '8080:8080'
    # For IPv4-only environments
    environment:
      - DISABLE_IPV6=true
BENTO_COMPOSE_EOF

# --- egos-extras: enable/disable the optional stacks ---
cat > "$OVL"/usr/local/bin/egos-extras <<'EXTRAS_EOF'
#!/bin/bash
# EgOS - optional stacks, not started by default.
#   egos-extras list               available stacks and their state
#   egos-extras enable <name>      copy to ~/app, create .env, start
#   egos-extras disable <name>     stop (files and data are kept)
set -euo pipefail

SRC=/usr/local/share/stack/extras
U=$(python3 -c "import json;print(json.load(open('/var/lib/setup-data.json'))['user'])" 2>/dev/null || true)
[ -n "$U" ] && id "$U" >/dev/null 2>&1 || { echo "Setup user cannot be determined."; exit 1; }
H=$(getent passwd "$U" | cut -d: -f6)

# name -> directory (same paths as on the production box) and compose file
dest_of() {
    case "$1" in
        qbtt)  echo "$H/app/qbtt/qbittorrent-nox-easywebapp" ;;
        bento) echo "$H/app/pdf/bento" ;;
        *) return 1 ;;
    esac
}
compose_of() { case "$1" in bento) echo bento.yml ;; *) echo docker-compose.yml ;; esac; }
media_dir() {
    local m
    m=$(grep -E '^JELLYFIN_MEDIA_LOCATION=' "$H/app/repos/.env" 2>/dev/null | tail -1 | cut -d= -f2-)
    echo "${m:-/srv/egos/pool/media}"
}
as_user() { if [ "$(id -u)" -eq 0 ]; then chown -R "$U:$U" "$@"; fi; }
dc() { local d="$1"; shift; ( cd "$d" && docker compose -f "$(compose_of "$NAME")" "$@" ); }

do_list() {
    local n d state
    for n in qbtt bento; do
        d=$(dest_of "$n")
        if [ ! -d "$d" ]; then state="not installed"
        elif NAME=$n dc "$d" ps -q 2>/dev/null | grep -q .; then state="running"
        else state="stopped"; fi
        printf '  %-6s %-14s %s\n' "$n" "$state" "$d"
    done
}

do_enable() {
    local d m
    d=$(dest_of "$NAME") || { echo "Unknown stack: $NAME"; exit 1; }
    mkdir -p "$d"
    cp -r --update=none "$SRC/$NAME/." "$d/"   # never overwrite files already there
    if [ -f "$d/env.example" ] && [ ! -f "$d/.env" ]; then
        m=$(media_dir)
        sed -e "s|__MEDIA__|$m|g" -e "s|__UID__|$(id -u "$U")|" -e "s|__GID__|$(id -g "$U")|" \
            "$d/env.example" > "$d/.env"
        chmod 600 "$d/.env"
    fi
    case "$NAME" in
        qbtt) m=$(media_dir)
              mkdir -p "$d/qbittorrent/config" "$m/downloads" "$m/Films" "$m/Musics" "$m/SerieTv"
              as_user "$m/downloads" ;;
    esac
    as_user "$d"
    if [ -f "$d/.env" ] && grep -q CHANGEME "$d/.env"; then
        echo "Edit $d/.env (replace every CHANGEME), then run again:"
        echo "  egos-extras enable $NAME"
        exit 0
    fi
    dc "$d" up -d --build
    [ "$NAME" = qbtt ] && echo "First start: follow $d/README.md (qBittorrent options, sort script)."
    return 0
}

do_disable() {
    local d
    d=$(dest_of "$NAME") || { echo "Unknown stack: $NAME"; exit 1; }
    [ -d "$d" ] || { echo "$NAME is not installed."; exit 0; }
    dc "$d" down
}

NAME="${2:-}"
case "${1:-list}" in
    list)    do_list ;;
    enable)  [ -n "$NAME" ] || { echo "Usage: egos-extras enable <qbtt|bento>"; exit 1; }; do_enable ;;
    disable) [ -n "$NAME" ] || { echo "Usage: egos-extras disable <qbtt|bento>"; exit 1; }; do_disable ;;
    *) echo "Usage: egos-extras [list|enable <name>|disable <name>]"; exit 1 ;;
esac
EXTRAS_EOF
chmod +x "$OVL"/usr/local/bin/egos-extras


# -----------------------------------------------------------------------------
# 11b. arm64 / Pi 5 specific overlays
# -----------------------------------------------------------------------------
# --- hostapd on brcmfmac: mandatory country code + rfkill unblock ---
sed -i 's/^wpa_passphrase=setup1234$/&\ncountry_code=IT\nieee80211d=1/' "$OVL"/usr/local/bin/setup-webapp.sh
sed -i 's|^    ip link set "\$WIFI" down 2>/dev/null \|\| true$|    rfkill unblock wlan 2>/dev/null \|\| true\n&|' "$OVL"/usr/local/bin/setup-webapp.sh
grep -q '^country_code=IT' "$OVL"/usr/local/bin/setup-webapp.sh || { echo "ERROR 11b: country_code patch"; exit 1; }
grep -q 'rfkill unblock wlan' "$OVL"/usr/local/bin/setup-webapp.sh || { echo "ERROR 11b: rfkill patch"; exit 1; }

# --- Console banner: adds the admin console URL ---
printf '  Home page:     http://egocenter.local:8000\n  Admin console: https://egocenter.local:9090  (Storage pool page)\n  Storage:       storage-add / storage-status / storage-drain\n  Extras:        egos-extras list\n\n' >> "$OVL"/etc/issue

# --- Storage: manual addition of disks to a mergerfs pool ------------------
#     Pool /srv/egos/pool, branches /srv/egos/disks/dataN, one ext4 per disk.
#     No RAID: a lost disk = its files, not the pool.
mkdir -p "$OVL"/usr/local/sbin "$OVL"/etc/profile.d

cat > "$OVL"/usr/local/sbin/egos-storage <<'STORAGE_EOF'
#!/bin/bash
# EgOS - storage management: the mergerfs pool and its disks.
#
# The pool /srv/egos/pool ALWAYS exists, from the 1st boot: it is served by
# egos-pool.service over /srv/egos/local (a folder on the system disk) plus
# the data disks /srv/egos/disks/dataN. The stack lives on the pool from the
# start, so adding a disk never moves data or changes a path.
#   no data disk           -> branches: local=RW          (new files: system disk)
#   one or more data disks -> branches: dataN=RW...:local=NC (new files: data disks;
#                             what is already on local stays readable/writable)
#   a disk missing at boot -> pool mounted with the disks present ("degraded"),
#                             Jellyfin kept stopped until it returns (its library
#                             scan would drop the missing titles and their metadata)
#
#   egos-storage add      (default)  formats a disk and joins it to the pool (hot)
#   egos-storage status              pool and branch status
#   egos-storage remove              retires a branch (disk still attached)
#   egos-storage reattach            mounts disks that came back, refreshes the pool
#                                    (alias: remount). Also AUTOMATIC: plugging a
#                                    missing disk back in starts it via udev
#   egos-storage drain               moves files from the system disk to the data disks
#   egos-storage link                legacy installs only: moves stack data onto the pool
# Non-interactive (Cockpit page "Storage pool", scripts):
#   egos-storage status --json                  pool, branches, stack paths, job
#   egos-storage disks --json                   disks that can be added
#   egos-storage add --disk DEV --confirm DEV   (the confirmation repeats DEV)
#   egos-storage remove --branch dataN --confirm dataN
#   egos-storage link --yes [--immich]
#   egos-storage job <command> <options>        runs it as the systemd unit
#       egos-storage-job (survives a closed browser), log in $JOBLOG
# Internal (systemd units): _pool (egos-pool.service), _pool-ready, _guard, _job,
#   _autoreattach (egos-reattach.service, started by udev)
set -euo pipefail

POOL=/srv/egos/pool
LOCAL=/srv/egos/local
BRANCHES=/srv/egos/disks
FSTAB=/etc/fstab
ENVF=""
JOBUNIT=egos-storage-job
JOBLOG=/var/log/egos-storage/job.log
POOL_UNIT=egos-pool.service
RUNDIR=/run/egos
DEGRADED=$RUNDIR/pool-degraded          # list of missing disks, absent when complete
GATE=$RUNDIR/pool-ok                    # exists only when complete: Jellyfin binds it, so
                                        # docker cannot start Jellyfin while a disk is missing
HELD=/var/lib/egos/jellyfin-held        # persistent: "docker stop" survives a reboot
LOCK=$RUNDIR/storage.lock               # one change at a time (page, shell, udev)
MOTD=/etc/motd                          # Cockpit shows it on Overview, SSH at login
DISK_WAIT="${DISK_WAIT:-60}"            # seconds the pool waits for slow (USB) disks at boot
MFS_OPTS="allow_other,use_ino,cache.files=partial,dropcacheonclose=true,category.create=mfs"
MFS_OPTS="$MFS_OPTS,moveonenospc=true,minfreespace=20G,fsname=egospool,statfs_ignore=nc"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo."; exit 1; }

CMD="${1:-add}"
[ $# -gt 0 ] && shift
OPT_JSON=0 OPT_DISK="" OPT_BRANCH="" OPT_CONFIRM="" OPT_YES=0 OPT_IMMICH=0
case "$CMD" in
    job|_job|_pool|_pool-ready|_guard|_autoreattach) ;;    # their arguments belong to the inner command
    *)
    while [ $# -gt 0 ]; do
        case "$1" in
            --json)    OPT_JSON=1 ;;
            --disk)    OPT_DISK="${2:-}"; shift ;;
            --branch)  OPT_BRANCH="${2:-}"; shift ;;
            --confirm) OPT_CONFIRM="${2:-}"; shift ;;
            --yes)     OPT_YES=1 ;;
            --immich)  OPT_IMMICH=1 ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
        shift
    done ;;
esac
for c in lsblk parted mkfs.ext4 blkid findmnt mountpoint mergerfs udevadm setfattr chattr rsync dd cmp timeout wipefs tr flock findfs; do
    command -v "$c" >/dev/null || { echo "Missing command: $c"; exit 1; }
done
mkdir -p "$POOL" "$LOCAL" "$BRANCHES"

# --- fstab: managed lines are recognised by their mount point (field 2).
#     No trailing comments: libmount only parses the 6 fields. ---
#     Every rewrite goes through a temp file: NUL/control bytes are dropped,
#     the result is flushed and validated before it replaces the real fstab
#     (2026-10-24: a non-atomic write left 256 NUL bytes and data1 unmounted).
fstab_commit() {   # $1 = candidate file
    local tmp="$1" out
    sync "$tmp"
    # only parse errors count: an unplugged nofail disk is an "error" for
    # --verify but a legitimate state here. The root line must survive.
    out=$(findmnt --verify --tab-file "$tmp" 2>&1 || true)
    if ! grep -q '^0 parse errors' <<<"$out" \
       || ! awk '$1 !~ /^#/ && $2 == "/" { f = 1 } END { exit !f }' "$tmp"; then
        echo "fstab check failed, $FSTAB NOT changed:"
        printf '%s\n' "$out"
        rm -f "$tmp"; return 1
    fi
    cp -p "$FSTAB" "$FSTAB.egos-prev"
    mv -f "$tmp" "$FSTAB"
    sync "$FSTAB"
}

fstab_del() {
    local tmp="$FSTAB.egos.$$"
    tr -d '\000' < "$FSTAB" \
        | awk -v mp="$1" '$0 ~ /^[[:space:]]*#/ || $2 != mp { print }' > "$tmp"
    fstab_commit "$tmp"
}

fstab_add() {      # $1 = complete fstab line
    local tmp="$FSTAB.egos.$$"
    { tr -d '\000' < "$FSTAB"; printf '%s\n' "$1"; } > "$tmp"
    fstab_commit "$tmp"
}

# --- one change at a time ---------------------------------------------------
# The Cockpit job, a shell command and the udev reattach could otherwise race
# (e.g. "add" formats a disk labelled egos-dataN: udev sees a pool disk appear).
storage_lock() {   # $1 = seconds to wait (0 = fail at once)
    mkdir -p "$RUNDIR"
    exec 9>"$LOCK"
    flock -w "${1:-0}" 9 || { echo "Another storage operation is running: retry when it ends."; exit 1; }
}

# --- disk-missing warning in /etc/motd ---------------------------------------
# Cockpit shows /etc/motd as a banner on the Overview page (the first page after
# login) and sshd prints it at login. Only the block between the markers is ours.
MOTD_BEGIN="*** EgOS STORAGE WARNING"       # our block: from this line...
MOTD_END="*** end of EgOS storage warning ***" # ...to this one, at the top of the file
motd_update() {   # $1 = missing disks (one per line), empty = clear the warning
    [ -f "$MOTD" ] || touch "$MOTD"
    local tmp="$MOTD.egos.$$"
    {
        if [ -n "$1" ]; then
            local names held=""
            names=$(printf '%s\n' "$1" | xargs -rn1 basename | tr '\n' ' ')
            [ -f "$HELD" ] && held=" Jellyfin is stopped until it is back."
            echo "$MOTD_BEGIN: pool disk missing: ${names% } ***"
            echo "Its files are not visible.$held"
            echo "Reconnect the disk: it is reattached automatically."
            echo "Details: Cockpit > Storage pool (or: storage-status)"
            echo "$MOTD_END"
        fi
        awk -v b="$MOTD_BEGIN" -v e="$MOTD_END" \
            'index($0, b) == 1 { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$MOTD"
    } > "$tmp"
    if cmp -s "$tmp" "$MOTD"; then rm -f "$tmp"; else chmod 644 "$tmp"; mv -f "$tmp" "$MOTD"; fi
}

# --- the pool ---------------------------------------------------------------
# NEVER unmount or restart the pool under a running stack: the containers keep
# their bind mounts on the old (dead) FUSE mount and see empty folders until
# they are restarted. Every change is applied hot, via the branch xattr.
pool_mounted() { findmnt -rno TARGET "$POOL" >/dev/null 2>&1; }

configured_disks() {   # data disks in fstab, in data1, data2, ... order
    awk -v b="$BRANCHES/data" '$1 !~ /^#/ && index($2, b) == 1 { print $2 }' "$FSTAB" | sort -V
}

missing_disks() {
    local d
    for d in $(configured_disks); do mountpoint -q "$d" || echo "$d"; done
}

# runtime branch list: data disks present first (reads hit them first), the
# system-disk folder last; it takes new files only while no data disk exists
branch_list() {
    local list="" d any=0
    for d in $(configured_disks); do
        any=1
        mountpoint -q "$d" && list="$list${list:+:}$d=RW"
    done
    if [ "$any" = 1 ]; then list="$list${list:+:}$LOCAL=NC"; else list="$LOCAL=RW"; fi
    echo "$list"
}

update_state() {   # degraded marker for the page and the Jellyfin guard
    mkdir -p "$RUNDIR"
    local m
    m=$(missing_disks)
    if [ -n "$m" ]; then
        printf '%s\n' "$m" > "$DEGRADED"
        rmdir "$GATE" 2>/dev/null || true
    else
        rm -f "$DEGRADED"
        mkdir -p "$GATE"
    fi
    motd_update "$m" || true
}

# The mergerfs daemon must live in egos-pool.service, not in the caller's
# cgroup: run from the Cockpit job (transient unit) it would be killed with
# the job when it ends, and the pool would vanish.
pool_start() {
    systemctl start "$POOL_UNIT" && pool_mounted
}

# HOT update: mergerfs rereads the whole branch list via xattr on the .mergerfs
# control file, without unmounting. Containers notice nothing.
# ("user.mergerfs.branches": srcmounts is read-only in Debian 13's mergerfs)
pool_sync() {
    if ! pool_mounted; then
        echo "Pool not mounted: starting $POOL_UNIT..."
        pool_start || { echo "The pool could not be started (journalctl -u $POOL_UNIT)."; return 1; }
        update_state
        return 0
    fi
    local list
    list=$(branch_list)
    if ! setfattr -n user.mergerfs.branches -v "$list" "$POOL/.mergerfs"; then
        echo "Could not update the pool branches (wanted: $list)."
        return 1
    fi
    update_state
    echo "Pool branches: $list"
}

mfs_branches() {   # $1 = "-/path" (remove one branch)
    setfattr -n user.mergerfs.branches -v "$1" "$POOL/.mergerfs" 2>/dev/null
}

# an empty mount point must never receive files: immutable while unmounted
# (mounting over an immutable directory works; writing into it does not)
guard_dir() { mountpoint -q "$1" || chattr +i "$1" 2>/dev/null || true; }
unguard_dir() { mountpoint -q "$1" || chattr -i "$1" 2>/dev/null || true; }

# --- egos-pool.service: ExecStart (foreground mergerfs) ---------------------
do_pool_run() {
    mkdir -p "$RUNDIR"
    pool_mounted && { echo "$POOL is already mounted."; exit 1; }
    # installs from before 4.2 mounted the pool from fstab
    if awk -v p="$POOL" '$1 !~ /^#/ && $2 == p { f = 1 } END { exit !f }' "$FSTAB"; then
        echo "Removing the old fstab pool line (the pool is now $POOL_UNIT)."
        fstab_del "$POOL"
        systemctl daemon-reload 2>/dev/null || true
    fi
    guard_dir "$POOL"
    local d
    for d in $(configured_disks); do mkdir -p "$d"; guard_dir "$d"; done
    # slow USB disks: wait for them, but never forever
    local end=$((SECONDS + DISK_WAIT))
    while [ -n "$(missing_disks)" ] && [ "$SECONDS" -lt "$end" ]; do sleep 2; done
    update_state
    if [ -s "$DEGRADED" ]; then
        echo "DEGRADED: disk(s) missing after ${DISK_WAIT}s: $(tr '\n' ' ' < "$DEGRADED")"
    fi
    echo "Branches: $(branch_list)"
    exec mergerfs -f -o "$MFS_OPTS" "$(branch_list)" "$POOL"
}

do_pool_ready() {  # ExecStartPost: the unit is "started" only once the pool is there
    local i
    for i in $(seq 1 $((DISK_WAIT + 30))); do
        pool_mounted && return 0
        sleep 1
    done
    echo "mergerfs did not mount $POOL"; return 1
}

# --- Jellyfin off while a disk is missing -----------------------------------
# docker starts its containers by itself at boot, before any unit of ours can
# intervene. So the compose file binds $GATE into Jellyfin (long syntax: docker
# does NOT create a missing source): while a disk is missing the gate does not
# exist and docker cannot start Jellyfin at all. egos-pool-guard.service only
# records that (and stops Jellyfin on stacks deployed before the gate existed).
jellyfin_release() {
    [ -f "$HELD" ] || return 0
    if docker start jellyfin >/dev/null 2>&1; then
        rm -f "$HELD"; echo "Jellyfin started again: all disks are present."
    else
        echo "Jellyfin could not be started (docker start jellyfin)."
    fi
}

do_guard() {
    if [ -s "$DEGRADED" ]; then
        local i
        for i in $(seq 1 60); do
            docker inspect jellyfin >/dev/null 2>&1 && break
            sleep 1
        done
        docker inspect jellyfin >/dev/null 2>&1 || { echo "No Jellyfin container: nothing to hold."; return 0; }
        mkdir -p "$(dirname "$HELD")"
        touch "$HELD"
        if [ "$(docker inspect -f '{{.State.Running}}' jellyfin 2>/dev/null)" = true ]; then
            docker stop jellyfin >/dev/null 2>&1 || true
            echo "Disk(s) missing: Jellyfin stopped (stack without the pool gate)."
        else
            echo "Disk(s) missing: Jellyfin kept off by the pool gate."
        fi
        motd_update "$(cat "$DEGRADED")" || true
    else
        jellyfin_release
    fi
}

# --- reattach: disks that came back (cable, power) --------------------------
do_reattach() {
    local d n=0
    for d in $(missing_disks); do
        n=$((n+1))
        echo "Mounting $d..."
        # plain mount: fails at once if the disk is absent (the mount unit
        # would wait for the device timeout). ext4 is in-kernel: no daemon.
        if mount "$d" 2>/dev/null; then echo "  ok"; else echo "  still missing (disk not detected)"; fi
    done
    [ "$n" -gt 0 ] || echo "No disk missing."
    pool_sync
    local m
    m=$(missing_disks)
    if [ -n "$m" ]; then
        echo
        echo "Still missing: $(echo $m)"
        echo "Check cable and power, then retry. If the disk is gone for good: storage-remove."
        exit 3
    fi
    jellyfin_release
    echo "All disks present."
}

# --- automatic reattach -----------------------------------------------------
# 90-egos-reattach.rules: a partition labelled egos-data* appears -> udev starts
# egos-reattach.service -> here. Nothing happens unless the pool is running and
# a configured disk that was missing is now detected (at boot every present
# disk is "added" too: egos-pool.service handles those).
do_autoreattach() {
    systemctl is-active --quiet "$POOL_UNIT" || { echo "Pool not running: nothing to do."; return 0; }
    udevadm settle --timeout=30 || true     # several disks plugged together: one pass
    storage_lock 900                        # wait for a running add/remove/drain
    local d src back="" stale=0
    for d in $(missing_disks); do
        src=$(awk -v m="$d" '$1 !~ /^#/ && $2 == m { print $1; exit }' "$FSTAB")
        [ -n "$src" ] && findfs "$src" >/dev/null 2>&1 && back="$back $d"
    done
    # mounted by someone else meanwhile, but the pool still marked degraded
    [ -s "$DEGRADED" ] && [ -z "$(missing_disks)" ] && stale=1
    if [ -z "$back" ] && [ "$stale" = 0 ]; then
        echo "No missing pool disk came back: nothing to do."; return 0
    fi
    echo "Pool disk plugged back in:${back:- (already mounted)}"
    mkdir -p "$(dirname "$JOBLOG")"
    echo "== $(date '+%F %T') egos-storage reattach (automatic: disk plugged back in)" > "$JOBLOG"
    local rc=0
    ( do_reattach ) < /dev/null >> "$JOBLOG" 2>&1 || rc=$?
    echo "== END rc=$rc $(date '+%F %T')" >> "$JOBLOG"
    cat "$JOBLOG"                           # also in the journal
    return 0
}

# --- Moves data onto the pool and rewrites the stack's .env ----------------
env_get() { grep -E "^$1=" "$ENVF" | tail -1 | cut -d= -f2-; }

move_tree() {   # $1 = .env key   $2 = destination on the pool
    local key="$1" dest="$2" cur need avail
    cur=$(env_get "$key")
    [ -n "$cur" ] || { echo "  $key missing from .env, skipping"; return 0; }
    if [ "$cur" = "$dest" ]; then echo "  $key already on the pool"; return 0; fi
    [ -d "$cur" ] || { echo "  $cur does not exist, skipping"; return 0; }

    need=$(du -sk "$cur" | cut -f1)
    avail=$(df -Pk "$POOL" | tail -1 | awk '{print $4}')
    if [ "$avail" -le $((need + 1048576)) ]; then
        echo "  not enough space on the pool for $cur ($((need/1024)) MiB)"; return 1
    fi

    echo "  copying $cur -> $dest"
    mkdir -p "$dest"
    if ! rsync -aHAX --numeric-ids --info=progress2 --human-readable "$cur"/ "$dest"/; then
        echo "  COPY FAILED: source intact, .env unchanged"; return 1
    fi
    # check 1: a second dry-run pass must have nothing to transfer
    local pending
    if ! pending=$(rsync -aHAXn --itemize-changes "$cur"/ "$dest"/); then
        echo "  CHECK COULD NOT RUN: source intact, .env unchanged"; return 1
    fi
    if [ -n "$(printf '%s\n' "$pending" | grep -v '^\.' | grep -v '^$')" ]; then
        echo "  CHECK FAILED: source intact, .env unchanged"; return 1
    fi
    # check 2: same number of files at source and destination
    local nsrc ndst
    nsrc=$(find "$cur" -type f | wc -l); ndst=$(find "$dest" -type f | wc -l)
    if [ "$nsrc" -ne "$ndst" ]; then
        echo "  CHECK FAILED ($nsrc files vs $ndst): source intact"; return 1
    fi
    mv "$cur" "$cur.pre-pool"
    sed -i "s|^$key=.*|$key=$dest|" "$ENVF"
    echo "  ok: original kept in $cur.pre-pool"
}

do_link() {
    pool_mounted || { echo "Pool not mounted: systemctl status $POOL_UNIT"; exit 1; }
    local U H
    U=$(python3 -c "import json;print(json.load(open('/var/lib/setup-data.json'))['user'])" 2>/dev/null || true)
    [ -n "$U" ] && id "$U" >/dev/null 2>&1 || { echo "Setup user cannot be determined."; exit 1; }
    H="/home/$U"
    ENVF="$H/app/repos/.env"
    [ -f "$ENVF" ] || { echo "$ENVF not found: the stack has not been configured yet."; exit 1; }

    echo "Moves the stack data onto the pool. Immich's Postgres stays on the NVMe:"
    echo "a database on a USB disk is the fastest way to corrupt it."
    echo
    local DO_IMMICH=n go=n gocopy=s
    if [ "$OPT_YES" = 1 ]; then
        [ "$OPT_IMMICH" = 1 ] && DO_IMMICH=y
        go=y
        echo "Immich originals: $([ "$DO_IMMICH" = y ] && echo moved || echo left in place)"
    else
        read -r -p "Also move the Immich originals (UPLOAD_LOCATION)? [y/N] " DO_IMMICH
        echo
        echo "The stack is stopped during the copy and restarted at the end."
        read -r -p "Proceed? [y/N] " go
    fi
    case "${go:-n}" in s|S|si|SI|y|Y) ;; *) echo "Cancelled."; exit 0 ;; esac

    cp "$ENVF" "$ENVF.bak.$(date +%Y%m%d%H%M%S)"
    ( cd "$H/app/repos" && docker compose down ) || true

    echo
    [ "$OPT_YES" = 1 ] || read -r -p "Docker stack stopped? Continue with the copy? [Y/n] " gocopy
    case "${gocopy:-s}" in
        n|N|no|NO) echo "Copy cancelled. The stack is stopped: restart it with"
                   echo "  cd $H/app/repos && docker compose up -d"
                   exit 0 ;;
    esac
    echo

    local rc=0
    move_tree JELLYFIN_MEDIA_LOCATION "$POOL/media" || rc=1
    case "${DO_IMMICH:-n}" in
        s|S|si|SI|y|Y) move_tree UPLOAD_LOCATION "$POOL/immich/upload" || rc=1 ;;
    esac

    chown -R "$U:$U" "$POOL" 2>/dev/null || true

    # the [media] share follows the media folder (prod had to be edited by hand)
    local MEDIA
    MEDIA=$(env_get JELLYFIN_MEDIA_LOCATION)
    if [ -n "$MEDIA" ] && [ -f /etc/samba/smb.conf ]; then
        sed -i "/^\[media\]/,/^\[/ s|^\([[:space:]]*path[[:space:]]*=\).*|\1 $MEDIA|" /etc/samba/smb.conf
        systemctl restart smbd 2>/dev/null || true
        systemctl restart wsdd2 2>/dev/null || true
        echo "Samba share [media] -> $MEDIA"
    fi

    ( cd "$H/app/repos" && docker compose up -d )

    echo
    if [ "$rc" -eq 0 ]; then
        echo "Link completed. Current paths:"
    else
        echo "Completed with errors: review the messages above. Current paths:"
    fi
    grep -E '^(JELLYFIN_MEDIA_LOCATION|UPLOAD_LOCATION|DB_DATA_LOCATION)=' "$ENVF"
    echo
    echo "The .pre-pool directories stay on the NVMe until you delete them by hand."
}

do_status() {
    echo "== Branches =="
    findmnt -rno TARGET,SOURCE,SIZE,AVAIL --target "$BRANCHES" 2>/dev/null || true
    local d
    for d in "$BRANCHES"/data*; do
        [ -d "$d" ] || continue
        if findmnt -rno SOURCE "$d" >/dev/null 2>&1; then
            printf '%-28s %s\n' "$d" "$(findmnt -rno SOURCE,SIZE,AVAIL "$d")"
        else
            printf '%-28s NOT MOUNTED\n' "$d"
        fi
    done
    printf '%-28s %s (system disk)\n' "$LOCAL" "$(du -sh "$LOCAL" 2>/dev/null | cut -f1)"
    echo
    echo "== Pool =="
    if pool_mounted; then
        df -h "$POOL" | tail -1
        echo "Branches: $(getfattr --only-values -n user.mergerfs.branches "$POOL/.mergerfs" 2>/dev/null)"
        [ -s "$DEGRADED" ] && echo "DEGRADED, missing: $(tr '\n' ' ' < "$DEGRADED")"
        [ -f "$HELD" ] && echo "Jellyfin is stopped until the missing disk returns (storage-reattach)."
    else
        echo "$POOL not mounted (systemctl status $POOL_UNIT)"
    fi
    return 0
}

# --- Checks that the disk really keeps what it writes ---------------------
# A fake-capacity device accepts writes, reports success and
# returns different data: mkfs succeeds, ext4 gets corrupted later.
# The test checks three things: integrity of the data read back, no new
# ext4 errors in the kernel, minimum acceptable speed.
VERIFY_MB="${VERIFY_MB:-128}"
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-180}"

verify_disk() {
    local mp="$1"
    local pat="/var/tmp/.egos-verify.$$" dst="$mp/.egos-verify.bin"
    local err0 err1 t0 secs rate
    echo "Integrity check on ${VERIFY_MB} MiB (max ${VERIFY_TIMEOUT}s)..."
    err0=$(dmesg 2>/dev/null | grep -c 'EXT4-fs error' || true)

    dd if=/dev/urandom of="$pat" bs=1M count="$VERIFY_MB" status=none
    t0=$SECONDS
    if ! timeout "$VERIFY_TIMEOUT" dd if="$pat" of="$dst" bs=1M conv=fdatasync status=none; then
        rm -f "$pat" "$dst"
        echo "  FAILED: writing ${VERIFY_MB} MiB did not finish in ${VERIFY_TIMEOUT}s."
        echo "  The disk is unusable at this speed."
        return 1
    fi
    secs=$(( SECONDS - t0 )); [ "$secs" -gt 0 ] || secs=1
    rate=$(( VERIFY_MB / secs ))
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    if ! cmp -s "$pat" "$dst"; then
        rm -f "$pat" "$dst"
        echo "  FAILED: the data read back does not match what was written."
        echo "  Fake-capacity or faulty device: do NOT use it."
        return 1
    fi
    rm -f "$pat" "$dst"

    err1=$(dmesg 2>/dev/null | grep -c 'EXT4-fs error' || true)
    if [ "$err1" -gt "$err0" ]; then
        echo "  FAILED: the kernel logged $((err1-err0)) EXT4 errors during the test."
        echo "  See: dmesg -T | grep EXT4"
        return 1
    fi
    echo "  ok: data intact, no ext4 errors, about ${rate} MB/s write"
    return 0
}

# --- Retiring a branch, TO BE RUN WITH THE DISK STILL ATTACHED ------------
# Formats nothing: detaches the branch from the pool, flushes pending writes,
# unmounts, cleans fstab, removes the device from the kernel and only then
# says the disk can be unplugged. Also works on an already unplugged disk,
# but in that case writes not yet on the platter are lost.
do_remove() {
    local -a MPS=()
    local d src n=0
    echo "Currently defined branches:"
    for d in "$BRANCHES"/data*; do
        [ -d "$d" ] || continue
        n=$((n+1)); MPS+=("$d")
        if src=$(findmnt -rno SOURCE "$d" 2>/dev/null); then
            printf ' %2d) %-26s %-12s %s\n' "$n" "$d" "$src" \
                   "$(findmnt -rno SIZE,USED,AVAIL "$d" 2>/dev/null)"
        else
            printf ' %2d) %-26s NOT MOUNTED\n' "$n" "$d"
        fi
    done
    [ "$n" -gt 0 ] || { echo "No branch to remove."; exit 0; }

    echo
    local MP=""
    if [ -n "$OPT_BRANCH" ]; then
        for d in "${MPS[@]}"; do [ "$(basename "$d")" = "$OPT_BRANCH" ] && MP="$d"; done
        [ -n "$MP" ] || { echo "Branch $OPT_BRANCH not found."; exit 1; }
    else
        read -r -p "Number of the branch to remove (Enter to cancel): " choice
        [ -n "${choice:-}" ] || { echo "Cancelled."; exit 0; }
        case "$choice" in ''|*[!0-9]*) echo "Invalid choice."; exit 1;; esac
        [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ] || { echo "Choice out of range."; exit 1; }
        MP="${MPS[$((choice-1))]}"
    fi
    local NAME SRC ATTACHED=0
    NAME=$(basename "$MP")
    SRC=$(findmnt -rno SOURCE "$MP" 2>/dev/null || true)
    if [ -n "$SRC" ] && [ -b "$SRC" ]; then
        ATTACHED=1
        echo
        echo "Disk attached: $SRC — the retirement will be complete and safe."
    else
        echo
        echo "Disk NOT attached or not mounted: cleaning up the configuration only."
    fi

    # how many data disks would remain?
    local left=0 x
    for x in "$BRANCHES"/data*; do [ -d "$x" ] && [ "$x" != "$MP" ] && left=$((left+1)); done
    if [ "$left" -eq 0 ]; then
        echo
        echo "This is the LAST data disk: the pool stays, new files go to the system"
        echo "disk again ($LOCAL)."
    fi

    echo
    echo "The files on this disk will disappear from the pool. The disk is NOT formatted."
    if [ -n "$OPT_BRANCH" ]; then confirm="$OPT_CONFIRM"
    else read -r -p "To confirm, type exactly $NAME : " confirm; fi
    [ "$confirm" = "$NAME" ] || { echo "Confirmation does not match. Cancelled."; exit 1; }

    # 1. hot detach, if the pool is mounted and still uses it
    if pool_mounted && getfattr --only-values -n user.mergerfs.branches "$POOL/.mergerfs" 2>/dev/null \
            | tr ':' '\n' | cut -d= -f1 | grep -qx "$MP"; then
        if mfs_branches "-$MP"; then
            echo "Branch hot-detached from the pool."
        else
            echo "Hot detach FAILED: nothing changed. Retry, or reboot and retry."
            exit 1
        fi
    fi

    # 2. flush pending writes: without this, unplugging the disk
    #    means losing what is still in cache
    echo "Flushing pending writes (sync)..."
    sync

    # 3. unmount. With the disk attached it must succeed CLEANLY:
    #    a lazy unmount would leave pending writes on a disk the
    #    user is about to unplug.
    if [ "$ATTACHED" = 1 ]; then
        if ! umount "$MP" 2>/dev/null; then
            echo
            echo "UNMOUNT REFUSED: something is keeping $MP open"
            if command -v lsof >/dev/null; then lsof +D "$MP" 2>/dev/null | head -20; fi
            echo
            echo "Do NOT unplug the disk. Close the processes (usually the stack:"
            echo "cd ~/app/repos && docker compose down) and repeat storage-remove."
            # puts the branch back into the pool: state returns to what it was
            pool_sync >/dev/null && echo "Branch put back into the pool: nothing changed."
            exit 1
        fi
        echo "Unmounted: $MP"
    else
        if findmnt -rno TARGET "$MP" >/dev/null 2>&1; then
            umount -f "$MP" 2>/dev/null || umount -l "$MP" 2>/dev/null || true
        fi
    fi

    # 4. fstab and branch directory
    fstab_del "$MP"
    systemctl daemon-reload 2>/dev/null || true
    if [ -n "$(ls -A "$MP" 2>/dev/null)" ]; then
        echo "The directory $MP is NOT empty after unmounting:"
        du -sh "$MP"
        echo "These are files that ended up on the system disk: review and remove them by hand."
    elif ! mountpoint -q "$MP"; then
        unguard_dir "$MP"
        rmdir "$MP" 2>/dev/null || true
    fi

    # 5. pool: branch list recomputed (local takes new files again if no disk is left)
    pool_sync || true
    if [ -z "$(missing_disks)" ]; then jellyfin_release; fi

    # 6. remove the device from the kernel, then clear it for unplugging
    if [ "$ATTACHED" = 1 ]; then
        local DISK
        DISK=$(lsblk -no PKNAME "$SRC" 2>/dev/null | head -1 || true)
        sync
        if [ -n "$DISK" ] && [ -e "/sys/block/$DISK/device/delete" ]; then
            echo 1 > "/sys/block/$DISK/device/delete" 2>/dev/null || true
            sleep 2
            if [ -b "/dev/$DISK" ]; then
                echo "Note: /dev/$DISK is still present; wait a few seconds."
            else
                echo "Device /dev/$DISK removed from the kernel."
            fi
        fi
        echo
        echo "============================================================"
        echo "  YOU CAN NOW SAFELY UNPLUG THE DISK ($NAME)"
        echo "============================================================"
    else
        echo
        echo "Configuration cleaned up. The disk was already unplugged."
    fi

    echo
    echo "Removed: $MP"
    do_status
}

# --- disks that may be added: whole disks, not the system disk ------------
sys_disk() {
    local ROOTSRC PK
    ROOTSRC=$(findmnt -no SOURCE /)
    PK=$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null | head -1 || true)
    [ -n "$PK" ] && echo "/dev/$PK"
}

candidates() {   # $1 = system disk. TSV: name size tran model mountpoints
    # lsblk JSON: empty TRAN/MODEL fields do not shift the columns
    python3 - "$1" <<'PY'
import json, re, subprocess, sys
sysdisk = sys.argv[1]
out = subprocess.run(["lsblk", "-J", "-p", "-o", "NAME,TYPE,SIZE,TRAN,MODEL,MOUNTPOINTS"],
                     capture_output=True, text=True, check=True).stdout
def mounts(n):
    m = [x for x in (n.get("mountpoints") or []) if x]
    for c in n.get("children") or []:
        m += mounts(c)
    return m
for n in sorted(json.loads(out)["blockdevices"], key=lambda d: d["name"]):
    name = n["name"]
    if n.get("type") != "disk" or name == sysdisk:
        continue
    # zram/loop: virtual; fd: legacy floppy controller found on x86 boards and VMs
    if name.startswith(("/dev/zram", "/dev/loop", "/dev/fd")):
        continue
    # eMMC hardware boot areas / RPMB show up as "disks" but are not usable
    if re.match(r"/dev/mmcblk\d+(boot\d+|rpmb)$", name):
        continue
    f = [name, n.get("size") or "-", n.get("tran") or "-",
         (n.get("model") or "-").strip(), " ".join(mounts(n))]
    print("\t".join(x.replace("\t", " ") for x in f))
PY
}

do_disks_json() {
    local SYSDISK
    SYSDISK=$(sys_disk) || true
    [ -n "$SYSDISK" ] || { echo "System disk cannot be determined: aborting."; exit 1; }
    candidates "$SYSDISK" | python3 -c '
import json, sys
keys = ["name", "size", "tran", "model", "mountpoints"]
print(json.dumps([dict(zip(keys, l.rstrip("\n").split("\t"))) for l in sys.stdin if l.strip()]))'
}

do_add() {
    local SYSDISK
    SYSDISK=$(sys_disk) || true
    [ -n "$SYSDISK" ] || { echo "System disk cannot be determined from $(findmnt -no SOURCE /): aborting."; exit 1; }

    echo "System disk (excluded): $SYSDISK"
    echo
    local -a DEVS=()
    local n=0 name size tran model mnt DEV=""
    while IFS=$'\t' read -r name size tran model mnt; do
        n=$((n+1)); DEVS+=("$name")
        [ -n "$OPT_DISK" ] && continue
        [ "$n" -eq 1 ] && echo "Available disks:"
        printf ' %2d) %-14s %-8s %-6s %-24s %s\n' "$n" "$name" "$size" "$tran" "$model" \
               "${mnt:+[in use: $mnt]}"
    done < <(candidates "$SYSDISK")

    [ "$n" -gt 0 ] || { echo "No additional disk detected."; exit 1; }
    if [ -n "$OPT_DISK" ]; then
        local x
        for x in "${DEVS[@]}"; do [ "$x" = "$OPT_DISK" ] && DEV="$x"; done
        [ -n "$DEV" ] || { echo "$OPT_DISK is not a disk that can be added."; exit 1; }
    else
        echo
        read -r -p "Number of the disk to add (Enter to cancel): " choice
        [ -n "${choice:-}" ] || { echo "Cancelled."; exit 0; }
        case "$choice" in ''|*[!0-9]*) echo "Invalid choice."; exit 1;; esac
        [ "$choice" -ge 1 ] && [ "$choice" -le "$n" ] || { echo "Choice out of range."; exit 1; }
        DEV="${DEVS[$((choice-1))]}"
    fi

    echo
    echo "Current content of $DEV:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DEV"
    if lsblk -nro MOUNTPOINTS "$DEV" | grep -q '[^[:space:]]'; then
        echo
        echo "WARNING: $DEV has mounted partitions. Unmount them before proceeding."
        exit 1
    fi
    echo
    echo "This operation ERASES all the content of $DEV."
    if [ -n "$OPT_DISK" ]; then confirm="$OPT_CONFIRM"
    else read -r -p "To confirm, type exactly $DEV : " confirm; fi
    [ "$confirm" = "$DEV" ] || { echo "Confirmation does not match. Cancelled."; exit 1; }

    # --- free label and mount point: never reuse the name of a disk that is
    #     configured but missing right now (its fstab line would be replaced) ---
    local i=1
    while configured_disks | grep -qx "$BRANCHES/data$i" || mountpoint -q "$BRANCHES/data$i" \
          || [ -n "$(ls -A "$BRANCHES/data$i" 2>/dev/null)" ]; do
        i=$((i+1))
    done
    local LABEL="egos-data$i" MP="$BRANCHES/data$i"

    echo "GPT partitioning on $DEV..."
    wipefs -a "$DEV" >/dev/null
    parted -s "$DEV" mklabel gpt
    parted -s -a optimal "$DEV" mkpart "$LABEL" ext4 0% 100%
    udevadm settle
    sleep 2

    local PART
    PART=$(lsblk -lnpo NAME,TYPE "$DEV" | awk '$2=="part"{print $1; exit}')
    [ -n "$PART" ] || { echo "No partition detected on $DEV."; exit 1; }

    echo "Formatting $PART as ext4 (may take a few minutes)..."
    mkfs.ext4 -F -L "$LABEL" -m 1 "$PART" >/dev/null

    local UUID
    UUID=$(blkid -s UUID -o value "$PART")
    [ -n "$UUID" ] || { echo "UUID not readable."; exit 1; }

    mkdir -p "$MP"
    guard_dir "$MP"
    fstab_del "$MP"
    fstab_add "$(printf 'UUID=%s  %s  ext4  defaults,nofail,noatime,x-systemd.device-timeout=%s  0 2' \
           "$UUID" "$MP" "$DISK_WAIT")"
    systemctl daemon-reload 2>/dev/null || true
    mount "$MP"

    if ! verify_disk "$MP"; then
        echo
        echo "Aborting: the disk does NOT join the pool."
        umount "$MP" 2>/dev/null || umount -l "$MP" 2>/dev/null || true
        fstab_del "$MP"
        systemctl daemon-reload 2>/dev/null || true
        unguard_dir "$MP"
        rmdir "$MP" 2>/dev/null || true
        exit 1
    fi

    # owner = user created by setup, so Samba and the services can write
    local U=""
    [ -f /var/lib/setup-data.json ] && \
        U=$(python3 -c "import json;print(json.load(open('/var/lib/setup-data.json'))['user'])" 2>/dev/null || true)
    if [ -n "$U" ] && id "$U" >/dev/null 2>&1; then
        chown "$U:$U" "$MP"
    fi

    local IN_POOL=1
    if pool_sync; then
        echo "Disk hot-attached: no service restart."
    else
        IN_POOL=0
    fi

    echo
    echo "Done: $DEV -> $MP (UUID $UUID), pool $POOL"
    do_status
    echo
    if [ "$IN_POOL" = 0 ]; then
        echo "WARNING: $MP is formatted and mounted but NOT yet part of the pool."
        echo "Retry with storage-reattach; if it still fails, reboot."
        exit 2
    fi
    echo "New files now go to the data disks. Files already on the system disk stay"
    echo "visible; to move them as well: storage-drain"
}

# --- drain: files from the system-disk branch to the data disks -------------
# Same relative path on the pool, so no service notices. rsync writes to a
# temporary name and renames at the end: nobody ever reads a half-copied file.
# Files modified in the last 10 minutes are left alone (may still be written).
# The folder tree and Immich's ".immich" marker files always stay on the system
# disk: with every data disk removed the stack still finds its folders (Immich
# refuses to start without the markers).
do_drain() {
    local -a DISKS=()
    local d
    for d in $(configured_disks); do mountpoint -q "$d" && DISKS+=("$d"); done
    [ "${#DISKS[@]}" -gt 0 ] || { echo "No data disk mounted: nothing to move the files to."; exit 1; }
    pool_mounted || { echo "Pool not mounted."; exit 1; }

    local plan="$RUNDIR/drain"
    rm -rf "$plan"; mkdir -p "$plan"
    # greedy plan: biggest files first, each on the disk with the most room left
    # (keeping the pool's 20G minfreespace on every disk)
    python3 - "$LOCAL" "$plan" "${DISKS[@]}" <<'PY'
import os, sys, time
local, plan, disks = sys.argv[1], sys.argv[2], sys.argv[3:]
reserve = 20 * 1024**3
room = {}
for d in disks:
    st = os.statvfs(d)
    room[d] = st.f_bavail * st.f_frsize - reserve
cutoff = time.time() - 600
files, recent = [], 0
for root, dirs, names in os.walk(local):
    for n in names:
        if n == ".immich":
            continue
        p = os.path.join(root, n)
        try:
            st = os.lstat(p)
        except OSError:
            continue
        if st.st_mtime > cutoff:
            recent += 1
            continue
        files.append((st.st_size, os.path.relpath(p, local)))
files.sort(reverse=True)
lists = {d: [] for d in disks}
total = {d: 0 for d in disks}
left = []
for size, rel in files:
    d = max(room, key=room.get)
    if room[d] < size:
        left.append(rel)
        continue
    room[d] -= size
    lists[d].append(rel)
    total[d] += size
for i, d in enumerate(disks):
    with open(os.path.join(plan, "%d.list" % i), "wb") as fh:
        fh.write(b"".join(r.encode() + b"\0" for r in lists[d]))
    with open(os.path.join(plan, "%d.disk" % i), "w") as fh:
        fh.write(d)
    print("  %-26s %6d files, %.1f GB" % (d, len(lists[d]), total[d] / 1e9))
print("  %d files to move; %d recent (left for now); %d do NOT fit" % (
    sum(len(v) for v in lists.values()), recent, len(left)))
for rel in left[:20]:
    print("    no room: " + rel)
PY
    local rc=0 f
    for f in "$plan"/*.list; do
        [ -s "$f" ] || continue
        d=$(cat "${f%.list}.disk")
        echo "Moving to $d..."
        rsync -aHAX --numeric-ids --from0 --files-from="$f" --remove-source-files \
              --info=progress2 --human-readable "$LOCAL"/ "$d"/ || rc=1
    done
    rm -rf "$plan"
    echo
    local n
    n=$(find "$LOCAL" -type f ! -name .immich | wc -l)
    echo "Files still on the system disk: $n ($(du -sh "$LOCAL" | cut -f1))"
    [ "$rc" -eq 0 ] || { echo "Some files could not be moved: see the messages above. Run it again to retry."; exit 1; }
}

# --- machine-readable state for the Cockpit page ---------------------------
do_status_json() {
    python3 - "$POOL" "$BRANCHES" "$FSTAB" "$JOBUNIT" "$JOBLOG" "$(sys_disk || true)" \
              "$LOCAL" "$DEGRADED" "$HELD" "$POOL_UNIT" <<'PY'
import json, os, re, subprocess, sys
pool, branches, fstab, unit, joblog, sysdisk, local, degraded, held, pool_unit = sys.argv[1:11]

def run(*a):
    r = subprocess.run(a, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""

mounts = {}
def walk(fss):
    for f in fss:
        mounts[f["target"]] = f
        walk(f.get("children") or [])
walk(json.loads(run("findmnt", "-J", "-o", "TARGET,SOURCE,FSTYPE") or '{"filesystems": []}')["filesystems"])

def space(p):
    st = os.statvfs(p)
    return {"size": st.f_blocks * st.f_frsize, "avail": st.f_bavail * st.f_frsize,
            "used": (st.f_blocks - st.f_bfree) * st.f_frsize}

def num(p):
    m = re.search(r"(\d+)$", p)
    return int(m.group(1)) if m else 0

in_fstab = {}
with open(fstab, errors="replace") as fh:
    for line in fh:
        f = line.split()
        if len(f) >= 2 and not f[0].startswith("#") and f[1].startswith(branches + "/data"):
            in_fstab[f[1]] = f[0]
paths = set(in_fstab)
if os.path.isdir(branches):
    paths |= {os.path.join(branches, d) for d in os.listdir(branches)
              if d.startswith("data") and os.path.isdir(os.path.join(branches, d))}

out = {"pool": {"path": pool, "mounted": False}, "branches": [], "system_disk": sysdisk}
for mp in sorted(paths, key=num):
    m = mounts.get(mp)
    b = {"name": os.path.basename(mp), "path": mp, "in_fstab": mp in in_fstab,
         "fstab_source": in_fstab.get(mp, ""), "mounted": bool(m)}
    if m:
        b["source"] = m["source"]
        b["label"] = run("lsblk", "-no", "LABEL", m["source"])
        b.update(space(mp))
    else:
        # files under an unmounted branch were written to the SYSTEM disk
        b["stray"] = os.path.isdir(mp) and bool(os.listdir(mp))
    out["branches"].append(b)

pm = mounts.get(pool)
active = None
modes = {}
if pm and pm.get("fstype", "").startswith("fuse"):
    out["pool"]["mounted"] = True
    out["pool"].update(space(pool))
    for attr in ("user.mergerfs.branches", "user.mergerfs.srcmounts"):
        try:
            raw = os.getxattr(os.path.join(pool, ".mergerfs"), attr).decode()
            for x in raw.split(":"):
                if x:
                    p, _, m = x.partition("=")
                    modes[p] = (m.split(",")[0] or "RW")
            active = set(modes)
            break
        except OSError:
            pass
for b in out["branches"]:
    b["in_pool"] = bool(active and b["path"] in active)
out["pool"]["service"] = run("systemctl", "is-active", pool_unit) or "inactive"
try:
    out["pool"]["missing"] = [os.path.basename(x) for x in open(degraded).read().split()]
except OSError:
    out["pool"]["missing"] = []
out["pool"]["degraded"] = bool(out["pool"]["missing"])

# system-disk branch: is anything (a file) still there?
def first_file(top):
    for root, dirs, names in os.walk(top):
        if any(n != ".immich" for n in names):
            return True
    return False
lst = {"path": local, "in_pool": bool(active and local in active), "mode": modes.get(local, "")}
lst["has_files"] = os.path.isdir(local) and first_file(local)
lst["system_free"] = space(local)["avail"] if os.path.isdir(local) else 0
out["local"] = lst
out["jellyfin_held"] = os.path.exists(held)

stack = {}
try:
    user = json.load(open("/var/lib/setup-data.json"))["user"]
    envf = "/home/%s/app/repos/.env" % user
    stack["env"] = envf
    with open(envf) as fh:
        for line in fh:
            k, _, v = line.strip().partition("=")
            if k in ("JELLYFIN_MEDIA_LOCATION", "UPLOAD_LOCATION", "DB_DATA_LOCATION"):
                stack[k] = v
except (OSError, KeyError, ValueError):
    pass
out["stack"] = stack

samba = ""
try:
    sect = ""
    for line in open("/etc/samba/smb.conf", errors="replace"):
        t = line.strip()
        if t.startswith("["):
            sect = t
        elif sect == "[media]" and t.split("=")[0].strip() == "path":
            samba = t.split("=", 1)[1].strip()
except OSError:
    pass
out["samba_media_path"] = samba

state = run("systemctl", "is-active", unit) or "inactive"
out["job"] = {"unit": unit, "state": state, "running": state in ("active", "activating"),
              "log": joblog, "has_log": os.path.exists(joblog)}
print(json.dumps(out))
PY
}

# --- long operations as a systemd unit: they survive a closed browser tab ---
do_start_job() {   # $@ = a non-interactive egos-storage command line
    case "${1:-}" in add|remove|link|remount|reattach|drain) ;;
        *) echo "Usage: egos-storage job add|remove|reattach|drain|link <options>"; exit 1 ;; esac
    if systemctl is-active --quiet "$JOBUNIT"; then
        echo "A storage job is already running ($JOBUNIT)."; exit 1
    fi
    systemctl reset-failed "$JOBUNIT" 2>/dev/null || true
    # HOME: docker compose (link) needs it, a transient unit has none
    systemd-run --unit="$JOBUNIT" --collect --quiet --setenv=HOME=/root \
        --description="EgOS storage: $*" /usr/local/sbin/egos-storage _job "$@"
    echo "Started: $JOBUNIT (log: $JOBLOG)"
}

do_run_job() {     # inside the unit: everything goes to the log, plus an end marker
    mkdir -p "$(dirname "$JOBLOG")"
    echo "== $(date '+%F %T') egos-storage $*" > "$JOBLOG"
    local rc=0
    /usr/local/sbin/egos-storage "$@" < /dev/null >> "$JOBLOG" 2>&1 || rc=$?
    echo "== END rc=$rc $(date '+%F %T')" >> "$JOBLOG"
    return "$rc"
}

case "$CMD" in
    add|link|remove|reattach|remount|drain) storage_lock 0 ;;
esac
case "$CMD" in
    add)     do_add ;;
    status)  if [ "$OPT_JSON" = 1 ]; then do_status_json; else do_status; fi ;;
    disks)   do_disks_json ;;
    link)    do_link ;;
    remove)  do_remove ;;
    reattach|remount) do_reattach ;;
    drain)   do_drain ;;
    job)     do_start_job "$@" ;;
    _job)    do_run_job "$@" ;;
    _pool)   do_pool_run ;;
    _pool-ready) do_pool_ready ;;
    _guard)  do_guard ;;
    _autoreattach) do_autoreattach ;;
    *) echo "Usage: egos-storage [add|status|disks|remove|reattach|drain|link|job] [options]"; exit 1 ;;
esac
STORAGE_EOF
chmod +x "$OVL"/usr/local/sbin/egos-storage

cat > "$OVL"/etc/profile.d/egos-storage.sh <<'ALIAS_EOF'
alias storage-add='sudo /usr/local/sbin/egos-storage add'
alias storage-status='sudo /usr/local/sbin/egos-storage status'
alias storage-link='sudo /usr/local/sbin/egos-storage link'
alias storage-remove='sudo /usr/local/sbin/egos-storage remove'
alias storage-reattach='sudo /usr/local/sbin/egos-storage reattach'
alias storage-remount='sudo /usr/local/sbin/egos-storage reattach'
alias storage-drain='sudo /usr/local/sbin/egos-storage drain'
ALIAS_EOF

# --- Storage pool service (4.2): the pool exists from the 1st boot ----------
#     mergerfs over /srv/egos/local (system disk) + the data disks; branch list
#     computed at start by egos-storage (disks present first, local last).
#     A disk missing after 60s -> pool mounted "degraded", Jellyfin held.
cat > "$OVL"/etc/systemd/system/egos-pool.service <<'POOLSVC_EOF'
[Unit]
Description=EgOS storage pool (mergerfs on /srv/egos/pool)
After=local-fs.target
Before=docker.service smbd.service egos-pool-guard.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/egos-storage _pool
ExecStartPost=/usr/local/sbin/egos-storage _pool-ready
ExecStop=-/bin/umount /srv/egos/pool
# 60s wait for slow USB disks + mount
TimeoutStartSec=150
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
POOLSVC_EOF

cat > "$OVL"/etc/systemd/system/egos-pool-guard.service <<'POOLGUARD_EOF'
[Unit]
Description=EgOS: keep Jellyfin stopped while a pool disk is missing
After=docker.service egos-pool.service docker-compose-startup.service
Wants=egos-pool.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/egos-storage _guard

[Install]
WantedBy=multi-user.target
POOLGUARD_EOF

# automatic reattach (4.2.1): udev -> egos-reattach.service -> egos-storage
# (udev must not run long jobs itself: RUN+= is killed after a few seconds)
cat > "$OVL"/etc/systemd/system/egos-reattach.service <<'REATTACH_EOF'
[Unit]
Description=EgOS: reattach a pool disk that was plugged back in
After=egos-pool.service docker.service egos-pool-guard.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/egos-storage _autoreattach
TimeoutStartSec=1200
REATTACH_EOF

mkdir -p "$OVL"/etc/udev/rules.d
cat > "$OVL"/etc/udev/rules.d/90-egos-reattach.rules <<'UDEVR_EOF'
# EgOS: a partition labelled egos-data* (made by egos-storage add) appears ->
# reattach it to the pool if it was missing (egos-storage _autoreattach decides)
ACTION=="add", SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{ID_FS_LABEL}=="egos-data*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="egos-reattach.service"
UDEVR_EOF

# /etc/motd without Debian's boilerplate: egos-storage writes only its disk-missing
# warning there, so Cockpit's Overview shows a banner only when there is a problem
: > "$OVL"/etc/motd

# docker (containers restarted by the daemon itself) and Samba only after the pool
for u in docker smbd; do
    mkdir -p "$OVL"/etc/systemd/system/$u.service.d
    printf '[Unit]\nWants=egos-pool.service\nAfter=egos-pool.service\n' \
        > "$OVL"/etc/systemd/system/$u.service.d/10-egos-pool.conf
done

# --- Cockpit page "Storage pool": front end for egos-storage ---------------
#     Plain HTML/JS + base1/cockpit.js (Cockpit 337 ships no PatternFly in base1).
#     Reads `egos-storage status/disks --json`, starts changes as
#     `egos-storage job ...` (systemd unit: a closed browser tab stops nothing).
mkdir -p "$OVL"/usr/share/cockpit/egos-storage
cat > "$OVL"/usr/share/cockpit/egos-storage/manifest.json <<'EGOS_CP_MANIFEST_EOF'
{
    "version": 0,
    "menu": {
        "index": {
            "label": "Storage pool",
            "order": 35,
            "keywords": [
                { "matches": ["egos", "pool", "disk", "mergerfs", "storage", "samba"] }
            ]
        }
    }
}
EGOS_CP_MANIFEST_EOF
cat > "$OVL"/usr/share/cockpit/egos-storage/index.html <<'EGOS_CP_HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Storage pool</title>
    <link rel="stylesheet" href="egos-storage.css">
    <script src="../base1/cockpit.js"></script>
    <script src="egos-storage.js"></script>
</head>
<body>
<main class="page">
    <header class="page-head">
        <div>
            <h1>Storage pool</h1>
            <p class="muted">One pool (<code>/srv/egos/pool</code>) for media, photos and the Samba share. It starts on the system disk; every disk you add joins it without moving anything.</p>
        </div>
        <button id="btn-refresh" class="btn" type="button">Refresh</button>
    </header>

    <div id="banner-admin" class="banner warn" hidden>
        <strong>Administrative access needed.</strong>
        Click <em>Limited access</em> at the top right of Cockpit and enter your password to manage storage.
    </div>
    <div id="banner-error" class="banner danger" hidden></div>
    <div id="banner-health" class="banner danger" hidden></div>

    <div id="content" hidden>
        <section class="card">
            <div class="card-head">
                <h2>Pool</h2>
                <span id="pool-state" class="badge"></span>
                <div class="spacer"></div>
                <button id="btn-reattach" class="btn" type="button">Retry missing disks</button>
            </div>
            <div id="pool-usage" class="usage" hidden>
                <div class="bar"><div id="pool-bar" class="bar-fill"></div></div>
                <div id="pool-numbers" class="muted"></div>
            </div>
            <p id="pool-empty" class="muted" hidden>No data disk yet: new files go to the system disk. Add a disk below.</p>
            <div class="table-wrap">
                <table id="branches">
                    <thead><tr><th>Disk</th><th>Device</th><th>Size</th><th>Used</th><th>Free</th><th>State</th><th></th></tr></thead>
                    <tbody></tbody>
                </table>
            </div>
        </section>

        <section class="card">
            <div class="card-head">
                <h2>Stack data</h2>
                <div class="spacer"></div>
                <button id="btn-drain" class="btn" type="button">Empty system disk</button>
                <button id="btn-link" class="btn primary" type="button" hidden>Move data to pool</button>
            </div>
            <div id="banner-held" class="banner warn" hidden>
                <strong>Jellyfin is stopped</strong> while a disk is missing: its library scan would
                forget the missing titles and their watch history. It restarts by itself when the disk is back.
            </div>
            <dl id="stack" class="kv"></dl>
            <p class="muted small">The Immich database always stays on the system disk: a database on a USB disk is easily corrupted.</p>
        </section>

        <section class="card">
            <div class="card-head"><h2>Disks that can be added</h2></div>
            <p id="disks-empty" class="muted" hidden>No additional disk detected. Plug one in and press Refresh.</p>
            <div class="table-wrap">
                <table id="disks">
                    <thead><tr><th>Device</th><th>Size</th><th>Bus</th><th>Model</th><th>In use</th><th></th></tr></thead>
                    <tbody></tbody>
                </table>
            </div>
        </section>

        <section class="card">
            <div class="card-head">
                <h2>Last operation</h2>
                <span id="job-state" class="badge"></span>
            </div>
            <p class="muted small">Operations run on the server: closing this page does not stop them.</p>
            <pre id="job-log" class="log">No operation yet.</pre>
        </section>
    </div>
</main>

<dialog id="dlg">
    <form method="dialog" id="dlg-form">
        <h2 id="dlg-title"></h2>
        <div id="dlg-body"></div>
        <label id="dlg-check-row" class="check" hidden>
            <input type="checkbox" id="dlg-check"> <span id="dlg-check-label"></span>
        </label>
        <label id="dlg-confirm-row" class="confirm" hidden>
            <span>To confirm, type <code id="dlg-confirm-word"></code></span>
            <input type="text" id="dlg-confirm" autocomplete="off" spellcheck="false">
        </label>
        <div class="dlg-actions">
            <button value="cancel" class="btn" type="submit" formnovalidate>Cancel</button>
            <button value="ok" id="dlg-ok" class="btn primary" type="submit"></button>
        </div>
    </form>
</dialog>
</body>
</html>
EGOS_CP_HTML_EOF
cat > "$OVL"/usr/share/cockpit/egos-storage/egos-storage.js <<'EGOS_CP_JS_EOF'
/* EgOS - Cockpit page "Storage pool": a front end for /usr/local/sbin/egos-storage.
 * Reads state with `egos-storage status --json` / `disks --json` and starts every
 * change as `egos-storage job ...` (a systemd unit), so closing the page never
 * interrupts a format or a copy. All safety checks stay in egos-storage. */
"use strict";

const TOOL = "/usr/local/sbin/egos-storage";
const POLL_IDLE = 10000;
const POLL_JOB = 2000;

let state = null;
let timer = null;
let lastJobRunning = false;

const $ = id => document.getElementById(id);

function run(args) {
    return cockpit.spawn([TOOL].concat(args), { superuser: "require", err: "message" });
}

function fmtBytes(n) {
    if (n === undefined || n === null) return "-";
    const u = ["B", "KB", "MB", "GB", "TB", "PB"];
    let i = 0;
    while (n >= 1000 && i < u.length - 1) { n /= 1000; i++ }
    return (i ? n.toFixed(n < 10 ? 1 : 0) : n) + " " + u[i];
}

function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
}

function badge(text, kind) {
    const b = el("span", "badge " + (kind || ""), text);
    return b;
}

function setBadge(node, text, kind) {
    node.textContent = text;
    node.className = "badge " + (kind || "");
}

/* ---------- theme: follow Cockpit's light/dark setting ---------- */
function applyTheme(style) {
    let s = style;
    if (!s) {
        try { s = localStorage.getItem("shell:style") } catch (e) { s = null }
    }
    const dark = s === "dark" ||
        ((!s || s === "auto") && window.matchMedia("(prefers-color-scheme: dark)").matches);
    document.documentElement.classList.toggle("dark", dark);
}
window.addEventListener("storage", ev => { if (ev.key === "shell:style") applyTheme() });
window.addEventListener("cockpit-style", ev => applyTheme(ev.detail && ev.detail.style));
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => applyTheme());

/* ---------- rendering ---------- */
function renderPool(st) {
    const pool = st.pool;
    const mounted = st.branches.filter(b => b.mounted).length;
    const notMounted = st.branches.filter(b => !b.mounted);
    // mounted, but the running mergerfs does not use it
    const outside = pool.mounted ? st.branches.filter(b => b.mounted && !b.in_pool) : [];
    const missing = notMounted.concat(outside);

    if (!pool.mounted) setBadge($("pool-state"), "not mounted", "danger");
    else if (missing.length) setBadge($("pool-state"), "degraded", "danger");
    else if (!st.branches.length) setBadge($("pool-state"), "system disk only", "");
    else setBadge($("pool-state"), "ok", "ok");

    $("pool-usage").hidden = !pool.mounted;
    if (pool.mounted) {
        // with data disks, count only them: the system disk is mostly the OS
        const data = st.branches.filter(b => b.mounted && b.in_pool);
        const sum = k => data.reduce((a, b) => a + (b[k] || 0), 0);
        const size = data.length ? sum("size") : pool.size;
        const used = data.length ? sum("used") : pool.used;
        const avail = data.length ? sum("avail") : pool.avail;
        const pct = size ? Math.round(100 * used / size) : 0;
        $("pool-bar").style.width = pct + "%";
        $("pool-bar").classList.toggle("high", pct >= 90);
        $("pool-numbers").textContent = fmtBytes(used) + " used of " + fmtBytes(size) +
            " (" + pct + "%), " + fmtBytes(avail) + " free, " +
            (mounted ? mounted + " data disk" + (mounted === 1 ? "" : "s") : "system disk only");
    }
    $("pool-empty").hidden = st.branches.length > 0;

    const tb = $("branches").querySelector("tbody");
    tb.replaceChildren();
    // the system-disk branch, always first in the table
    const loc = st.local || {};
    const lr = el("tr");
    const ln = el("td");
    ln.append(el("strong", "", "system disk"));
    ln.append(el("div", "muted small", loc.path || ""));
    lr.append(ln);
    lr.append(el("td", "mono", st.system_disk || "-"));
    lr.append(el("td", "", "-"));
    lr.append(el("td", "", loc.has_files ? "has files" : "empty"));
    lr.append(el("td", "", fmtBytes(loc.system_free)));
    const ls = el("td");
    if (!loc.in_pool) ls.append(badge(pool.mounted ? "not in pool" : "-", pool.mounted ? "danger" : ""));
    else if (loc.mode === "RW") ls.append(badge("new files", "ok"));
    else ls.append(badge("old files only", ""));
    lr.append(ls);
    lr.append(el("td", ""));
    tb.append(lr);
    for (const b of st.branches) {
        const tr = el("tr");
        const name = el("td");
        name.append(el("strong", "", b.name));
        if (b.label) name.append(el("div", "muted small", b.label));
        tr.append(name);
        tr.append(el("td", "mono", b.mounted ? b.source : (b.fstab_source || "-")));
        tr.append(el("td", "", b.mounted ? fmtBytes(b.size) : "-"));
        tr.append(el("td", "", b.mounted ? fmtBytes(b.used) : "-"));
        tr.append(el("td", "", b.mounted ? fmtBytes(b.avail) : "-"));
        const s = el("td");
        if (b.mounted && (b.in_pool || !pool.mounted)) s.append(badge(pool.mounted ? "new files" : "mounted", pool.mounted ? "ok" : ""));
        else if (b.mounted) s.append(badge("not in pool", "danger"));
        else {
            s.append(badge("NOT MOUNTED", "danger"));
            if (b.stray) s.append(el("div", "danger-text small", "files on the system disk"));
        }
        tr.append(s);
        const act = el("td", "right");
        const btn = el("button", "btn danger-outline small-btn", "Remove");
        btn.type = "button";
        btn.addEventListener("click", () => askRemove(b));
        act.append(btn);
        tr.append(act);
        tb.append(tr);
    }

    // the 2026-10-24 incident: a branch silently missing from the pool
    const health = $("banner-health");
    if (missing.length) {
        health.hidden = false;
        health.replaceChildren();
        health.append(el("strong", "", "Disk missing from the pool: " + missing.map(b => b.name).join(", ") + ". "));
        health.append(document.createTextNode(notMounted.length
            ? "Its files are not visible until it is back; new files go to the other disks. Reconnect it (check cable and power): it is reattached automatically within seconds. Otherwise press Retry missing disks; if the disk is gone for good, press Remove on its row."
            : "The disk is mounted but the pool does not use it yet. Press Retry missing disks."));
    } else if (!pool.mounted) {
        health.hidden = false;
        health.replaceChildren();
        health.append(el("strong", "", "The pool is not mounted. "));
        health.append(document.createTextNode("Media and photos are unavailable. Press Retry missing disks; if it fails, check: systemctl status egos-pool"));
    } else {
        health.hidden = true;
    }
}

function renderStack(st) {
    const dl = $("stack");
    dl.replaceChildren();
    const rows = [
        ["Media (Jellyfin, Samba)", st.stack.JELLYFIN_MEDIA_LOCATION],
        ["Immich photos", st.stack.UPLOAD_LOCATION],
        ["Immich database", st.stack.DB_DATA_LOCATION],
        ["Samba share \\\\egocenter\\media", st.samba_media_path],
    ];
    for (const [k, v] of rows) {
        dl.append(el("dt", "", k));
        const dd = el("dd");
        if (!v) dd.append(el("span", "muted", "not configured yet"));
        else {
            dd.append(el("code", "", v));
            const onPool = v.replace(/\/$/, "").startsWith(st.pool.path);
            dd.append(document.createTextNode(" "));
            if (onPool && !st.pool.mounted) dd.append(badge("pool NOT MOUNTED", "danger"));
            else dd.append(badge(onPool ? "pool" : "system disk", onPool ? "ok" : ""));
        }
        dl.append(dd);
    }
}

function renderDisks(all) {
    // disks already in the pool are listed in the Pool card
    const disks = all.filter(d => !(d.mountpoints || "").split(" ").some(m => m.indexOf("/srv/egos/disks/") === 0));
    const tb = $("disks").querySelector("tbody");
    tb.replaceChildren();
    $("disks-empty").hidden = disks.length > 0;
    $("disks").hidden = !disks.length;
    for (const d of disks) {
        const tr = el("tr");
        tr.append(el("td", "mono", d.name));
        tr.append(el("td", "", d.size));
        tr.append(el("td", "", d.tran === "-" ? "" : d.tran));
        tr.append(el("td", "", d.model === "-" ? "" : d.model));
        tr.append(el("td", "small", d.mountpoints || ""));
        const act = el("td", "right");
        if (d.mountpoints) {
            act.append(el("span", "muted small", "in use: unmount it first"));
        } else {
            const btn = el("button", "btn primary small-btn", "Add to pool");
            btn.type = "button";
            btn.addEventListener("click", () => askAdd(d));
            act.append(btn);
        }
        tr.append(act);
        tb.append(tr);
    }
}

function renderJob(st, log) {
    const j = st.job;
    let kind = "", text = "idle";
    const m = log && log.match(/== END rc=(\d+)/);
    if (j.running) { kind = "busy"; text = "running" }
    else if (m) { kind = m[1] === "0" ? "ok" : "danger"; text = m[1] === "0" ? "finished" : "failed (" + m[1] + ")" }
    setBadge($("job-state"), text, kind);
    if (log !== null) {
        // rsync/dd progress uses \r: keep only the last update of each line
        const clean = log.split("\n").map(l => l.split("\r").pop()).join("\n");
        const pre = $("job-log");
        const atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
        pre.textContent = clean || "No operation yet.";
        if (atEnd || j.running) pre.scrollTop = pre.scrollHeight;
    }
    for (const b of document.querySelectorAll("button.btn")) {
        if (b.id === "btn-refresh") continue;
        if (b.closest("dialog")) continue;
        b.disabled = j.running;
    }
    // legacy installs only (stack created outside the pool, before EgOS 4.2)
    const onPool = v => !!v && v.startsWith(st.pool.path);
    const legacy = !!st.stack.env && !(onPool(st.stack.JELLYFIN_MEDIA_LOCATION) && onPool(st.stack.UPLOAD_LOCATION));
    $("btn-link").hidden = !legacy;
    $("btn-link").disabled = j.running || !st.pool.mounted;

    const diskIn = st.branches.some(b => b.mounted && b.in_pool);
    const loc = st.local || {};
    $("btn-drain").disabled = j.running || !diskIn || !loc.has_files;
    $("btn-drain").title = !diskIn ? "Add a data disk first"
        : !loc.has_files ? "Nothing left on the system disk" : "";
    const problem = !st.pool.mounted || st.branches.some(b => !b.mounted || !b.in_pool);
    $("btn-reattach").disabled = j.running || !problem;
    $("btn-reattach").title = problem ? "" : "All disks are present";
    $("banner-held").hidden = !st.jellyfin_held;
}

/* ---------- refresh loop ---------- */
async function refresh() {
    clearTimeout(timer);
    let st, disks, log = null;
    try {
        st = JSON.parse(await run(["status", "--json"]));
        disks = JSON.parse(await run(["disks", "--json"]));
        if (st.job.has_log)
            log = await cockpit.spawn(["tail", "-c", "40000", st.job.log], { superuser: "require", err: "message" });
    } catch (e) {
        const denied = e && (e.problem === "access-denied" || e.problem === "not-authorized");
        $("banner-admin").hidden = !denied;
        $("banner-error").hidden = denied;
        if (!denied) $("banner-error").textContent = "Cannot read the storage state: " + (e.message || e.problem || e);
        $("content").hidden = true;
        timer = setTimeout(refresh, POLL_IDLE);
        return;
    }
    $("banner-admin").hidden = true;
    $("banner-error").hidden = true;
    $("content").hidden = false;
    state = st;
    renderPool(st);
    renderStack(st);
    renderDisks(disks);
    renderJob(st, log);
    if (lastJobRunning && !st.job.running) $("job-log").scrollIntoView({ block: "nearest" });
    lastJobRunning = st.job.running;
    timer = setTimeout(refresh, st.job.running ? POLL_JOB : POLL_IDLE);
}

async function startJob(args) {
    try {
        await run(["job"].concat(args));
    } catch (e) {
        $("banner-error").hidden = false;
        $("banner-error").textContent = "Could not start: " + (e.message || e.problem || e);
    }
    lastJobRunning = true;
    $("job-log").scrollIntoView({ behavior: "smooth", block: "nearest" });
    refresh();
}

/* ---------- dialogs ---------- */
function dialog({ title, body, okText, okKind, confirmWord, checkLabel }) {
    return new Promise(resolve => {
        const dlg = $("dlg");
        $("dlg-title").textContent = title;
        const b = $("dlg-body");
        b.replaceChildren();
        for (const p of body) {
            const n = el("p", p.kind || "", p.text);
            b.append(n);
        }
        $("dlg-check-row").hidden = !checkLabel;
        $("dlg-check").checked = false;
        $("dlg-check-label").textContent = checkLabel || "";
        const inp = $("dlg-confirm");
        $("dlg-confirm-row").hidden = !confirmWord;
        $("dlg-confirm-word").textContent = confirmWord || "";
        inp.value = "";
        const ok = $("dlg-ok");
        ok.textContent = okText;
        ok.className = "btn " + (okKind || "primary");
        const check = () => { ok.disabled = !!confirmWord && inp.value !== confirmWord };
        inp.oninput = check;
        check();
        dlg.onclose = () => resolve(dlg.returnValue === "ok"
            ? { checked: $("dlg-check").checked, typed: inp.value } : null);
        dlg.returnValue = "";
        dlg.showModal();
        if (confirmWord) inp.focus();
    });
}

async function askAdd(d) {
    const r = await dialog({
        title: "Add " + d.name + " to the pool",
        body: [
            { text: "Everything on " + d.name + " (" + d.size + (d.model !== "-" ? ", " + d.model : "") + ") will be ERASED.", kind: "danger-text" },
            { text: "The disk is partitioned, formatted as ext4, tested with a write/read check and joined to the pool. Services keep running." },
        ],
        okText: "Erase and add", okKind: "danger", confirmWord: d.name,
    });
    if (r) startJob(["add", "--disk", d.name, "--confirm", r.typed]);
}

async function askRemove(b) {
    const body = [
        { text: "The files on " + b.name + " disappear from the pool. The disk is NOT formatted." },
        { text: b.mounted ? "Keep the disk plugged in until the page says it can be unplugged."
                          : "The disk is not mounted: only the configuration is cleaned up." },
    ];
    const others = state.branches.filter(x => x.name !== b.name).length;
    if (!others)
        body.push({ text: "This is the last data disk: new files will go to the system disk again.", kind: "danger-text" });
    if (b.mounted)
        body.push({ text: "Files that exist only on this disk become unavailable to Jellyfin, Immich and Samba." });
    const r = await dialog({ title: "Remove " + b.name, body, okText: "Remove", okKind: "danger", confirmWord: b.name });
    if (r) startJob(["remove", "--branch", b.name, "--confirm", r.typed]);
}

async function askLink() {
    const r = await dialog({
        title: "Move data to the pool",
        body: [
            { text: "Copies the media folder onto the pool, checks the copy, then switches Jellyfin and the Samba share to it. The originals are kept on the system disk (*.pre-pool) until you delete them." },
            { text: "Jellyfin and Immich are stopped during the copy. Large libraries take hours: you can close this page." },
        ],
        okText: "Move", checkLabel: "Also move the Immich photo originals",
    });
    if (r) startJob(["link", "--yes"].concat(r.checked ? ["--immich"] : []));
}

async function askReattach() {
    const r = await dialog({
        title: "Retry missing disks",
        body: [{ text: "Mounts the disks that are back (check cable and power first) and adds them to the pool without stopping anything. Jellyfin restarts when every disk is present." }],
        okText: "Retry",
    });
    if (r) startJob(["reattach"]);
}

async function askDrain() {
    const r = await dialog({
        title: "Empty the system disk",
        body: [
            { text: "Moves the media and photos still on the system disk to the data disks. Paths do not change: Jellyfin, Immich and Samba keep working during the move." },
            { text: "Files changed in the last 10 minutes are left for a later run. Large libraries take hours: you can close this page." },
        ],
        okText: "Move files",
    });
    if (r) startJob(["drain"]);
}

document.addEventListener("DOMContentLoaded", () => {
    applyTheme();
    $("btn-refresh").addEventListener("click", refresh);
    $("btn-link").addEventListener("click", askLink);
    $("btn-reattach").addEventListener("click", askReattach);
    $("btn-drain").addEventListener("click", askDrain);
    refresh();
    cockpit.transport.wait(() => document.body.removeAttribute("hidden"));
});
EGOS_CP_JS_EOF
cat > "$OVL"/usr/share/cockpit/egos-storage/egos-storage.css <<'EGOS_CP_CSS_EOF'
/* EgOS storage page. No PatternFly in base1 on Cockpit 337: small own stylesheet,
   light/dark through the .dark class set from Cockpit's shell:style setting. */
:root {
    --bg: #f0f0f0;
    --card: #ffffff;
    --text: #151515;
    --muted: #6a6e73;
    --border: #d2d2d2;
    --primary: #0066cc;
    --primary-text: #ffffff;
    --ok: #3e8635;
    --ok-bg: #f3faf2;
    --danger: #c9190b;
    --danger-bg: #faeae8;
    --warn: #795600;
    --warn-bg: #fdf7e7;
    --busy: #2b9af3;
    --busy-bg: #e7f1fa;
    --bar: #e0e0e0;
    --log-bg: #1e1e1e;
    --log-text: #e0e0e0;
    color-scheme: light;
}
:root.dark {
    --bg: #1b1d21;
    --card: #26292d;
    --text: #e0e0e0;
    --muted: #a2a6ab;
    --border: #44484c;
    --primary: #4d9de0;
    --primary-text: #0f1214;
    --ok: #7cc674;
    --ok-bg: #1e2e1c;
    --danger: #fe5142;
    --danger-bg: #3b1b18;
    --warn: #f0ab00;
    --warn-bg: #33290e;
    --busy: #73bcf7;
    --busy-bg: #172a3a;
    --bar: #3c3f42;
    --log-bg: #111315;
    --log-text: #d2d2d2;
    color-scheme: dark;
}

* { box-sizing: border-box; }
[hidden] { display: none !important; }   /* .check/.usage set display: hidden must still win */
html, body { margin: 0; background: var(--bg); color: var(--text); }
body { font-family: "Red Hat Text", "RedHatText", "Overpass", system-ui, sans-serif; font-size: 14px; line-height: 1.5; }
code, .mono, .log { font-family: "Red Hat Mono", "RedHatMono", ui-monospace, monospace; }
code { font-size: 0.92em; overflow-wrap: anywhere; }

.page { max-width: 1100px; margin: 0 auto; padding: 16px; }
.page-head { display: flex; align-items: flex-start; gap: 16px; justify-content: space-between; margin-bottom: 12px; }
h1 { font-size: 1.5rem; font-weight: 500; margin: 0 0 2px; }
h2 { font-size: 1.1rem; font-weight: 500; margin: 0; }
p { margin: 0 0 8px; }
.muted { color: var(--muted); }
.small { font-size: 0.86em; }
.right { text-align: right; }
.spacer { flex: 1; }
.danger-text { color: var(--danger); font-weight: 500; }

.card { background: var(--card); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin-bottom: 16px; }
.card-head { display: flex; align-items: center; gap: 10px; margin-bottom: 12px; flex-wrap: wrap; }

.banner { border-radius: 8px; padding: 12px 16px; margin-bottom: 16px; border-left: 4px solid; }
.banner.warn { background: var(--warn-bg); border-color: var(--warn); }
.banner.danger { background: var(--danger-bg); border-color: var(--danger); }

.badge { display: inline-block; padding: 1px 9px; border-radius: 999px; font-size: 0.82em; font-weight: 500;
         background: var(--bar); color: var(--text); white-space: nowrap; }
.badge:empty { display: none; }
.badge.ok { background: var(--ok-bg); color: var(--ok); border: 1px solid var(--ok); }
.badge.danger { background: var(--danger-bg); color: var(--danger); border: 1px solid var(--danger); }
.badge.busy { background: var(--busy-bg); color: var(--busy); border: 1px solid var(--busy); }

.btn { font: inherit; padding: 6px 14px; border-radius: 6px; border: 1px solid var(--border); background: var(--card);
       color: var(--text); cursor: pointer; white-space: nowrap; }
.btn:hover:not(:disabled) { border-color: var(--primary); }
.btn.primary { background: var(--primary); border-color: var(--primary); color: var(--primary-text); }
.btn.danger { background: var(--danger); border-color: var(--danger); color: #fff; }
.btn.danger-outline { color: var(--danger); border-color: var(--danger); background: transparent; }
.btn:disabled { opacity: 0.45; cursor: not-allowed; }
.small-btn { padding: 3px 10px; font-size: 0.9em; }

.usage { margin-bottom: 12px; }
.bar { height: 10px; background: var(--bar); border-radius: 5px; overflow: hidden; margin-bottom: 4px; }
.bar-fill { height: 100%; width: 0; background: var(--primary); transition: width 0.4s; }
.bar-fill.high { background: var(--danger); }

.table-wrap { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; }
th { text-align: left; font-weight: 500; color: var(--muted); font-size: 0.86em; padding: 6px 8px; border-bottom: 1px solid var(--border); }
td { padding: 8px; border-bottom: 1px solid var(--border); vertical-align: middle; }
tr:last-child td { border-bottom: none; }

.kv { display: grid; grid-template-columns: max-content 1fr; gap: 6px 16px; margin: 0 0 10px; }
.kv dt { color: var(--muted); }
.kv dd { margin: 0; }

.log { background: var(--log-bg); color: var(--log-text); border-radius: 6px; padding: 12px; margin: 0;
       max-height: 360px; overflow: auto; white-space: pre-wrap; font-size: 0.86em; }

dialog { border: 1px solid var(--border); border-radius: 10px; padding: 20px; width: min(520px, calc(100vw - 32px));
         background: var(--card); color: var(--text); }
dialog::backdrop { background: rgba(0, 0, 0, 0.45); }
dialog h2 { margin-bottom: 12px; }
.check { display: flex; gap: 8px; align-items: center; margin: 8px 0; }
.confirm { display: block; margin: 12px 0; }
.confirm input { display: block; width: 100%; margin-top: 4px; padding: 6px 8px; font: inherit; border-radius: 6px;
                 border: 1px solid var(--border); background: var(--bg); color: var(--text); }
.dlg-actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 16px; }

@media (max-width: 640px) {
    .page-head { flex-direction: column; }
    .kv { grid-template-columns: 1fr; gap: 0; }
    .kv dd { margin-bottom: 8px; }
}
EGOS_CP_CSS_EOF

# --- Network: ONLY manager = systemd-networkd (no d-i -> no ifupdown) ---
mkdir -p "$OVL"/etc/systemd/network "$OVL"/etc/systemd/resolved.conf.d
cat > "$OVL"/etc/systemd/network/20-wired.network <<'NET_EOF'
[Match]
Name=eth* en*

[Network]
DHCP=yes
NET_EOF
# wlan0 NOT managed by networkd: setup-webapp.sh configures it (AP)

# resolved: mDNS -> avahi (5353), LLMNR -> wsdd2 (5355): avoid conflicts
cat > "$OVL"/etc/systemd/resolved.conf.d/egos.conf <<'RES_EOF'
[Resolve]
MulticastDNS=no
LLMNR=no
RES_EOF

# --- Clock: Pi 5 without RTC battery -> wait for NTP before TLS pulls ---
mkdir -p "$OVL"/etc/systemd/system/docker-compose-startup.service.d
cat > "$OVL"/etc/systemd/system/docker-compose-startup.service.d/10-timesync.conf <<'TS_EOF'
[Unit]
After=time-sync.target
Wants=time-sync.target
TS_EOF

# --- growroot at 1st boot (small image -> 250GB NVMe) ---
cat > "$OVL"/etc/systemd/system/egos-growroot.service <<'GR_EOF'
[Unit]
Description=Grow rootfs at first boot
Before=first-boot-setup.service
ConditionPathExists=!/var/lib/egos-growroot-done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/egos-growroot.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
GR_EOF

cat > "$OVL"/usr/local/bin/egos-growroot.sh <<'GRS_EOF'
#!/bin/bash
set -e
SRC=$(findmnt -no SOURCE /)
PART=$(basename "$SRC")
DISK=/dev/$(lsblk -no PKNAME "$SRC")
NUM=$(cat /sys/class/block/"$PART"/partition)
growpart "$DISK" "$NUM" || true      # exit 1 = "NOCHANGE": not an error
resize2fs "$SRC"
touch /var/lib/egos-growroot-done
systemctl disable egos-growroot.service
GRS_EOF
chmod +x "$OVL"/usr/local/bin/egos-growroot.sh

# --- SSH host keys: NOT included in the image (they would be identical on every
#     box flashed from the same .img). Generated at 1st boot, before sshd. ---
cat > "$OVL"/etc/systemd/system/egos-sshkeys.service <<'SK_EOF'
[Unit]
Description=Generate SSH host keys at first boot
DefaultDependencies=no
After=local-fs.target
Before=ssh.service ssh.socket sockets.target shutdown.target
Conflicts=shutdown.target
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target ssh.service ssh.socket
SK_EOF

# --- Boot Pi 5 ---
mkdir -p "$OVL"/boot/firmware
cat > "$OVL"/boot/firmware/config.txt <<'CFG_EOF'
[all]
arm_64bit=1
# 4K page kernel: compatibility with arm64 docker images (jemalloc) vs 16K
kernel=kernel8.img
auto_initramfs=1
# external PCIe for NVMe HATs without HAT+ EEPROM
dtparam=pciex1
CFG_EOF

cat > "$OVL"/boot/firmware/cmdline.txt <<CMD_EOF
console=serial0,115200 console=tty1 root=PARTUUID=${LABELID}-02 rootfstype=ext4 fsck.repair=yes rootwait
CMD_EOF

cat > "$OVL"/etc/fstab <<FSTAB_EOF
PARTUUID=${LABELID}-02  /              ext4  defaults,noatime  0 1
PARTUUID=${LABELID}-01  /boot/firmware vfat  defaults          0 2
FSTAB_EOF

# -----------------------------------------------------------------------------
# 12. arm64 rootfs (replaces live-build + d-i + preseed)
#     Packages = amd64 pkgsel/include + Pi kernel/firmware + docker + network
# -----------------------------------------------------------------------------
PKGS="systemd-sysv systemd-resolved systemd-timesyncd dbus udev kmod \
locales keyboard-configuration console-setup tzdata \
initramfs-tools linux-image-rpi-v8 raspi-firmware firmware-brcm80211 \
wireless-regdb rfkill cloud-guest-utils e2fsprogs dosfstools zstd \
hostapd dnsmasq avahi-daemon python3 iptables iw curl ca-certificates samba wsdd2 sudo \
htop nano less lsof rsync openssh-server mergerfs parted attr net-tools progress \
git python3-requests \
docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
# variant=important brings these in; on EgOS they are dead weight or a second
# network manager (ifupdown = networking.service, the drift seen in prod)
PURGE="ifupdown dhcpcd-base dmidecode"

if [ "$KEEP_ROOTFS" = 1 ] && [ -d "$ROOT/lib/modules" ]; then
  echo "12 skipped: existing rootfs reused (KEEP_ROOTFS=1); overlay reapplied"
  cp -a "$OVL/." "$ROOT/"
  chroot "$ROOT" env DEBIAN_FRONTEND=noninteractive apt-get purge -y $PURGE || true
  rm -f "$ROOT"/etc/ssh/ssh_host_*
  chroot "$ROOT" systemctl enable egos-sshkeys.service
else
mmdebstrap --architectures=arm64 --variant=important \
  --include="$(echo $PKGS | tr ' ' ',')" \
  --setup-hook='mkdir -p "$1/etc/apt/keyrings"' \
  --setup-hook="cp '$KEYS/raspberrypi.gpg' \"\$1/etc/apt/keyrings/raspberrypi.gpg\"" \
  --setup-hook="cp '$KEYS/docker.gpg' \"\$1/etc/apt/keyrings/docker.gpg\"" \
  --customize-hook="cp -a '$OVL/.' \"\$1/\"" \
  --customize-hook='chroot "$1" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cockpit-ws cockpit-bridge cockpit-system' \
  --customize-hook="chroot \"\$1\" env DEBIAN_FRONTEND=noninteractive apt-get purge -y $PURGE" \
  --customize-hook='chroot "$1" env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y' \
  --customize-hook='echo egocenter > "$1/etc/hostname"' \
  --customize-hook='printf "127.0.0.1\tlocalhost\n::1\t\tlocalhost ip6-localhost ip6-loopback\n" > "$1/etc/hosts"' \
  --customize-hook='ln -sf /usr/share/zoneinfo/Europe/Rome "$1/etc/localtime"; echo Europe/Rome > "$1/etc/timezone"' \
  --customize-hook='sed -i "s/^# *it_IT.UTF-8/it_IT.UTF-8/" "$1/etc/locale.gen"; chroot "$1" locale-gen; echo LANG=it_IT.UTF-8 > "$1/etc/default/locale"' \
  --customize-hook='sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"it\"/" "$1/etc/default/keyboard"' \
  --customize-hook='echo root:CHANGE_ME | chroot "$1" chpasswd' \
  --customize-hook='chroot "$1" groupadd -f docker' \
  --customize-hook='chroot "$1" systemctl enable systemd-networkd systemd-resolved systemd-timesyncd systemd-time-wait-sync avahi-daemon wsdd2 docker cockpit.socket egos-growroot.service egos-sshkeys.service first-boot-setup.service docker-compose-startup.service egos-pool.service egos-pool-guard.service' \
  --customize-hook='chroot "$1" sh -c "systemctl enable ssh || systemctl enable ssh.socket || true"' \
  --customize-hook='chroot "$1" systemctl disable hostapd dnsmasq' \
  --customize-hook='rm -f "$1"/etc/ssh/ssh_host_*' \
  --customize-hook='ln -sf /run/systemd/resolve/stub-resolv.conf "$1/etc/resolv.conf"' \
  --customize-hook=': > "$1/etc/machine-id"' \
  trixie "$ROOT" \
  "deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware" \
  "deb http://deb.debian.org/debian-security trixie-security main contrib non-free non-free-firmware" \
  "deb [signed-by=/etc/apt/keyrings/raspberrypi.gpg] http://archive.raspberrypi.com/debian trixie main" \
  "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian trixie stable"
fi

# v4: Docker repo STAYS in the final system (signed-by, key
# verified in sec. 1): without them docker-ce never gets security updates
[ -s "$ROOT"/etc/apt/keyrings/docker.gpg ] || cp "$KEYS/docker.gpg" "$ROOT"/etc/apt/keyrings/

# mmdebstrap manages /etc/resolv.conf during the build: restore the link
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"

# Cockpit's terminal starts a NON-login bash: /etc/profile.d is not read there.
# The setup user's ~/.bashrc is copied from /etc/skel at the 1st boot (useradd -m)
grep -q 'egos-storage.sh' "$ROOT/etc/skel/.bashrc" || printf '\n%s\n%s\n' \
    "# EgOS: storage-* aliases also in non-login shells (Cockpit terminal)" \
    '[ -r /etc/profile.d/egos-storage.sh ] && . /etc/profile.d/egos-storage.sh' >> "$ROOT/etc/skel/.bashrc"

# -----------------------------------------------------------------------------
# 13. Kernel/initramfs/DTB in /boot/firmware — explicit, not left to hooks
# -----------------------------------------------------------------------------
KVER=$(ls "$ROOT"/lib/modules | grep -- '-rpi-v8$' | sort -V | tail -1)
[ -n "$KVER" ] || { echo "ERROR 13: rpi-v8 kernel missing:"; ls "$ROOT"/lib/modules; exit 1; }
# The z50-raspi-firmware hook requires a MOUNTED /boot/firmware and makes
# update-initramfs fail in the chroot. Disable it here and restore it right after:
# it is needed on the Pi, because there /boot/firmware is a real partition (fstab).
HOOK="$ROOT/etc/initramfs/post-update.d/z50-raspi-firmware"
if [ -f "$HOOK" ]; then mv "$HOOK" "$HOOK.off"; fi
chroot "$ROOT" update-initramfs -c -k "$KVER" || chroot "$ROOT" update-initramfs -u -k "$KVER"
if [ -f "$HOOK.off" ]; then mv "$HOOK.off" "$HOOK"; fi
[ -s "$ROOT/boot/initrd.img-$KVER" ] || { echo "ERROR 13: initrd not generated"; exit 1; }
cp "$ROOT/boot/vmlinuz-$KVER"    "$ROOT/boot/firmware/kernel8.img"
cp "$ROOT/boot/initrd.img-$KVER" "$ROOT/boot/firmware/initramfs8"
DTBDIR=$(dirname "$(find "$ROOT/usr/lib/linux-image-$KVER" "$ROOT/boot/firmware" -name bcm2712-rpi-5-b.dtb 2>/dev/null | head -1)")
if [ -z "$DTBDIR" ] || [ "$DTBDIR" = "." ]; then
    echo "ERROR 13: bcm2712-rpi-5-b.dtb not found. Contents:"; ls -R "$ROOT/usr/lib/linux-image-$KVER" | head -50; exit 1
fi
case "$DTBDIR" in "$ROOT/boot/firmware") ;; *)
    cp "$DTBDIR"/bcm2712*.dtb "$ROOT/boot/firmware/"
    OVLD=$(find "$ROOT/usr/lib/linux-image-$KVER" -type d -name overlays | head -1)
    if [ -n "$OVLD" ]; then cp -r "$OVLD" "$ROOT/boot/firmware/"; fi ;;
esac
echo "13 ok: kernel $KVER, DTB from $DTBDIR"

# -----------------------------------------------------------------------------
# 14. Critical package check (amd64 anti-purge equivalent)
# -----------------------------------------------------------------------------
for p in docker-ce containerd.io docker-compose-plugin samba wsdd2 hostapd dnsmasq avahi-daemon linux-image-rpi-v8 cockpit-ws sudo openssh-server htop rsync mergerfs parted attr git python3-requests; do
    chroot "$ROOT" dpkg-query -W -f='${Status}\n' "$p" 2>/dev/null | grep -q 'install ok installed' \
        || { echo "ERROR 14: $p not installed"; exit 1; }
done
for p in network-manager modemmanager wpasupplicant ppp ifupdown dhcpcd-base; do
    if chroot "$ROOT" dpkg-query -W -f='${Status}\n' "$p" 2>/dev/null | grep -q 'install ok installed'; then
        echo "ERROR 14: $p installed: only systemd-networkd may manage the network"; exit 1
    fi
done
grep -qx "EGOS_VERSION=$EGOS_VERSION" "$ROOT/etc/egos-release" \
    || { echo "ERROR 14: /etc/egos-release missing or wrong version"; exit 1; }
grep -q "^IMMICH_VERSION=$IMMICH_VERSION$" "$ROOT/usr/local/share/stack/env.template" \
    || { echo "ERROR 14: env.template not pinned"; exit 1; }
if ls "$ROOT"/etc/ssh/ssh_host_* >/dev/null 2>&1; then
    echo "ERROR 14: SSH host keys present in the image"; exit 1
fi
# -L, not -e: the link is absolute (/etc/systemd/...) and -e would resolve it on the build host
[ -L "$ROOT/etc/systemd/system/multi-user.target.wants/egos-sshkeys.service" ] \
    || { echo "ERROR 14: egos-sshkeys.service not enabled"; exit 1; }
[ -L "$ROOT/etc/resolv.conf" ] || { echo "ERROR 14: /etc/resolv.conf is not a link to systemd-resolved"; exit 1; }
grep -q 'egos-storage.sh' "$ROOT/etc/skel/.bashrc" || { echo "ERROR 14: storage aliases missing from /etc/skel/.bashrc"; exit 1; }
for f in home.py docker-proxy.cfg icons/immich.svg icons/jellyfin.svg icons/cockpit.svg; do
    [ -s "$ROOT/usr/local/share/stack/egos-home/$f" ] || { echo "ERROR 14: egos-home file $f missing"; exit 1; }
done
grep -q "^  egos-home:$" "$ROOT/usr/local/share/stack/docker-compose.yml" || { echo "ERROR 14: egos-home missing from the stack"; exit 1; }
for f in manifest.json index.html egos-storage.js egos-storage.css; do
    [ -s "$ROOT/usr/share/cockpit/egos-storage/$f" ] || { echo "ERROR 14: Cockpit page file $f missing"; exit 1; }
done
[ -s "$ROOT/etc/udev/rules.d/90-egos-reattach.rules" ] && [ -s "$ROOT/etc/systemd/system/egos-reattach.service" ] \
    || { echo "ERROR 14: automatic reattach (udev rule / unit) missing"; exit 1; }
for u in egos-pool.service egos-pool-guard.service; do
    [ -L "$ROOT/etc/systemd/system/multi-user.target.wants/$u" ] || [ -f "$OVL/etc/systemd/system/$u" ] \
        || { echo "ERROR 14: $u missing"; exit 1; }
done
grep -q '^JELLYFIN_MEDIA_LOCATION=/srv/egos/pool/media$' "$ROOT/usr/local/share/stack/env.template" \
    || { echo "ERROR 14: the stack does not start on the pool"; exit 1; }
echo "14 ok: critical packages present, no network conflict, EgOS $EGOS_VERSION"

# -----------------------------------------------------------------------------
# 15. .img assembly WITHOUT loop devices (reliable in rootless/privileged containers)
# -----------------------------------------------------------------------------
ROOT_MB=$(( $(du -sm --exclude=boot/firmware "$ROOT" | cut -f1) * 13 / 10 + 512 ))

rm -f "$W/boot.part"
mkfs.vfat -n EGOSBOOT -C "$W/boot.part" $((BOOT_MB * 1024))
mcopy -s -i "$W/boot.part" "$ROOT"/boot/firmware/* ::/

mv "$ROOT/boot/firmware" "$W/firmware.tmp" && mkdir "$ROOT/boot/firmware"
mke2fs -t ext4 -L EGOSROOT -d "$ROOT" "$W/root.part" "${ROOT_MB}M"
rmdir "$ROOT/boot/firmware" && mv "$W/firmware.tmp" "$ROOT/boot/firmware"

TOTAL_MB=$((4 + BOOT_MB + ROOT_MB + 4))
truncate -s "${TOTAL_MB}M" "$IMG"
sfdisk "$IMG" <<SFD
label: dos
label-id: 0x${LABELID}
start=4MiB, size=${BOOT_MB}MiB, type=c, bootable
start=$((4 + BOOT_MB))MiB, size=${ROOT_MB}MiB, type=83
SFD
dd if="$W/boot.part" of="$IMG" bs=1M seek=4 conv=notrunc status=none
dd if="$W/root.part" of="$IMG" bs=1M seek=$((4 + BOOT_MB)) conv=notrunc status=none
rm -f "$W/boot.part" "$W/root.part"

sfdisk -d "$IMG" | grep -q "label-id: 0x${LABELID}" || { echo "ERROR 15: label-id"; exit 1; }
echo
echo "Done: $IMG (${TOTAL_MB} MiB)"
echo "Owner: sudo chown \$SUDO_USER:\$SUDO_USER $IMG"
echo "Flash: Raspberry Pi Imager on Windows, see header (FLASH)"
