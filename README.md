# Config Manager (REST) — v1.6.6

Konfigurations-Dateien sicher lesen/schreiben per REST-API mit
Backups, atomaren Writes und optionaler Rechte-Anpassung (owner/mode).

**Highlights**

- Atomare Writes (`write_atomic`) für `configs.json` und Ziel-Dateien
- Backup-Rotation pro Config
- `apply_meta` (Owner/Group/Mode) optional & auto-aktiv bei gesetzten Feldern
- Pfad-Guard (`path_guard: off|audit|enforce`) + Symlink-Verbot
- IP-ACL (CIDR) + API-Token (Header oder Bearer)
- `actions`-Schema als Whitelist für Service-/Job-Steuerung
- Health-Check-Endpoint

## Quickstart

```bash
# Abhängigkeiten (Debian/Ubuntu Beispiele)
apt-get install -y libmojolicious-perl libjson-maybexs-perl   liblog-log4perl-perl libnet-cidr-perl

# Start (ohne systemd)
cd bin
./config-manager.pl
```

Standard-HTTP/HTTPS Bind Address wird aus `global.json` gelesen.

## Konfiguration

Siehe `config/global.json` und `config/configs.json`. Beispiel:

- `path_guard`: `off` (kein Guard), `audit` (loggt Verstösse, erlaubt), `enforce` (verbietet)
- `allowed_roots`: Liste von Wurzeln; werden beim Boot kanonisiert (realpath + trailing slash)
- `apply_meta`: globaler Default, kann pro Config übersteuert werden

## API

Swagger/OpenAPI liegt in `docs/swagger.yaml` (Kurzform) sowie `docs/openapi.json`.

Wichtige Endpunkte:
- `GET /configs`, `GET /config/{name}`, `POST /config/{name}`
- `GET /backups/{name}`, `GET /backupfile/{name}/{filename}`, `GET /backupcontent/{name}/{filename}`
- `POST /restore/{name}/{filename}`
- `POST /action/{name}/{cmd}`
- `GET /raw/configs`, `POST /raw/configs`, `POST /raw/configs/reload`, `DELETE /raw/configs/{name}`
- `GET /health`

## Systemd

```bash
cp systemd/config-manager.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now config-manager
```

## Docker

```bash
docker build -t config-manager:1.6.1 ./docker
docker run --rm -p 8080:8080   -v $(pwd)/config:/app   -v $(pwd)/backup:/app/backup   -e API_TOKEN=changeme   config-manager:1.6.1
```

## Sicherheit

- Umask 0007 → Dateien 0660 / Verzeichnisse 0770 (sofern respektiert)
- Symlink-Ziele werden strikt abgelehnt
- `path_guard=enforce` lässt nur Pfade innerhalb `allowed_roots` zu

## Lizenz

MIT — siehe `LICENSE`.
