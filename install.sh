#!/usr/bin/env bash

set -e

echo "=== Proxmox PowerScheduler - Installation ==="

if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this installation as root/sudo."
    exit 1
fi

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Set permissions and create symlink in /usr/local/bin
echo "[1/3] Creating symlink in /usr/local/bin/pve-powerscheduler..."
chmod +x "${INSTALL_DIR}/pve-powerscheduler.sh"
ln -sf "${INSTALL_DIR}/pve-powerscheduler.sh" /usr/local/bin/pve-powerscheduler

# 2. Automatically register tags in Proxmox cluster
echo "[2/3] Registering tags in Proxmox VE..."
/usr/local/bin/pve-powerscheduler register-tags || true

# 3. Install and enable systemd service
echo "[3/3] Installing and starting systemd service..."
cp "${INSTALL_DIR}/pve-powerscheduler.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pve-powerscheduler.service

echo ""
echo "=== Installation completed successfully! ==="
echo "Configuration file: ${INSTALL_DIR}/pve-powerscheduler.conf"
echo "Run 'pve-powerscheduler status' to check current status and schedule."
