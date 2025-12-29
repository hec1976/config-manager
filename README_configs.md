
# Config Manager — configs.json

## Übersicht
Die Datei `configs.json` definiert die Konfigurationen, die vom **Config Manager** verwaltet werden. Jeder Eintrag beschreibt eine Konfigurationsdatei, ihre Berechtigungen, zugehörige Dienste und erlaubte Aktionen.

Diese Anleitung erklärt die **tatsächlich unterstützten Felder** und deren Verwendung.

---

## Struktur der configs.json
Die `configs.json` ist ein JSON-Objekt, in dem jeder Schlüssel den Namen einer Konfiguration darstellt. Jeder Eintrag enthält die folgenden Felder:

```json
{
  "konfigurationsname": {
    "path": "/pfad/zur/datei",
    "category": "kategorie",
    "service": "dienstname",
    "actions": {
      "aktion1": ["arg1", "arg2"],
      "aktion2": []
    },
    "user": "benutzer",
    "group": "gruppe",
    "mode": "0644",
    "apply_meta": true
  }
}
```

---

## Unterstützte Felder

### Pflichtfelder
| Feld      | Typ          | Beschreibung                                                                                     |
|-----------|--------------|-------------------------------------------------------------------------------------------------|
| `path`    | String       | **Pflichtfeld.** Pfad zur Konfigurationsdatei.                                                   |
| `actions` | Objekt       | **Pflichtfeld.** Definiert die erlaubten Aktionen für diese Konfiguration.                       |

### Optionale Felder
| Feld         | Typ          | Beschreibung                                                                                     |
|--------------|--------------|-------------------------------------------------------------------------------------------------|
| `category`   | String       | Kategorie zur Gruppierung (z. B. `webserver`, `application`).                                   |
| `service`    | String       | Name des zugehörigen systemd-Dienstes (z. B. `nginx`).                                           |
| `user`       | String       | Benutzer, dem die Datei gehören soll. Standard: `root`.                                          |
| `group`      | String       | Gruppe, der die Datei gehören soll. Standard: `root`.                                           |
| `mode`       | String       | Dateiberechtigungen (z. B. `0644`). Standard: `0644`.                                            |
| `apply_meta` | Boolean      | Legt fest, ob Benutzer, Gruppe und Modus angewendet werden sollen. Standard: `true`.            |

---

## Felder erklärt

### `path`
- **Pflichtfeld.**
- Gibt den absoluten Pfad zur Konfigurationsdatei an.
- Beispiel: `"/etc/nginx/nginx.conf"`.

### `category`
- Dient der Gruppierung von Konfigurationen (z. B. `webserver`, `mail`, `security`).
- Wird in der API-Antwort (`/configs`) zurückgegeben, aber nicht funktional genutzt.
- Beispiel: `"category": "webserver"`.

### `service`
- Name des systemd-Dienstes, der mit dieser Konfiguration verknüpft ist.
- Wird für Aktionen wie `restart`, `reload` oder `status` verwendet.
- Beispiel: `"service": "nginx"`.

### `actions`
- **Pflichtfeld.**
- Definiert die Aktionen, die für diese Konfiguration ausgeführt werden dürfen.
- Jeder Schlüssel ist der Name der Aktion, der Wert ein Array von Argumenten.
- Beispiel:
  ```json
  "actions": {
    "reload": [],
    "restart": ["--no-block"],
    "run": ["/opt/scripts/restart_app.sh"]
  }
  ```

### `user`, `group`, `mode`
- Legt fest, wem die Datei gehören soll und welche Berechtigungen sie haben soll.
- Wird nur angewendet, wenn `apply_meta` auf `true` gesetzt ist.
- Beispiel:
  ```json
  "user": "appuser",
  "group": "appgroup",
  "mode": "0640"
  ```

### `apply_meta`
- Legt fest, ob die Metadaten (`user`, `group`, `mode`) auf die Datei angewendet werden sollen.
- Standard: `true`.
- Beispiel: `"apply_meta": true`.

---

## Beispiele

### 1. Nginx-Konfiguration
```json
"nginx_conf": {
  "path": "/etc/nginx/nginx.conf",
  "category": "webserver",
  "service": "nginx",
  "actions": {
    "status": [],
    "reload": [],
    "restart": []
  },
  "user": "root",
  "group": "root",
  "mode": "0644",
  "apply_meta": true
}
```

### 2. Umgebungsvariablen
```json
"app_env": {
  "path": "/opt/configs/app.env",
  "category": "application",
  "actions": {
    "run": ["/opt/scripts/restart_app.sh"]
  },
  "user": "appuser",
  "group": "appgroup",
  "mode": "0640",
  "apply_meta": true
}
```

### 3. Postfix-Konfiguration
```json
"postfix_main_cf": {
  "path": "/etc/postfix/main.cf",
  "category": "mail",
  "service": "postfix",
  "actions": {
    "reload": [],
    "check": ["postfix", "check"]
  },
  "user": "root",
  "group": "postfix",
  "mode": "0640",
  "apply_meta": true
}
```

---

## Best Practices

1. **Kategorien nutzen:** Verwende klare Kategorien wie `webserver`, `database`, `security`, um Konfigurationen zu gruppieren.
2. **Berechtigungen einschränken:** Verwende spezifische Benutzer und Gruppen (z. B. `appuser:appgroup` statt `root:root`).
3. **Aktionen sinnvoll wählen:** Definiere nur Aktionen, die für die Konfiguration relevant sind (z. B. `reload` für Nginx, `check` für Postfix).
4. **`apply_meta` nutzen:** Aktiviere `apply_meta`, um sicherzustellen, dass Berechtigungen korrekt gesetzt werden.

---

## Integration mit dem Config Manager

### Kompatibilität
Die `configs.json` ist vollständig kompatibel mit dem **Config Manager**-Skript (`config-manager.pl`). Das Skript unterstützt **nur die oben genannten Felder**.

### Backups
- Backups werden standardmäßig im Verzeichnis `<backupRoot>/<name>` gespeichert.
- Die maximale Anzahl der Backups wird global in der `global.json` (`maxBackups`) definiert.

---

## Beispiel für eine vollständige configs.json
```json
{
  "nginx_conf": {
    "path": "/etc/nginx/nginx.conf",
    "category": "webserver",
    "service": "nginx",
    "actions": {
      "status": [],
      "reload": [],
      "restart": []
    },
    "user": "root",
    "group": "root",
    "mode": "0644",
    "apply_meta": true
  },

  "app_env": {
    "path": "/opt/configs/app.env",
    "category": "application",
    "actions": {
      "run": ["/opt/scripts/restart_app.sh"]
    },
    "user": "appuser",
    "group": "appgroup",
    "mode": "0640",
    "apply_meta": true
  }
}
```

---

## Nicht unterstützte Felder
Die folgenden Felder werden **nicht** vom Skript verarbeitet und sollten vermieden werden:
- `backup_dir`
- `max_backups`
- `description`
- `validation`

Falls du diese Felder nutzen möchtest, musst du das Skript entsprechend erweitern.

---

## Lizenz
Dieses Projekt steht unter der MIT-Lizenz.

## Support
Für Fragen oder Probleme öffne bitte ein Issue im Projekt-Repository.
