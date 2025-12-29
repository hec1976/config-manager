
# Config Manager — global.json

## Übersicht
Die Datei `global.json` enthält die **globalen Einstellungen** für den **Config Manager**. Sie definiert Netzwerk-, Sicherheits-, Logging- und Systemparameter, die das Verhalten der Anwendung steuern.

Diese Anleitung erklärt alle verfügbaren Felder und deren Verwendung.

---

## Struktur der global.json
Die `global.json` ist ein JSON-Objekt mit den folgenden Feldern:

```json
{
  "listen": "0.0.0.0:8080",
  "ssl_enable": false,
  "ssl_cert_file": "",
  "ssl_key_file": "",
  "secret": "change-this-long-random-secret-please",
  "logfile": "/var/log/config-manager.log",
  "backupDir": "./backup",
  "tmpDir": "./tmp",
  "apply_meta": 0,
  "auto_create_backups": 1,
  "fsync_dir": 1,
  "path_guard": "audit",
  "allowed_roots": [
    "/etc",
    "/opt/configs"
  ],
  "allowed_ips": [
    "127.0.0.1/32",
    "::1/128"
  ],
  "api_token": "changeme",
  "trusted_proxies": [],
  "allow_origins": [
    "*"
  ],
  "systemctl": "/usr/bin/systemctl",
  "systemctl_flags": "",
  "script_timeout": 60
}
```

---

## Felder im Detail

### Netzwerk
| Feld            | Typ          | Beschreibung                                                                                     | Standardwert                     |
|-----------------|--------------|-------------------------------------------------------------------------------------------------|----------------------------------|
| `listen`        | String       | Adresse und Port, auf denen der Server lauschen soll.                                           | `"0.0.0.0:3000"`                |
| `ssl_enable`    | Boolean      | Aktiviert HTTPS.                                                                                 | `false`                          |
| `ssl_cert_file` | String       | Pfad zur SSL-Zertifikatsdatei.                                                                   | `""`                            |
| `ssl_key_file`  | String       | Pfad zur SSL-Schlüsseldatei.                                                                     | `""`                            |

### Sicherheit
| Feld               | Typ          | Beschreibung                                                                                     | Standardwert                     |
|--------------------|--------------|-------------------------------------------------------------------------------------------------|----------------------------------|
| `secret`          | String       | **Wichtig!** Geheimnis für Mojolicious-Sessions. **Ändere dies unbedingt!**                       | `"change-this-long-random-secret-please"` |
| `api_token`       | String       | API-Token für die Authentifizierung. **Ändere dies unbedingt!**                                   | `"changeme"`                   |
| `allowed_ips`     | Array        | Liste der erlaubten IP-Adressen oder CIDR-Blöcke.                                                | `[]`                             |
| `trusted_proxies` | Array        | Liste der vertrauenswürdigen Proxy-IPs für X-Forwarded-For.                                      | `[]`                             |
| `allow_origins`   | Array        | Erlaubte Ursprünge für CORS.                                                                      | `[]`                             |
| `path_guard`      | String       | Modus für die Pfadvalidierung (`"off"`, `"audit"`).                                           | `"off"`                         |
| `allowed_roots`   | Array        | Liste der erlaubten Stammverzeichnisse für Konfigurationsdateien.                                | `[]`                             |

### Verzeichnisse
| Feld        | Typ          | Beschreibung                                                                                     | Standardwert                     |
|-------------|--------------|-------------------------------------------------------------------------------------------------|----------------------------------|
| `backupDir` | String       | Verzeichnis für Backups.                                                                         | `"./backup"`                   |
| `tmpDir`    | String       | Verzeichnis für temporäre Dateien.                                                               | `"./tmp"`                      |

### System
| Feld               | Typ          | Beschreibung                                                                                     | Standardwert                     |
|--------------------|--------------|-------------------------------------------------------------------------------------------------|----------------------------------|
| `systemctl`        | String       | Pfad zur systemctl-Binärdatei.                                                                    | `"/usr/bin/systemctl"`         |
| `systemctl_flags`  | String       | Flags, die an systemctl übergeben werden.                                                       | `""`                            |
| `script_timeout`   | Integer      | Timeout für Skripte in Sekunden.                                                                 | `30`                             |

### Funktionen
| Feld                  | Typ          | Beschreibung                                                                                     | Standardwert                     |
|-----------------------|--------------|-------------------------------------------------------------------------------------------------|----------------------------------|
| `apply_meta`         | Boolean      | Aktiviert das Anwenden von Metadaten (Benutzer, Gruppe, Modus) auf Konfigurationsdateien.      | `true`                           |
| `auto_create_backups`| Boolean      | Erstellt Backup-Verzeichnisse automatisch, falls sie nicht existieren.                          | `false`                          |
| `fsync_dir`          | Boolean      | Aktiviert fsync für Verzeichnisse.                                                               | `false`                          |

### Logging
| Feld      | Typ          | Beschreibung                                                                                     | Standardwert                     |
|-----------|--------------|-------------------------------------------------------------------------------------------------|----------------------------------|
| `logfile` | String       | Pfad zur Logdatei.                                                                               | `"/var/log/config-manager.log"` |

---

## Felder erklärt

### `listen`
- Adresse und Port, auf denen der Server lauschen soll.
- Beispiel: `"0.0.0.0:8080"` (alle Schnittstellen, Port 8080).

