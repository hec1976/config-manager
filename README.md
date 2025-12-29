
# Config Manager — REST-API

## Übersicht
Config Manager ist eine auf Perl basierende REST-API zur Verwaltung von Systemkonfigurationen, Backups und Dienstaktionen. Die Anwendung nutzt das Mojolicious-Framework und bietet eine sichere und modulare Möglichkeit, Konfigurationsdateien zu verwalten, Systembefehle auszuführen und Backups zu handhaben.

## Funktionen
- **Konfigurationsverwaltung:** Lesen, Schreiben und Verwalten von Konfigurationsdateien.
- **Backup-System:** Automatisches Erstellen und Wiederherstellen von Backups für Konfigurationsdateien.
- **Dienstaktionen:** Ausführen von Systembefehlen und Dienstaktionen (z. B. Starten, Stoppen, Neustarten).
- **Sicherheit:** IP-basierte Zugriffskontrolle, API-Token-Authentifizierung und Pfadvalidierung.
- **Protokollierung:** Umfassende Protokollierung mit Mojo::Log.
- **Modularer Aufbau:** Einfache Erweiterbarkeit und Anpassbarkeit.

## Voraussetzungen
- Perl 5.20 oder neuer
- Mojolicious
- JSON::MaybeXS
- File::Basename
- File::Copy
- Time::Piece
- Time::HiRes
- FindBin
- File::Temp
- Fcntl
- Net::CIDR
- IPC::Open3
- Symbol
- Cwd
- Text::ParseWords
- POSIX

## Installation
1. Klone das Repository oder lade den Quellcode herunter.
2. Installiere die benötigten Perl-Module mit `cpan`:
   ```bash
   cpan Mojolicious JSON::MaybeXS File::Basename File::Copy Time::Piece Time::HiRes FindBin File::Temp Fcntl Net::CIDR IPC::Open3 Symbol Cwd Text::ParseWords POSIX
   ```
3. Konfiguriere die Dateien `global.json` und `configs.json` nach deinen Anforderungen.
4. Starte die Anwendung:
   ```bash
   perl config-manager.pl
   ```

## Konfiguration
### `global.json`
Diese Datei enthält globale Einstellungen für die Anwendung, wie z. B.:
- `listen`: Adresse und Port, auf denen der Server lauschen soll.
- `api_token`: API-Token für die Authentifizierung.
- `allowed_ips`: Liste der erlaubten IP-Adressen oder CIDR-Bereiche.
- `allowed_roots`: Liste der erlaubten Stammverzeichnisse für die Pfadvalidierung.
- `logfile`: Pfad zur Protokolldatei.
- `systemctl`: Pfad zur systemctl-Binärdatei.
- `systemctl_flags`: Flags, die an systemctl übergeben werden sollen.
- `maxBackups`: Maximale Anzahl der zu behaltenden Backups.
- `path_guard`: Modus der Pfadvalidierung (`off`, `audit`).
- `apply_meta`: Legt fest, ob Metadaten (Benutzer, Gruppe, Modus) auf Dateien angewendet werden sollen.
- `auto_create_backups`: Automatisches Erstellen von Backup-Verzeichnissen.
- `fsync_dir`: Aktiviert fsync für Verzeichnisse.

### `configs.json`
Diese Datei definiert die Konfigurationen, die von der Anwendung verwaltet werden. Jeder Konfigurationseintrag enthält:
- `path`: Pfad zur Konfigurationsdatei.
- `service`: Zugehöriger systemd-Dienst (optional).
- `category`: Kategorie zur Gruppierung von Konfigurationen (optional).
- `actions`: Erlaubte Aktionen für die Konfiguration (z. B. starten, stoppen, neustarten).
- `user`, `group`, `mode`: Metadaten, die auf die Konfigurationsdatei angewendet werden sollen.

## API-Endpunkte
- `GET /`: Listet alle verfügbaren API-Endpunkte auf.
- `GET /configs`: Listet alle Konfigurationen auf.
- `GET /config/{name}`: Liest eine Konfigurationsdatei.
- `POST /config/{name}`: Schreibt eine Konfigurationsdatei.
- `GET /backups/{name}`: Listet Backups für eine Konfiguration auf.
- `GET /backupcontent/{name}/{filename}`: Liest den Inhalt einer Backup-Datei.
- `POST /restore/{name}/{filename}`: Stellt eine Konfiguration aus einem Backup wieder her.
- `POST /action/{name}/{cmd}`: Führt eine Aktion für eine Konfiguration aus.
- `GET /raw/configs`: Liest die Rohdaten der `configs.json`-Datei.
- `POST /raw/configs`: Schreibt die Rohdaten der `configs.json`-Datei.
- `POST /raw/configs/reload`: Lädt die `configs.json`-Datei neu.
- `DELETE /raw/configs/{name}`: Löscht einen Konfigurationseintrag.
- `GET /health`: Endpunkt für den Gesundheitscheck.

## Sicherheit
- **Authentifizierung:** Verwende den `X-API-Token`-Header mit dem konfigurierten `api_token`.
- **IP-Zugriffskontrolle:** Konfiguriere `allowed_ips` in `global.json`, um den Zugriff einzuschränken.
- **Pfadvalidierung:** Nutze `allowed_roots`, um den Dateizugriff auf bestimmte Verzeichnisse zu beschränken.

## Protokollierung
Die Anwendung protokolliert in die angegebene `logfile` oder in STDERR, falls das Protokollverzeichnis nicht erstellt werden kann. Die Protokolle umfassen Anfragedetails, Fehler und wichtige Ereignisse.

## Lizenz
Dieses Projekt steht unter der MIT-Lizenz.

## Support
Für Probleme oder Funktionswünsche öffne bitte ein Issue im Projekt-Repository.

## Beispielkonfigurationen
### Beispiel für `global.json`
```json
{
  "listen": "127.0.0.1:3000",
  "api_token": "dein-sicherer-api-token",
  "allowed_ips": ["192.168.1.0/24"],
  "allowed_roots": ["/etc", "/var/www"],
  "logfile": "/var/log/config-manager.log",
  "systemctl": "/usr/bin/systemctl",
  "maxBackups": 10,
  "path_guard": "off",
  "apply_meta": true,
  "auto_create_backups": true,
  "fsync_dir": false
}
```

### Beispiel für `configs.json`
```json
{
  "nginx": {
    "path": "/etc/nginx/nginx.conf",
    "service": "nginx",
    "category": "Webserver",
    "actions": {
      "restart": []
    },
    "user": "root",
    "group": "root",
    "mode": "0644"
  }
}
```
