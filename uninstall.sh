#!/usr/bin/env bash

set -e

echo "=== Proxmox PowerScheduler - Uninstallation ==="

if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run uninstallation as root/sudo."
    exit 1
fi

# 1. Stop and disable systemd service
echo "[1/5] Stopping and disabling systemd service..."
systemctl stop pve-powerscheduler.service 2>/dev/null || true
systemctl disable pve-powerscheduler.service 2>/dev/null || true
rm -f /etc/systemd/system/pve-powerscheduler.service
systemctl daemon-reload

# 2. Remove binary
echo "[2/5] Removing binary from /usr/local/bin/pve-powerscheduler..."
rm -f /usr/local/bin/pve-powerscheduler

# 3. Remove runtime state and configuration
echo "[3/5] Removing state and configuration directories..."
rm -rf /var/lib/pve-powerscheduler
rm -rf /etc/pve-powerscheduler

# 4. Remove tags from Proxmox Datacenter Options
echo "[4/5] Removing PowerScheduler tags from Proxmox Datacenter..."
tags_to_remove=("power-ignore" "power-start-first" "power-start-last" "power-stop-first" "power-stop-last" "power-start-1" "power-start-2" "power-start-3" "power-stop-1" "power-stop-2" "power-stop-3")

is_tag_to_remove() {
    local check="$1"
    for r in "${tags_to_remove[@]}"; do
        [ "$check" = "$r" ] && return 0
    done
    return 1
}

if command -v pvesh >/dev/null 2>&1; then
    current_tags=""
    if [ -f /etc/pve/datacenter.cfg ]; then
        current_tags=$(grep -E '^\s*registered-tags:' /etc/pve/datacenter.cfg 2>/dev/null | sed -E 's/^\s*registered-tags:\s*//')
    fi
    if [ -z "$current_tags" ]; then
        current_tags=$(pvesh get /cluster/options --output-format json 2>/dev/null | grep -o '"registered-tags":\s*"[^"]*"' | cut -d'"' -f4)
    fi

    if [ -n "$current_tags" ]; then
        new_registered_tags=""
        IFS=';' read -ra tag_arr <<< "$current_tags"
        for t in "${tag_arr[@]}"; do
            [ -z "$t" ] && continue
            if ! is_tag_to_remove "$t"; then
                if [ -z "$new_registered_tags" ]; then
                    new_registered_tags="$t"
                else
                    new_registered_tags="${new_registered_tags};${t}"
                fi
            fi
        done

        if [ -n "$new_registered_tags" ]; then
            pvesh set /cluster/options --registered-tags "$new_registered_tags" >/dev/null 2>&1 || true
            echo "Updated registered tags in Proxmox Datacenter (retained other custom tags)."
        else
            pvesh set /cluster/options --delete registered-tags >/dev/null 2>&1 || pvesh set /cluster/options --registered-tags "" >/dev/null 2>&1 || true
            echo "Removed all PowerScheduler registered tags from Proxmox Datacenter."
        fi
    fi
fi

# 5. Clean up tags from individual LXC containers and VMs
echo "[5/5] Cleaning up tags from LXCs and VMs..."
if command -v pct >/dev/null 2>&1; then
    for ctid in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
        raw_tags=$(pct config "$ctid" 2>/dev/null | grep -E '^tags:' | sed 's/^tags:[[:space:]]*//' | tr ';,' ' ')
        new_guest_tags=""
        changed=false
        for t in $raw_tags; do
            if is_tag_to_remove "$t"; then
                changed=true
            else
                new_guest_tags="${new_guest_tags},${t}"
            fi
        done
        if [ "$changed" = true ]; then
            new_guest_tags=$(echo "$new_guest_tags" | sed 's/^,//')
            if [ -n "$new_guest_tags" ]; then
                pct set "$ctid" -tags "$new_guest_tags" >/dev/null 2>&1 || true
            else
                pct set "$ctid" -delete tags >/dev/null 2>&1 || pct set "$ctid" -tags "" >/dev/null 2>&1 || true
            fi
            echo "Cleaned tags from LXC $ctid."
        fi
    done
fi

if command -v qm >/dev/null 2>&1; then
    for vmid in $(qm list 2>/dev/null | awk 'NR>1 {print $1}'); do
        raw_tags=$(qm config "$vmid" 2>/dev/null | grep -E '^tags:' | sed 's/^tags:[[:space:]]*//' | tr ';,' ' ')
        new_guest_tags=""
        changed=false
        for t in $raw_tags; do
            if is_tag_to_remove "$t"; then
                changed=true
            else
                new_guest_tags="${new_guest_tags},${t}"
            fi
        done
        if [ "$changed" = true ]; then
            new_guest_tags=$(echo "$new_guest_tags" | sed 's/^,//')
            if [ -n "$new_guest_tags" ]; then
                qm set "$vmid" -tags "$new_guest_tags" >/dev/null 2>&1 || true
            else
                qm set "$vmid" -delete tags >/dev/null 2>&1 || qm set "$vmid" -tags "" >/dev/null 2>&1 || true
            fi
            echo "Cleaned tags from VM $vmid."
        fi
    done
fi

echo ""
echo "=== Uninstallation completed successfully! ==="
echo "Proxmox PowerScheduler, its service, configuration, and tags have been removed."