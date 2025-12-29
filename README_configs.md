
# Config Manager — configs.json

## Übersicht
Die Datei `configs.json` definiert die Konfigurationen, die vom **Config Manager** verwaltet werden. Jeder Eintrag beschreibt eine Konfigurationsdatei, ihre Berechtigungen, zugehörige Dienste, erlaubte Aktionen und optionale Metadaten wie Backups oder Validierungen.

Diese Anleitung erklärt die Struktur, Felder und Best Practices für die `configs.json`.

---

## Struktur der configs.json
Die `configs.json` ist ein JSON-Objekt, in dem jeder Schlüssel den Namen einer Konfiguration darstellt. Jeder Eintrag enthält die folgenden Felder:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$comment": "Config Manager — configs.json (v1.6.7)",
  "description": "Definiert die zu verwaltenden Konfigurationen, inkl. Pfade, Aktionen, Berechtigungen und Metadaten.",

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
    "apply_meta": true,
    "backup_dir": "/pfad/zu/backups",
    "max_backups": 5,
    "description": "Beschreibung der Konfiguration",
    "validation": {
      "required_vars": ["VAR1", "VAR2"],
      "template": "/pfad/zur/vorlage"
    }
  }
}
```

---

## Felder im Detail

### Pflichtfelder
| Feld          | Typ          | Beschreibung                                                                                     |
|---------------|--------------|-------------------------------------------------------------------------------------------------|
| `path`        | String       | **Pflichtfeld.** Pfad zur Konfigurationsdatei.                                                   |
| `actions`     | Objekt       | **Pflichtfeld.** Definiert die erlaubten Aktionen für diese Konfiguration.                       |

### Optionale Felder
| Feld          | Typ          | Beschreibung                                                                                     |
|---------------|--------------|-------------------------------------------------------------------------------------------------|
| `category`    | String       | Kategorie zur Gruppierung (z. B. `webserver`, `application`, `mail`).                            |
| `service`     | String       | Name des zugehörigen systemd-Dienstes (z. B. `nginx`).                                           |
| `user`        | String       | Benutzer, dem die Datei gehören soll. Standard: `root`.                                          |
| `group`       | String       | Gruppe, der die Datei gehören soll. Standard: `root`.                                           |
| `mode`        | String       | Dateiberechtigungen (z. B. `0644`). Standard: `0644`.                                            |
| `apply_meta`  | Boolean      | Legt fest, ob Benutzer, Gruppe und Modus angewendet werden sollen. Standard: `true`.            |
| `backup_dir`  | String       | Individueller Pfad für Backups. Standard: `<backupRoot>/<name>`.                                 |
| `max_backups` | Integer      | Maximale Anzahl der Backups. Überschreibt den globalen Wert.                                    |
| `description` | String       | Beschreibung der Konfiguration.                                                                 |
| `validation`  | Objekt       | Definiert Validierungsregeln (z. B. erforderliche Variablen oder eine Vorlage).                 |

---

## Felder erklärt

### `path`
- **Pflichtfeld.**
- Gibt den absoluten Pfad zur Konfigurationsdatei an.
- Beispiel: `"/etc/nginx/nginx.conf"`.

### `category`
- Dient der Gruppierung von Konfigurationen (z. B. `webserver`, `mail`, `security`).
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
    "check": ["postfix", "check"]
  }
  ```

### `user`, `group`, `mode`
- Legt fest, wem die Datei gehören soll und welche Berechtigungen sie haben soll.
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

### `backup_dir`
- Überschreibt den Standard-Backup-Pfad für diese Konfiguration.
- Beispiel: `"backup_dir": "/var/backups/nginx"`.

### `max_backups`
- Überschreibt die globale Einstellung für die maximale Anzahl der Backups.
- Beispiel: `"max_backups": 5`.

### `description`
- Beschreibung der Konfiguration, z. B. ihr Zweck oder Hinweise zur Bearbeitung.
- Beispiel: `"description": "Hauptkonfiguration für Nginx. Änderungen erfordern einen Reload."`.

