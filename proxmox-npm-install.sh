#!/usr/bin/env bash
# =============================================================================
#  Nginx Proxy Manager - Proxmox LXC Installer
#  bash -c "$(wget -qO- https://raw.githubusercontent.com/Tacticatz/proxmox-npm/main/proxmox-npm-install.sh)"
# =============================================================================

set -euo pipefail

# ──────────────── Farben & Hilfsfunktionen ────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

msg()    { echo -e "${GREEN}✔  $1${NC}"; }
info()   { echo -e "${BLUE}ℹ  $1${NC}"; }
warn()   { echo -e "${YELLOW}⚠  $1${NC}"; }
error()  { echo -e "${RED}✘  $1${NC}"; exit 1; }
header() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}\n"; }

ask() {
  # ask "Frage" "Standardwert"  → gibt Eingabe zurück
  local prompt="$1"
  local default="$2"
  local input
  echo -ne "${BOLD}${CYAN}  ❯ ${NC}${prompt}"
  [[ -n "$default" ]] && echo -ne " ${YELLOW}[${default}]${NC}"
  echo -ne ": "
  read -r input
  echo "${input:-$default}"
}

ask_list() {
  # ask_list "Frage" item1 item2 item3 ...
  local prompt="$1"; shift
  local items=("$@")
  echo -e "${BOLD}${CYAN}  ❯ ${NC}${prompt}:"
  for i in "${!items[@]}"; do
    echo -e "    ${YELLOW}$((i+1))${NC}) ${items[$i]}"
  done
  echo -ne "${BOLD}${CYAN}  ❯ ${NC}Auswahl (Nummer oder Name): "
  local input; read -r input
  # Wenn Zahl eingegeben → Element auswählen
  if [[ "$input" =~ ^[0-9]+$ ]] && (( input >= 1 && input <= ${#items[@]} )); then
    echo "${items[$((input-1))]}"
  else
    echo "$input"
  fi
}

# ──────────────── Root-Check & Proxmox-Check ────────────────
[[ "$(id -u)" != "0" ]] && error "Muss als root ausgeführt werden!"
command -v pveversion &>/dev/null || error "Kein Proxmox-System erkannt!"

# ──────────────── Banner ────────────────
clear
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║     Nginx Proxy Manager – Proxmox LXC Installer   ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ──────────────── Auto-Erkennung ────────────────
header "Systemerkennung"

# Nächste freie Container-ID
NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")
info "Nächste freie Container-ID: $NEXT_ID"

# Verfügbare Storages ermitteln (die rootdir/images unterstützen)
STORAGES=()
while IFS= read -r line; do
  name=$(echo "$line" | awk '{print $1}')
  [[ -n "$name" && "$name" != "Name" ]] && STORAGES+=("$name")
done < <(pvesm status --content rootdir 2>/dev/null | tail -n +2 || \
         pvesm status 2>/dev/null | awk 'NR>1 {print $1}')

if [[ ${#STORAGES[@]} -eq 0 ]]; then
  # Fallback: alle Storages anzeigen
  while IFS= read -r s; do STORAGES+=("$s"); done \
    < <(pvesm status 2>/dev/null | awk 'NR>1 {print $1}')
fi

# Verfügbare Netzwerk-Bridges ermitteln
BRIDGES=()
while IFS= read -r br; do
  [[ "$br" =~ ^vmbr ]] && BRIDGES+=("$br")
done < <(ip link show 2>/dev/null | grep -oP 'vmbr\d+' | sort -u || echo "vmbr0")
[[ ${#BRIDGES[@]} -eq 0 ]] && BRIDGES=("vmbr0")

info "Gefundene Storages : ${STORAGES[*]}"
info "Gefundene Bridges  : ${BRIDGES[*]}"

# ──────────────── Interaktive Konfiguration ────────────────
header "Container-Konfiguration"
echo -e "  ${YELLOW}Einfach Enter drücken um den Standardwert [in Klammern] zu übernehmen.${NC}\n"

CT_ID=$(ask "Container-ID" "$NEXT_ID")
CT_HOSTNAME=$(ask "Hostname" "nginx-proxy-manager")
CT_PASSWORD=$(ask "Root-Passwort des Containers" "npm@proxmox")
CT_CORES=$(ask "CPU-Kerne" "2")
CT_RAM=$(ask "RAM in MB" "1024")
CT_DISK=$(ask "Festplattengröße in GB" "8")

echo ""

# Storage auswählen
if [[ ${#STORAGES[@]} -eq 1 ]]; then
  STORAGE="${STORAGES[0]}"
  info "Storage: $STORAGE (einziger verfügbarer)"
else
  STORAGE=$(ask_list "Storage für den Container" "${STORAGES[@]}")
fi

# Bridge auswählen
if [[ ${#BRIDGES[@]} -eq 1 ]]; then
  CT_BRIDGE="${BRIDGES[0]}"
  info "Bridge: $CT_BRIDGE (einzige verfügbare)"
else
  CT_BRIDGE=$(ask_list "Netzwerk-Bridge" "${BRIDGES[@]}")
fi

echo ""

# IP-Konfiguration
echo -e "  ${BOLD}IP-Konfiguration:${NC}"
echo -e "    ${YELLOW}1${NC}) DHCP (automatisch)"
echo -e "    ${YELLOW}2${NC}) Statische IP"
echo -ne "${BOLD}${CYAN}  ❯ ${NC}Auswahl [1]: "
read -r ip_choice

if [[ "${ip_choice:-1}" == "2" ]]; then
  CT_IP=$(ask "IP-Adresse (z.B. 192.168.1.100/24)" "")
  CT_GW=$(ask "Gateway (z.B. 192.168.1.1)" "")
  NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW},ip6=auto"
else
  CT_IP="dhcp"
  CT_GW=""
  NET_CONFIG="name=eth0,bridge=${CT_BRIDGE},ip=dhcp,ip6=auto"
fi

CT_DNS=$(ask "DNS-Server" "1.1.1.1")

# Template Storage (immer "local" in Proxmox Standard)
TEMPLATE_STORAGE="local"
if ! pvesm list local &>/dev/null; then
  TEMPLATE_STORAGE="${STORAGES[0]}"
fi

# ──────────────── Zusammenfassung ────────────────
echo ""
echo -e "${BOLD}${CYAN}━━━ Zusammenfassung ━━━${NC}"
echo ""
echo -e "  Container ID   : ${BOLD}$CT_ID${NC}"
echo -e "  Hostname       : ${BOLD}$CT_HOSTNAME${NC}"
echo -e "  CPU-Kerne      : ${BOLD}$CT_CORES${NC}"
echo -e "  RAM            : ${BOLD}${CT_RAM} MB${NC}"
echo -e "  Festplatte     : ${BOLD}${CT_DISK} GB${NC}"
echo -e "  Storage        : ${BOLD}$STORAGE${NC}"
echo -e "  Bridge         : ${BOLD}$CT_BRIDGE${NC}"
echo -e "  IP             : ${BOLD}$CT_IP${NC}"
echo -e "  DNS            : ${BOLD}$CT_DNS${NC}"
echo ""
echo -ne "${BOLD}${CYAN}  ❯ ${NC}Starten? ${YELLOW}[J/n]${NC}: "
read -r confirm
[[ "${confirm,,}" == "n" ]] && { echo "Abgebrochen."; exit 0; }
echo ""

# ──────────────── 1/5 Template herunterladen ────────────────
header "1/5  Debian-Template herunterladen"

TEMPLATE_NAME=$(pveam available --section system 2>/dev/null | grep -i "debian-12" | awk '{print $2}' | head -1)
[[ -z "$TEMPLATE_NAME" ]] && error "Kein Debian 12 Template gefunden. Internet-Verbindung prüfen."
info "Template: $TEMPLATE_NAME"

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
  info "Herunterladen..."
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME" || error "Download fehlgeschlagen!"
fi
msg "Template bereit."

TEMPLATE_PATH="$TEMPLATE_STORAGE:vztmpl/$TEMPLATE_NAME"

# ──────────────── 2/5 Container erstellen ────────────────
header "2/5  LXC-Container erstellen"

pct create "$CT_ID" "$TEMPLATE_PATH" \
  --hostname    "$CT_HOSTNAME" \
  --password    "$CT_PASSWORD" \
  --cores       "$CT_CORES" \
  --memory      "$CT_RAM" \
  --rootfs      "${STORAGE}:${CT_DISK}" \
  --net0        "$NET_CONFIG" \
  --nameserver  "$CT_DNS" \
  --features    "nesting=1" \
  --unprivileged 1 \
  --onboot      1 \
  --start       0 \
  --description "Nginx Proxy Manager – https://github.com/Tacticatz/proxmox-npm" \
  || error "Container konnte nicht erstellt werden!"

msg "Container $CT_ID erstellt."

# ──────────────── 3/5 Container starten ────────────────
header "3/5  Container starten"
pct start "$CT_ID"
sleep 6
msg "Container gestartet."

# ──────────────── 4/5 NPM installieren ────────────────
header "4/5  Nginx Proxy Manager installieren"
info "Dies dauert ca. 3–6 Minuten..."

pct exec "$CT_ID" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "  → System aktualisieren..."
apt-get update -qq && apt-get upgrade -y -qq

echo "  → Abhängigkeiten installieren..."
apt-get install -y -qq \
  curl wget gnupg2 ca-certificates lsb-release \
  build-essential git python3 \
  openssl libssl-dev libffi-dev \
  libcap2-bin sqlite3 logrotate

echo "  → Node.js 18 installieren..."
curl -fsSL https://deb.nodesource.com/setup_18.x | bash - >/dev/null 2>&1
apt-get install -y -qq nodejs

echo "  → OpenResty installieren..."
apt-get install -y -qq zlib1g-dev libpcre3 libpcre3-dev
echo "deb http://openresty.org/package/debian $(lsb_release -sc) openresty" \
  > /etc/apt/sources.list.d/openresty.list
curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor \
  -o /etc/apt/trusted.gpg.d/openresty.gpg 2>/dev/null
apt-get update -qq
apt-get install -y -qq openresty || apt-get install -y -qq nginx

echo "  → Nginx Proxy Manager herunterladen..."
NPM_VERSION=$(curl -s "https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest" \
  | grep tag_name | cut -d'"' -f4)
echo "    Version: $NPM_VERSION"

mkdir -p /opt/nginx-proxy-manager
curl -sL "https://github.com/NginxProxyManager/nginx-proxy-manager/archive/refs/tags/${NPM_VERSION}.tar.gz" \
  | tar -xz -C /opt/nginx-proxy-manager --strip-components=1

echo "  → Backend installieren..."
cd /opt/nginx-proxy-manager/backend
npm ci --production --silent 2>/dev/null || npm install --production --silent

echo "  → Frontend bauen..."
cd /opt/nginx-proxy-manager/frontend
npm ci --silent 2>/dev/null || npm install --silent
npm run build --silent 2>/dev/null || true

echo "  → Verzeichnisse anlegen..."
mkdir -p /data/nginx /data/custom_ssl /data/logs /data/access \
  /data/nginx/{default_host,default_www,proxy_host,redirection_host,stream,dead_host,temp} \
  /data/letsencrypt-acme-challenge /etc/letsencrypt /var/log/nginx-proxy-manager

echo "  → Datenbank-Konfiguration schreiben..."
mkdir -p /opt/nginx-proxy-manager/config
cat > /opt/nginx-proxy-manager/config/production.json <<EOF
{
  "database": {
    "engine": "knex-native",
    "knex": {
      "client": "sqlite3",
      "connection": { "filename": "/data/database.sqlite" }
    }
  }
}
EOF

echo "  → Systemd-Service einrichten..."
cat > /etc/systemd/system/npm.service <<EOF
[Unit]
Description=Nginx Proxy Manager
After=network.target

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
EOF

systemctl daemon-reload
systemctl enable npm
systemctl start npm || true
echo "  ✔ Installation abgeschlossen!"
'

# ──────────────── 5/5 Fertig ────────────────
header "5/5  Fertig!"

sleep 4
CONTAINER_IP=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "Unbekannt")

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║      Nginx Proxy Manager erfolgreich installiert!  ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Container ID :${NC} $CT_ID"
echo -e "  ${BOLD}IP-Adresse   :${NC} $CONTAINER_IP"
echo ""
echo -e "  ${BOLD}${CYAN}Admin-Oberfläche:${NC}  http://${CONTAINER_IP}:81"
echo ""
echo -e "  ${BOLD}Standard-Login:${NC}"
echo -e "  📧  admin@example.com"
echo -e "  🔑  changeme"
echo ""
echo -e "  ${YELLOW}⚠  Beim ersten Login sofort Passwort ändern!${NC}"
echo ""
echo -e "  ${BOLD}Ports:${NC}  80 (HTTP)  81 (Admin)  443 (HTTPS)"
echo -e "          143 (IMAP)  465 (SMTPS)  587 (SMTP)  993 (IMAPS)"
echo ""
echo -e "  ${BOLD}Container verwalten:${NC}"
echo -e "  pct start $CT_ID  /  pct stop $CT_ID  /  pct enter $CT_ID"
echo ""
