#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
sudo install -m 0755 wsl-proxy.sh /usr/local/sbin/wsl-proxy
sudo install -m 0644 wsl-proxy.service /etc/systemd/system/wsl-proxy.service
sudo systemctl daemon-reload
sudo systemctl enable wsl-proxy.service
sudo systemctl restart wsl-proxy.service
echo 'wsl-proxy.service installed, enabled, and started.'
