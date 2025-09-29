#!/usr/bin/env bash
set -euo pipefail
APP_DIR=${APP_DIR:-/opt/config-manager}

sudo mkdir -p "$APP_DIR"
sudo cp -r bin "$APP_DIR/"
sudo cp global.json "$APP_DIR/"
sudo cp configs.json "$APP_DIR/"
sudo mkdir -p "$APP_DIR/backup" "$APP_DIR/tmp"

sudo cp systemd/config-manager.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now config-manager
echo "Deployed to $APP_DIR and service started."
