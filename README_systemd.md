
# Config Agent — Systemd Service

## Übersicht
Diese Datei beschreibt die systemd-Service-Unit für den **Config Agent**. Der Service ist für den Betrieb des Config Managers als systemd-Dienst konzipiert und enthält umfangreiche Sicherheits- und Sandboxing-Einstellungen, um die Anwendung sicher und isoliert auszuführen.

## Service-Unit-Datei
Die Service-Unit-Datei (`config-agent.service`) enthält alle notwendigen Konfigurationen, um den Config Agent als systemd-Dienst zu betreiben. Die Datei ist für maximale Sicherheit und Isolation konfiguriert.

## Installation

### 1. Service-Unit-Datei erstellen
Kopiere den folgenden Inhalt in eine neue Datei unter `/etc/systemd/system/config-agent.service`:

```ini
[Unit]
Description=Config Agent (hardened)
Wants=network-online.target
After=network.target network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=/opt/config-agent
ExecStart=/usr/bin/perl /opt/config-agent/config-agent.pl
EnvironmentFile=/opt/env/config-agent.env
UMask=0027

# ENV/Path härten
Environment=PATH=/usr/bin:/usr/sbin
UnsetEnvironment=PERL5LIB PERLLIB PERL5OPT IFS CDPATH ENV BASH_ENV
# optional:
UnsetEnvironment=LD_PRELOAD LD_LIBRARY_PATH

# Restart
TimeoutStartSec=30
Restart=on-failure
RestartSec=3s

# Sandboxing
NoNewPrivileges=yes
RestrictSUIDSGID=yes
ProtectSystem=strict
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
ProtectKernelLogs=true
PrivateTmp=true
PrivateDevices=true
PrivateMounts=true
LockPersonality=yes
RestrictNamespaces=yes
RestrictRealtime=yes
KeyringMode=private
ProcSubset=pid
ProtectProc=invisible
MemoryDenyWriteExecute=true
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@obsolete
SystemCallFilter=~@privileged

# Netzwerk
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
# nur Loopback?:
# IPAddressDeny=any
# IPAddressAllow=127.0.0.1 ::1

# Default-deny Filesystem
TemporaryFileSystem=/

# Binaries/Libs
BindReadOnlyPaths=/usr:/usr
BindReadOnlyPaths=/usr/share:/usr/share
BindReadOnlyPaths=/lib:/lib
BindReadOnlyPaths=/lib64:/lib64
BindReadOnlyPaths=/bin:/bin
BindReadOnlyPaths=/sbin:/sbin

# /etc-Basics
BindReadOnlyPaths=/etc/hosts
BindReadOnlyPaths=/etc/resolv.conf
BindReadOnlyPaths=/etc/nsswitch.conf
BindReadOnlyPaths=/etc/localtime
BindReadOnlyPaths=/etc/machine-id

# Kommunikation mit systemd-Manager
BindReadOnlyPaths=/run/dbus/system_bus_socket

# Prozess-Tracking & Status-Abfrage
BindReadOnlyPaths=/sys/fs/cgroup

# Journal NUR wenn benötigt:
# BindReadOnlyPaths=/run/systemd/journal:/run/systemd/journal
# SupplementaryGroups=systemd-journal

# HTTPS NUR wenn benötigt:
# BindReadOnlyPaths=/etc/ssl/ca-bundle.pem

#-----------------------------------
# Verzeichnis schreiben
#------------------------------------
BindPaths=/var/log
BindPaths=/opt/config-agent
BindPaths=/etc/postfix

#-----------------------------------
# Verzeichnis lesen
#-----------------------------------
# BindReadOnlyPaths=

# Caps minimal (keine nötig)
AmbientCapabilities=CAP_CHOWN CAP_FOWNER CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
CapabilityBoundingSet=CAP_CHOWN CAP_FOWNER CAP_DAC_READ_SEARCH CAP_DAC_OVERRIDE
SecureBits=noroot-locked

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=config-agent

[Install]
WantedBy=multi-user.target
```

### 2. Rechte setzen
Stelle sicher, dass die Datei die richtigen Berechtigungen hat:
```bash
sudo chmod 644 /etc/systemd/system/config-agent.service
```

### 3. Service aktivieren und starten
Lade die systemd-Konfiguration neu, aktiviere den Service und starte ihn:
```bash
sudo systemctl daemon-reload
sudo systemctl enable config-agent
sudo systemctl start config-agent
```

## Konfiguration

### `EnvironmentFile`
Die Service-Unit verwendet eine `EnvironmentFile`-Datei (`/opt/env/config-agent.env`), um Umgebungsvariablen zu definieren. Erstelle diese Datei und füge alle benötigten Umgebungsvariablen hinzu, z. B.:
```bash
API_TOKEN="dein-sicherer-api-token"
LISTEN="127.0.0.1:3000"
```

### `WorkingDirectory`
Der Service verwendet `/opt/config-agent` als Arbeitsverzeichnis. Stelle sicher, dass dieses Verzeichnis existiert und die notwendigen Dateien (z. B. `config-agent.pl`, `global.json`, `configs.json`) enthält.

## Sicherheitsfeatures

### Sandboxing
- **`ProtectSystem=strict`:** Schreibzugriff nur auf `/var/log`, `/opt/config-agent` und `/etc/postfix`.
- **`PrivateTmp`:** Isoliertes `/tmp`-Verzeichnis.
- **`PrivateDevices`:** Kein Zugriff auf Gerätedateien.
- **`ProtectHome`:** Kein Zugriff auf `/home`, `/root` oder `/run/user`.
- **`CapabilityBoundingSet`:** Beschränkt die Fähigkeiten des Prozesses auf das Notwendigste.
- **`SystemCallFilter`:** Filtert Systemaufrufe, um nur sichere Aufrufe zuzulassen.
- **`RestrictAddressFamilies`:** Beschränkt die Netzwerkprotokolle auf `AF_UNIX`, `AF_INET`, `AF_INET6` und `AF_NETLINK`.

### Netzwerk
Der Service kann auf alle Netzwerkprotokolle zugreifen. Falls nur Loopback-Verbindungen erlaubt sein sollen, entferne die Kommentare bei `IPAddressDeny` und `IPAddressAllow`.

### Logging
Der Service protokolliert Ausgaben in das Journal. Du kannst die Logs mit folgendem Befehl anzeigen:
```bash
journalctl -u config-agent -f
```

## Fehlerbehebung

### Service-Status prüfen
```bash
sudo systemctl status config-agent
```

### Logs anzeigen
```bash
journalctl -u config-agent
```

### Service neu starten
```bash
sudo systemctl restart config-agent
```

## Deaktivieren
Falls der Service nicht mehr benötigt wird, kannst du ihn deaktivieren und stoppen:
```bash
sudo systemctl stop config-agent
sudo systemctl disable config-agent
```

## Lizenz
Dieses Projekt steht unter der MIT-Lizenz.

## Support
Für Fragen oder Probleme öffne bitte ein Issue im Projekt-Repository.
