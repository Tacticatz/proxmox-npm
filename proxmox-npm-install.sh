#!/usr/bin/env bash
# =============================================================================
#  Nginx Proxy Manager - Proxmox LXC Installer
#  Führe dieses Script in der Proxmox Shell (als root) aus:
#    bash -c "$(wget -qO- https://raw.githubusercontent.com/Tacticatz/proxmox-npm/main/proxmox-npm-install.sh)"
#  ODER kopiere es nach Proxmox und führe es aus:
#    bash proxmox-npm-install.sh
# =============================================================================

set -euo pipefail

# ──────────────── Farben & Hilfsfunktionen ────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

msg()    { echo -e "${GREEN}✔ $1${NC}"; }
info()   { echo -e "${BLUE}ℹ $1${NC}"; }
warn()   { echo -e "${YELLOW}⚠ $1${NC}"; }
error()  { echo -e "${RED}✘ $1${NC}"; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}$1${NC}\n"; }

# ──────────────── Konfiguration ────────────────
CT_ID="${CT_ID:-$(pvesh get /cluster/nextid)}"
CT_HOSTNAME="${CT_HOSTNAME:-nginx-proxy-manager}"
CT_PASSWORD="${CT_PASSWORD:-npm@proxmox}"
CT_CORES="${CT_CORES:-2}"
CT_RAM="${CT_RAM:-1024}"
CT_DISK="${CT_DISK:-8}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_IP="${CT_IP:-dhcp}"          # z.B. "192.168.1.100/24" für statische IP
CT_GW="${CT_GW:-}"              # Gateway nur bei statischer IP nötig
CT_DNS="${CT_DNS:-1.1.1.1}"
TEMPLATE_STORAGE="${TEMPLATE_STORAGE:-local}"

# Storage automatisch erkennen: bevorzuge local-lvm, dann local, dann erstes verfügbares
if [[ -z "${STORAGE:-}" ]]; then
  if pvesm status 2>/dev/null | grep -q '^local-lvm'; then
    STORAGE="local-lvm"
  elif pvesm status 2>/dev/null | grep -qE '^local\s'; then
    STORAGE="local"
  else
    STORAGE=$(pvesm status 2>/dev/null | awk 'NR>1 && $2~/dir|lvmthin|lvm|zfspool/ {print $1; exit}')
    [[ -z "$STORAGE" ]] && error "Kein geeigneter Storage gefunden! Bitte STORAGE=<name> manuell setzen."
  fi
fi

# NPM Ports
PORT_HTTP=80
PORT_ADMIN=81
PORT_HTTPS=443
PORT_IMAP=143
PORT_SMTPS=465
PORT_SMTP=587
PORT_IMAPS=993

# ──────────────── Prüfungen ────────────────
header "═══════════════════════════════════════════"
header "   Nginx Proxy Manager – Proxmox Installer "
header "═══════════════════════════════════════════"

[[ "$(id -u)" != "0" ]] && error "Dieses Script muss als root ausgeführt werden!"
command -v pveversion &>/dev/null || error "Kein Proxmox-System erkannt. Dieses Script läuft nur auf Proxmox VE."

info "Container ID  : $CT_ID"
info "Hostname      : $CT_HOSTNAME"
info "CPU-Kerne     : $CT_CORES"
info "RAM           : ${CT_RAM} MB"
info "Festplatte    : ${CT_DISK} GB"
info "Bridge        : $CT_BRIDGE"
info "IP            : $CT_IP"
info "Storage       : $STORAGE"

# ──────────────── Debian-Template herunterladen ────────────────
header "1/5 Template herunterladen..."

TEMPLATE_LIST=$(pveam available --section system 2>/dev/null | grep -i "debian-12" | head -1)
if [[ -z "$TEMPLATE_LIST" ]]; then
  error "Kein Debian 12 Template verfügbar. Bitte prüfe deine Proxmox-Verbindung."
fi

TEMPLATE_NAME=$(echo "$TEMPLATE_LIST" | awk '{print $2}')
info "Verwende Template: $TEMPLATE_NAME"

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
  info "Template wird heruntergeladen..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" || error "Template-Download fehlgeschlagen!"
  msg "Template heruntergeladen."
else
  msg "Template bereits vorhanden."
fi

TEMPLATE_PATH="$TEMPLATE_STORAGE:vztmpl/$TEMPLATE_NAME"

# ──────────────── LXC-Container erstellen ────────────────
header "2/5 LXC-Container erstellen..."

# IP-Konfiguration aufbauen
if [[ "$CT_IP" == "dhcp" ]]; then
  NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=dhcp,ip6=auto"
else
  [[ -z "$CT_GW" ]] && error "Bei statischer IP muss CT_GW (Gateway) gesetzt sein!"
  NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW},ip6=auto"
fi

pct create "$CT_ID" "$TEMPLATE_PATH" \
  --hostname "$CT_HOSTNAME" \
  --password "$CT_PASSWORD" \
  --cores "$CT_CORES" \
  --memory "$CT_RAM" \
  --rootfs "$STORAGE:${CT_DISK}" \
  --net0 "$NET_CONFIG" \
  --nameserver "$CT_DNS" \
  --features "nesting=1" \
  --unprivileged 1 \
  --onboot 1 \
  --start 0 \
  --description "Nginx Proxy Manager – installiert via proxmox-npm-install.sh" \
  || error "Container konnte nicht erstellt werden!"

