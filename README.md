# 🚀 Nginx Proxy Manager – Proxmox LXC

Einfache Installation von Nginx Proxy Manager als LXC-Container auf Proxmox VE.

## Schnellstart

### Option 1: Container direkt installieren (empfohlen)
In der **Proxmox Shell** ausführen:
```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/Tacticatz/proxmox-npm/main/proxmox-npm-install.sh)"
```

### Option 2: .tar.zst Template bauen
In der **Proxmox Shell** ausführen:
```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/Tacticatz/proxmox-npm/main/proxmox-npm-build-template.sh)"
```

## Nach der Installation

- **Admin-UI:** http://CONTAINER-IP:81
- **E-Mail:** admin@example.com
- **Passwort:** changeme *(beim ersten Login ändern!)*

## Freigegebene Ports

| Port | Protokoll |
|------|-----------|
| 80   | HTTP      |
| 81   | Admin-UI  |
| 443  | HTTPS     |
| 143  | IMAP      |
| 465  | SMTPS     |
| 587  | SMTP      |
| 993  | IMAPS     |

## Optionen (Install-Script)

```bash
# Statische IP
CT_IP="192.168.1.100/24" CT_GW="192.168.1.1" bash proxmox-npm-install.sh

# Mit eigener ID und mehr RAM
CT_ID=200 CT_RAM=2048 bash proxmox-npm-install.sh
```

## Dateien

- proxmox-npm-install.sh – Erstellt direkt einen LXC-Container mit NPM
- proxmox-npm-build-template.sh – Baut ein wiederverwendbares .tar.zst Template

---
Made with ❤️ for Proxmox VE