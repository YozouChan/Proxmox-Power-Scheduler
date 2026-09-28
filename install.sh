#!/usr/bin/env bash

set -e

echo "=== Proxmox PowerScheduler - Installation ==="

if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this installation as root/sudo."
    exit 1
fi

# 1. Set up configuration directory and default config
echo "[1/4] Setting up configuration in /etc/pve-powerscheduler..."
mkdir -p /etc/pve-powerscheduler
if [ -f /etc/pve-powerscheduler/pve-powerscheduler.conf ]; then
    echo "Existing configuration found. Preserving /etc/pve-powerscheduler/pve-powerscheduler.conf."
    cp pve-powerscheduler.conf /etc/pve-powerscheduler/pve-powerscheduler.conf.example
else
    cp pve-powerscheduler.conf /etc/pve-powerscheduler/pve-powerscheduler.conf
    echo "Default configuration copied to /etc/pve-powerscheduler/pve-powerscheduler.conf."
fi

# 2. Copy binary and set permissions
echo "[2/4] Copying script to /usr/local/bin/pve-powerscheduler..."
cp pve-powerscheduler.sh /usr/local/bin/pve-powerscheduler
chmod +x /usr/local/bin/pve-powerscheduler

# 3. Automatically register tags in Proxmox cluster
echo "[3/4] Registering tags in Proxmox VE..."
/usr/local/bin/pve-powerscheduler register-tags || true

# 4. Install and enable systemd service
echo "[4/4] Installing and starting systemd service..."
cp pve-powerscheduler.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pve-powerscheduler.service

echo ""
echo "=== Installation completed successfully! ==="
echo "Configuration file: /etc/pve-powerscheduler/pve-powerscheduler.conf"
echo "Run 'pve-powerscheduler status' to check current status and schedule."