msg "Container $CT_ID erstellt."

# ──────────────── Container starten ────────────────
header "3/5 Container starten..."
pct start "$CT_ID"
sleep 5
msg "Container gestartet."

# ──────────────── NPM installieren ────────────────
header "4/5 Nginx Proxy Manager installieren..."
info "Dies kann 2–5 Minuten dauern..."

pct exec "$CT_ID" -- bash -c '
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "→ System aktualisieren..."
apt-get update -qq
apt-get upgrade -y -qq

echo "→ Abhängigkeiten installieren..."
apt-get install -y -qq \
  curl wget gnupg2 ca-certificates lsb-release \
  build-essential git python3 python3-pip \
  openssl libssl-dev libffi-dev \
  nginx certbot

echo "→ Node.js 18 installieren..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs

echo "→ Node-Version: $(node --version)"

echo "→ SQLite3 & openresty vorbereiten..."
apt-get install -y -qq \
  libcap2-bin sqlite3 logrotate

echo "→ Nginx Proxy Manager herunterladen..."
NPM_VERSION=$(curl -s "https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest" | grep tag_name | cut -d '"' -f 4)
echo "  Version: $NPM_VERSION"

mkdir -p /opt/nginx-proxy-manager
cd /opt/nginx-proxy-manager

curl -sL "https://github.com/NginxProxyManager/nginx-proxy-manager/archive/refs/tags/${NPM_VERSION}.tar.gz" \
  -o npm.tar.gz
tar -xzf npm.tar.gz --strip-components=1
rm npm.tar.gz

echo "→ OpenResty installieren..."
apt-get install -y -qq \
  zlib1g-dev libpcre3 libpcre3-dev

if ! command -v openresty &>/dev/null; then
  echo "deb http://openresty.org/package/debian $(lsb_release -sc) openresty" \
    > /etc/apt/sources.list.d/openresty.list
  curl -fsSL https://openresty.org/package/pubkey.gpg | apt-key add - >/dev/null 2>&1
  apt-get update -qq
  apt-get install -y -qq openresty || apt-get install -y -qq nginx
fi

echo "→ Backend installieren..."
cd /opt/nginx-proxy-manager/backend
npm ci --production --silent 2>/dev/null || npm install --production --silent

echo "→ Frontend bauen..."
cd /opt/nginx-proxy-manager/frontend
npm ci --silent 2>/dev/null || npm install --silent
npm run build --silent 2>/dev/null || true

echo "→ Verzeichnisse erstellen..."
mkdir -p /data/nginx /data/custom_ssl /data/logs /data/access /data/nginx/default_host \
         /data/nginx/default_www /data/nginx/proxy_host /data/nginx/redirection_host \
         /data/nginx/stream /data/nginx/dead_host /data/nginx/temp \
         /data/letsencrypt-acme-challenge /etc/letsencrypt /var/log/nginx-proxy-manager

echo "→ Konfiguration erstellen..."
cat > /opt/nginx-proxy-manager/config/production.json <<EOF2
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
EOF2

echo "→ Systemd-Service einrichten..."
cat > /etc/systemd/system/npm.service <<EOF2
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
EOF2

systemctl daemon-reload
systemctl enable npm
systemctl start npm || true

echo "✔ Installation abgeschlossen!"
'

# ──────────────── Abschluss ────────────────
header "5/5 Fertig! 🎉"

# IP-Adresse ermitteln
sleep 3
CONTAINER_IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "Unbekannt")

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║   Nginx Proxy Manager erfolgreich installiert  ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Container ID :${NC} $CT_ID"
echo -e "  ${BOLD}IP-Adresse   :${NC} $CONTAINER_IP"
echo ""
echo -e "  ${BOLD}${CYAN}Admin-Oberfläche:${NC}"
echo -e "  🌐 http://${CONTAINER_IP}:81"
echo ""
echo -e "  ${BOLD}Standard-Zugangsdaten:${NC}"
echo -e "  📧 E-Mail    : admin@example.com"
echo -e "  🔑 Passwort  : changeme"
echo ""
echo -e "  ${YELLOW}⚠ Bitte das Passwort beim ersten Login sofort ändern!${NC}"
echo ""
echo -e "  ${BOLD}Freigegebene Ports:${NC}"
echo -e "  80  → HTTP"
echo -e "  81  → Admin-UI"
echo -e "  443 → HTTPS"
echo -e "  143 → IMAP"
echo -e "  465 → SMTPS"
echo -e "  587 → SMTP"
echo -e "  993 → IMAPS"
echo ""
echo -e "  ${BOLD}Container verwalten:${NC}"
echo -e "  pct stop  $CT_ID   # Stoppen"
echo -e "  pct start $CT_ID   # Starten"
echo -e "  pct enter $CT_ID   # Shell öffnen"
echo ""
