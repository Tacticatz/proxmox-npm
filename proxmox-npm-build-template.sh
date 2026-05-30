#!/usr/bin/env bash
# =============================================================================
#  Nginx Proxy Manager – Proxmox LXC Template Builder (.tar.zst)
#  Läuft auf Proxmox VE oder Debian/Ubuntu mit debootstrap
#
#  Verwendung:
#    bash proxmox-npm-build-template.sh
#
#  Das fertige Template wird automatisch in den Proxmox Template-Speicher
#  importiert und ist danach unter "local → CT Templates" verfügbar.
# =============================================================================

set -euo pipefail

# ──────────────── Farben ────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

msg()    { echo -e "${GREEN}✔  $1${NC}"; }
info()   { echo -e "${BLUE}ℹ  $1${NC}"; }
warn()   { echo -e "${YELLOW}⚠  $1${NC}"; }
error()  { echo -e "${RED}✘  $1${NC}"; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}\n"; }

# ──────────────── Konfiguration ────────────────
TEMPLATE_NAME="debian-12-nginx-proxy-manager"
TEMPLATE_VERSION="$(date +%Y%m%d)"
OUTPUT_FILE="${TEMPLATE_NAME}_${TEMPLATE_VERSION}.tar.zst"
BUILD_DIR="/tmp/npm-template-rootfs"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"   # Proxmox Storage für Templates
IMPORT_TO_PROXMOX="${IMPORT_TO_PROXMOX:-auto}"  # auto | yes | no

# ──────────────── Banner ────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║  NPM Proxmox Template Builder  (.tar.zst)         ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ──────────────── Voraussetzungen prüfen ────────────────
header "1/6  Voraussetzungen prüfen"

[[ "$(id -u)" != "0" ]] && error "Muss als root ausgeführt werden! (sudo bash $0)"

for cmd in debootstrap tar zstd curl; do
  if ! command -v "$cmd" &>/dev/null; then
    info "$cmd wird installiert..."
    apt-get install -y -qq "$cmd" || error "Konnte $cmd nicht installieren!"
  fi
done
msg "Alle Abhängigkeiten vorhanden."