### `ssl_enable`, `ssl_cert_file`, `ssl_key_file`
- Aktiviert HTTPS, falls `ssl_enable` auf `true` gesetzt ist.
- `ssl_cert_file` und `ssl_key_file` müssen auf gültige Zertifikats- und Schlüsseldateien zeigen.
- Beispiel:
  ```json
  "ssl_enable": true,
  "ssl_cert_file": "/etc/ssl/certs/config-manager.crt",
  "ssl_key_file": "/etc/ssl/private/config-manager.key"
  ```

### `secret`
- **Wichtig!** Dieses Geheimnis wird für Mojolicious-Sessions verwendet.
- **Ändere dies unbedingt in eine zufällige, lange Zeichenkette!**
- Beispiel: `"secret": "dein-geheimes-passwort-hier"`.

### `api_token`
- API-Token für die Authentifizierung.
- **Ändere dies unbedingt in ein sicheres Token!**
- Beispiel: `"api_token": "sicherer-api-token"`.

### `logfile`
- Pfad zur Logdatei.
- Beispiel: `"logfile": "/var/log/config-manager.log"`.

### `backupDir`
- Verzeichnis, in dem Backups gespeichert werden.
- Beispiel: `"backupDir": "/var/backups/config-manager"`.

### `tmpDir`
- Verzeichnis für temporäre Dateien.
- Beispiel: `"tmpDir": "/tmp/config-manager"`.

### `apply_meta`
- Legt fest, ob Metadaten (Benutzer, Gruppe, Modus) auf Konfigurationsdateien angewendet werden sollen.
- `1` oder `true`: aktiviert.
- `0` oder `false`: deaktiviert.

### `auto_create_backups`
- Erstellt Backup-Verzeichnisse automatisch, falls sie nicht existieren.
- `1` oder `true`: aktiviert.
- `0` oder `false`: deaktiviert.

### `fsync_dir`
- Aktiviert fsync für Verzeichnisse, um sicherzustellen, dass Änderungen auf die Platte geschrieben werden.
- `1` oder `true`: aktiviert.
- `0` oder `false`: deaktiviert.

### `path_guard`
- Modus für die Pfadvalidierung:
  - `"off"`: Keine Validierung.
  - `"audit"`: Validierung mit Warnungen im Log.
- Beispiel: `"path_guard": "audit"`.

### `allowed_roots`
- Liste der erlaubten Stammverzeichnisse für Konfigurationsdateien.
- Beispiel:
  ```json
  "allowed_roots": ["/etc", "/opt/configs"]
  ```

### `allowed_ips`
- Liste der erlaubten IP-Adressen oder CIDR-Blöcke.
- Beispiel:
  ```json
  "allowed_ips": ["127.0.0.1/32", "192.168.1.0/24", "::1/128"]
  ```

### `trusted_proxies`
- Liste der vertrauenswürdigen Proxy-IPs, von denen X-Forwarded-For-Header akzeptiert werden.
- Beispiel:
  ```json
  "trusted_proxies": ["192.168.1.1", "10.0.0.1"]
  ```

### `allow_origins`
- Erlaubte Ursprünge für CORS (Cross-Origin Resource Sharing).
- `"*"` erlaubt alle Ursprünge.
- Beispiel:
  ```json
  "allow_origins": ["https://example.com", "https://api.example.com"]
  ```

### `systemctl`, `systemctl_flags`
- Pfad zur systemctl-Binärdatei und Flags, die an systemctl übergeben werden.
- Beispiel:
  ```json
  "systemctl": "/usr/bin/systemctl",
  "systemctl_flags": "--no-pager"
  ```

### `script_timeout`
- Timeout für Skripte in Sekunden.
- Beispiel: `"script_timeout": 60`.

---

## Beispiel für eine vollständige global.json
```json
{
  "listen": "0.0.0.0:8080",
  "ssl_enable": false,
  "ssl_cert_file": "",
  "ssl_key_file": "",
  "secret": "dein-geheimes-passwort-hier",
  "logfile": "/var/log/config-manager.log",
  "backupDir": "/var/backups/config-manager",
  "tmpDir": "/tmp/config-manager",
  "apply_meta": 1,
  "auto_create_backups": 1,
  "fsync_dir": 1,
  "path_guard": "audit",
  "allowed_roots": [
    "/etc",
    "/opt/configs"
  ],
  "allowed_ips": [
    "127.0.0.1/32",
    "192.168.1.0/24",
    "::1/128"
  ],
  "api_token": "sicherer-api-token",
  "trusted_proxies": ["192.168.1.1"],
  "allow_origins": ["https://example.com"],
  "systemctl": "/usr/bin/systemctl",
  "systemctl_flags": "--no-pager",
  "script_timeout": 60
}
```

---

## Best Practices

1. **Sicherheit:**
   - Ändere `secret` und `api_token` in sichere, zufällige Werte.
   - Beschränke `allowed_ips` auf vertrauenswürdige Netzwerke.
   - Nutze `path_guard` im `"audit"`-Modus, um unerlaubte Pfade zu erkennen.

2. **Verzeichnisse:**
   - Stelle sicher, dass `backupDir` und `tmpDir` existieren und beschreibbar sind.
   - Verwende absolute Pfade für `backupDir` und `tmpDir`.

3. **Netzwerk:**
   - Nutze HTTPS im Produktionsbetrieb (`ssl_enable`: `true`).
   - Beschränke `listen` auf spezifische Schnittstellen, falls möglich.

4. **Logging:**
   - Stelle sicher, dass das Log-Verzeichnis existiert und beschreibbar ist.

5. **System:**
   - Passe `systemctl_flags` an, falls spezielle Flags benötigt werden.

---

## Lizenz
Dieses Projekt steht unter der MIT-Lizenz.

## Support
Für Fragen oder Probleme öffne bitte ein Issue im Projekt-Repository.
