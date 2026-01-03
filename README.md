# Config Manager REST

Ein schlanker, gehärteter REST Service zum Verwalten von Konfigurationsdateien und Service Aktionen auf Linux Systemen.
Der Config Manager erlaubt das lesen, schreiben, versionieren (Backups) sowie das ausführen kontrollierter Aktionen wie systemctl reload oder restart, alles über eine gesicherte HTTP API.

## Features
- REST API auf Basis von Mojolicious
- Atomares Schreiben von Konfigurationsdateien
- Automatische Backup Erstellung mit Rollback
- Zugriffsschutz via API Token und IP ACL
- Optionaler Path Guard gegen Pfad Traversal
- Meta Anwendung (Owner, Group, Mode)
- systemctl Integration mit sauberem Promise Handling
- Skript Actions (bash, sh, perl, exec)
- Audit taugliches Logging
- Health Endpoint

## Installation
```bash
git clone https://github.com/<user>/<repo>.git
cd config-manager
chmod +x config-manager.pl
```

## Lizenz
MIT License