### `validation`
- Definiert Regeln zur Validierung der Konfiguration.
- Unterstützt:
  - `required_vars`: Liste der erforderlichen Variablen (für z. B. `.env`-Dateien).
  - `template`: Pfad zu einer Vorlagendatei, mit der die Konfiguration verglichen wird.
- Beispiel:
  ```json
  "validation": {
    "required_vars": ["DB_HOST", "DB_USER"],
    "template": "/opt/templates/app.env.template"
  }
  ```

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
    "restart": ["--no-block"]
  },
  "user": "root",
  "group": "root",
  "mode": "0644",
  "apply_meta": true,
  "backup_dir": "/var/backups/nginx",
  "max_backups": 5,
  "description": "Hauptkonfiguration für Nginx. Änderungen erfordern einen Reload oder Restart."
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
  "apply_meta": true,
  "description": "Umgebungsvariablen für die Anwendung. Wird beim Deployment aktualisiert.",
  "validation": {
    "required_vars": ["DB_HOST", "DB_USER", "API_KEY"],
    "template": "/opt/templates/app.env.template"
  }
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
  "apply_meta": true,
  "description": "Postfix-Hauptkonfiguration. Nach Änderungen 'postfix check' ausführen."
}
```

---

## Best Practices

1. **Kategorien nutzen:** Verwende klare Kategorien wie `webserver`, `database`, `security`, um Konfigurationen zu gruppieren.
2. **Berechtigungen einschränken:** Verwende spezifische Benutzer und Gruppen (z. B. `appuser:appgroup` statt `root:root`).
3. **Beschreibungen hinzufügen:** Dokumentiere den Zweck und Besonderheiten jeder Konfiguration.
4. **Validierung nutzen:** Für kritische Konfigurationen (z. B. `.env`-Dateien) solltest du `required_vars` oder `template` verwenden.
5. **Backups individuell steuern:** Nutze `backup_dir` und `max_backups` für wichtige Konfigurationen.
6. **Aktionen sinnvoll wählen:** Definiere nur Aktionen, die für die Konfiguration relevant sind (z. B. `reload` für Nginx, `check` für Postfix).

---

## Integration mit dem Config Manager

### Kompatibilität
Die `configs.json` ist vollständig kompatibel mit dem **Config Manager**-Skript (`config-manager.pl`). Das Skript unterstützt alle oben genannten Felder und Funktionen.

### Erweiterte Funktionen
- **Validierung:** Die Validierung wird nicht direkt vom Skript durchgeführt, kann aber in Hooks oder Skripten (z. B. in `actions`) integriert werden.
- **Individuelle Backup-Pfade:** Das Skript verwendet standardmäßig `<backupRoot>/<name>`, aber du kannst dies durch Anpassen der Funktion `_backup_dir_for` im Skript ändern.

---

## Beispiel für eine vollständige configs.json
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$comment": "Config Manager — configs.json (v1.6.7)",
  "description": "Definiert die zu verwaltenden Konfigurationen, inkl. Pfade, Aktionen, Berechtigungen und Metadaten.",

  "nginx_conf": {
    "path": "/etc/nginx/nginx.conf",
    "category": "webserver",
    "service": "nginx",
    "actions": {
      "status": [],
      "reload": [],
      "restart": ["--no-block"]
    },
    "user": "root",
    "group": "root",
    "mode": "0644",
    "apply_meta": true,
    "backup_dir": "/var/backups/nginx",
    "max_backups": 5,
    "description": "Hauptkonfiguration für Nginx. Änderungen erfordern einen Reload oder Restart."
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
    "apply_meta": true,
    "description": "Umgebungsvariablen für die Anwendung. Wird beim Deployment aktualisiert.",
    "validation": {
      "required_vars": ["DB_HOST", "DB_USER", "API_KEY"],
      "template": "/opt/templates/app.env.template"
    }
  }
}
```

---

## Lizenz
Dieses Projekt steht unter der MIT-Lizenz.

## Support
Für Fragen oder Probleme öffne bitte ein Issue im Projekt-Repository.