# Build-Verzeichnis aufräumen falls vorhanden
[[ -d "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ──────────────── Debian 12 Rootfs erstellen ────────────────
header "2/6  Debian 12 Minimal-Rootfs erstellen (debootstrap)"
info "Dies dauert ca. 2–3 Minuten..."

debootstrap \
  --arch=amd64 \
  --include=systemd,systemd-sysv,dbus,curl,wget,ca-certificates,gnupg2,lsb-release,locales,tzdata \
  bookworm \
  "$BUILD_DIR" \
  http://deb.debian.org/debian

msg "Rootfs erstellt."

# ──────────────── Grundkonfiguration ────────────────
header "3/6  System konfigurieren"

# Hostname
echo "nginx-proxy-manager" > "$BUILD_DIR/etc/hostname"

# Hosts
cat > "$BUILD_DIR/etc/hosts" <<'EOF'
127.0.0.1   localhost
127.0.1.1   nginx-proxy-manager
::1         localhost ip6-localhost ip6-loopback
EOF

# Locale
echo "en_US.UTF-8 UTF-8" > "$BUILD_DIR/etc/locale.gen"
chroot "$BUILD_DIR" locale-gen

# Zeitzone
echo "Europe/Berlin" > "$BUILD_DIR/etc/timezone"
chroot "$BUILD_DIR" dpkg-reconfigure -f noninteractive tzdata

# Netzwerk (für LXC)
cat > "$BUILD_DIR/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# Root-Passwort setzen
echo "root:npm@proxmox" | chroot "$BUILD_DIR" chpasswd

# SSH aktivieren
chroot "$BUILD_DIR" apt-get install -y -qq openssh-server
sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' \
  "$BUILD_DIR/etc/ssh/sshd_config"

msg "System konfiguriert."

# ──────────────── Nginx Proxy Manager installieren ────────────────
header "4/6  Nginx Proxy Manager installieren"
info "Dies dauert ca. 5–8 Minuten..."

chroot "$BUILD_DIR" bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "  → Pakete aktualisieren..."
apt-get update -qq
apt-get upgrade -y -qq

echo "  → Abhängigkeiten installieren..."
apt-get install -y -qq \
  build-essential git python3 python3-pip \
  openssl libssl-dev libffi-dev \
  libcap2-bin sqlite3 logrotate \
  net-tools iproute2 iputils-ping

echo "  → Node.js 18 installieren..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs

echo "  → OpenResty installieren..."
apt-get install -y -qq zlib1g-dev libpcre3 libpcre3-dev
echo "deb http://openresty.org/package/debian $(lsb_release -sc) openresty" \
  > /etc/apt/sources.list.d/openresty.list
curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor -o \
  /etc/apt/trusted.gpg.d/openresty.gpg 2>/dev/null
apt-get update -qq
apt-get install -y -qq openresty || apt-get install -y -qq nginx

echo "  → NPM herunterladen..."
NPM_VERSION=$(curl -s "https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest" \
  | grep tag_name | cut -d'"' -f4)
echo "  → Version: $NPM_VERSION"

mkdir -p /opt/nginx-proxy-manager
cd /opt/nginx-proxy-manager

curl -sL "https://github.com/NginxProxyManager/nginx-proxy-manager/archive/refs/tags/${NPM_VERSION}.tar.gz" \
  -o npm.tar.gz
tar -xzf npm.tar.gz --strip-components=1
rm npm.tar.gz

echo "  → Backend installieren..."
cd /opt/nginx-proxy-manager/backend
npm ci --production --silent 2>/dev/null || npm install --production --silent

echo "  → Frontend bauen..."
cd /opt/nginx-proxy-manager/frontend
npm ci --silent 2>/dev/null || npm install --silent
npm run build --silent 2>/dev/null || true

echo "  → Verzeichnisse erstellen..."
mkdir -p /data/nginx /data/custom_ssl /data/logs /data/access \
         /data/nginx/{default_host,default_www,proxy_host,redirection_host,stream,dead_host,temp} \
         /data/letsencrypt-acme-challenge /etc/letsencrypt /var/log/nginx-proxy-manager

echo "  → Konfiguration schreiben..."
mkdir -p /opt/nginx-proxy-manager/config
cat > /opt/nginx-proxy-manager/config/production.json <<CONF
{
  "database": {
    "engine": "knex-native",
    "knex": {
      "client": "sqlite3",
      "connection": {
        "filename": "/data/database.sqlite"
      }
    }
  }
}
CONF

echo "  → Systemd Service einrichten..."
cat > /etc/systemd/system/npm.service <<SERVICE
[Unit]
Description=Nginx Proxy Manager
After=network.target
Wants=network-online.target

[Service]
Type=simple
Environment=NODE_ENV=production
WorkingDirectory=/opt/nginx-proxy-manager/backend
ExecStart=/usr/bin/node src/index.js
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=npm

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable npm

echo "  → Cache aufräumen..."
apt-get clean
apt-get autoremove -y -qq
rm -rf /tmp/* /var/tmp/* /root/.npm /root/.node-gyp

echo "  ✔ NPM Installation abgeschlossen!"
'

msg "Nginx Proxy Manager installiert (Version: $(chroot "$BUILD_DIR" bash -c 'curl -s "https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest" | grep tag_name | cut -d"\"" -f4' 2>/dev/null || echo 'aktuell'))"

# ──────────────── LXC-spezifische Konfiguration ────────────────
header "5/6  LXC-Konfiguration anpassen"

# /dev cleanup
rm -rf "$BUILD_DIR/dev"/*

# fstab für LXC
cat > "$BUILD_DIR/etc/fstab" <<'EOF'
# LXC fstab - wird von Proxmox verwaltet
EOF

# Systemd-Units deaktivieren die in LXC nicht funktionieren
for unit in \
  systemd-udevd.service \
  systemd-modules-load.service \
  sys-kernel-debug.mount \
  sys-kernel-tracing.mount; do
  chroot "$BUILD_DIR" systemctl mask "$unit" 2>/dev/null || true
done

# MOTD anpassen
cat > "$BUILD_DIR/etc/motd" <<'EOF'

  ╔══════════════════════════════════════════════╗
  ║        Nginx Proxy Manager - LXC Container       ║
  ║                                                    ║
  ║  Admin UI:  http://<CONTAINER-IP>:81               ║
  ║  E-Mail:    admin@example.com                      ║
  ║  Passwort:  changeme                               ║
  ║                                                    ║
  ║  Service:   systemctl status npm                   ║
  ╚══════════════════════════════════════════════╝

EOF

msg "LXC-Konfiguration angepasst."

# ──────────────── Template packen ────────────────
header "6/6  Template als .tar.zst packen"
info "Packe Rootfs – bitte warten..."

OUTPUT_PATH="$(pwd)/$OUTPUT_FILE"

tar \
  --zstd \
  --numeric-owner \
  --xattrs \
  --xattrs-include='*' \
  -cpf "$OUTPUT_PATH" \
  -C "$BUILD_DIR" \
  .

FILESIZE=$(du -sh "$OUTPUT_PATH" | cut -f1)
msg "Template erstellt: $OUTPUT_FILE ($FILESIZE)"

# ──────────────── In Proxmox importieren ────────────────
if command -v pveam &>/dev/null; then
  if [[ "$IMPORT_TO_PROXMOX" == "auto" || "$IMPORT_TO_PROXMOX" == "yes" ]]; then
    info "Proxmox erkannt – importiere Template nach '$TEMPLATE_STORAGE'..."
    TEMPLATE_DIR=$(pvesm path "$TEMPLATE_STORAGE:vztmpl/" 2>/dev/null | head -1 || echo "/var/lib/vz/template/cache")
    mkdir -p "$TEMPLATE_DIR"
    cp "$OUTPUT_PATH" "$TEMPLATE_DIR/$OUTPUT_FILE"
    pveam refresh 2>/dev/null || true
    msg "Template in Proxmox importiert!"
    info "Verfügbar unter: Datacenter → $TEMPLATE_STORAGE → CT Templates → $OUTPUT_FILE"
  fi
else
  info "Kein Proxmox erkannt. Template manuell hochladen:"
  info "  scp $OUTPUT_FILE root@PROXMOX_IP:/var/lib/vz/template/cache/"
  info "  Dann in Proxmox: pveam refresh"
fi

# Aufräumen
rm -rf "$BUILD_DIR"

# ──────────────── Fertig ────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║           Template erfolgreich gebaut! 🎉      ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Datei:${NC} $OUTPUT_FILE"
echo -e "  ${BOLD}Größe:${NC} $FILESIZE"
echo ""
echo -e "  ${BOLD}Nächste Schritte:${NC}"
echo -e "  1. Template in Proxmox: ${CYAN}Datacenter → local → CT Templates${NC}"
echo -e "  2. Container erstellen: ${CYAN}Rechtsklick → Create CT${NC}"
echo -e "  3. Admin-UI aufrufen:   ${CYAN}http://CONTAINER-IP:81${NC}"
echo -e "  4. Login:               ${CYAN}admin@example.com / changeme${NC}"
echo ""
echo -e "  ${YELLOW}⚠  Beim ersten Login unbedingt Passwort ändern!${NC}"
echo ""
