# Proxmox PowerScheduler

Automated, schedule-based power management for Proxmox VE. Automatically stops and starts LXC containers (and optionally VMs) based on daily schedules in prioritized stages.

---

## 🚀 Features

- **⏰ Individual Daily Schedules:** Configure exact START and STOP times (`HH:MM`) for each weekday. Supports overnight spans.
- **🔄 Dynamic Hot-Reloading:** The service automatically reloads the configuration every 30s. No service restarts required for config edits.
- **🏷️ Staged Tag Orchestration:** `power-start-first` -> Default (untagged) -> `power-start-last` (and vice-versa for shutdown).
- **🖥️ LXC & VM Support:** Native LXC support; optional QEMU/KVM VM support via `ENABLE_VMS=true` (disabled by default).
- **🛡️ State & I/O Protection:** Only wakes up guests that were running before shutdown. Staggered starts avoid disk I/O spikes.
- **⚡ Zero Overhead:** Lightweight background systemd service (< 0.1% CPU/RAM).

---

## 🏷️ Proxmox Tags

Tags are automatically registered in Proxmox upon install and selectable in the Web GUI under **Guest -> Tags**:

| Tag | Start Order | Stop Order |
| :--- | :--- | :--- |
| `power-ignore` | 24/7 (Never touched) | 24/7 (Never touched) |
| `power-start-first` | **1st** (before others) | — |
| *(no tag)* | **2nd** (Default in middle) | **2nd** (Default in middle) |
| `power-start-last` | **3rd** (after others) | — |
| `power-stop-first` | — | **1st** (before others) |
| `power-stop-last` | — | **3rd** (after others) |

> Flow: `First` -> wait `STAGE_DELAY_SECONDS` (default: 5s) -> `Default` -> wait -> `Last`

---

## ⚙️ Configuration

The configuration file is **`pve-powerscheduler.conf`**:
- Located in your cloned repository folder, and installed to `/etc/pve-powerscheduler/pve-powerscheduler.conf`.
- Changes are **hot-reloaded dynamically** every 30 seconds.

Key options:
```bash
ENABLE_VMS=false          # Set to true to include QEMU/KVM VMs

# Daily wake-up (START) and shutdown (STOP) times (HH:MM)
MON_START="08:00"; MON_STOP="22:30"
TUE_START="08:30"; TUE_STOP="22:30"
WED_START="08:00"; WED_STOP="22:30"
THU_START="08:00"; THU_STOP="22:30"
FRI_START="08:00"; FRI_STOP="03:00"   # Stays active until Saturday 03:00 AM
SAT_START="09:00"; SAT_STOP="03:00"
SUN_START="09:00"; SUN_STOP="22:30"

STAGE_DELAY_SECONDS=5     # Pause between priority stages
START_DELAY_SECONDS=2     # Pause between individual guest starts (I/O smoothing)
```

---

## 📦 Installation

```bash
git clone https://github.com/YozouChan/proxmox-power-scheduler.git
cd proxmox-power-scheduler
chmod +x install.sh
sudo ./install.sh
```

---

## 🛠 CLI Commands

| Command | Description |
| :--- | :--- |
| `pve-powerscheduler status` | View service status, weekly schedule, tags, and active/shutdown mode. |
| `pve-powerscheduler stop-all` | Staged shutdown of active guests (`stop-first` -> Default -> `stop-last`). |
| `pve-powerscheduler start-all` | Staged startup of saved guests (`start-first` -> Default -> `start-last`). |
| `pve-powerscheduler register-tags` | Re-registers tags in Proxmox Datacenter (if renamed in config). |
| `pve-powerscheduler disable` | Pauses/disables the background service. |
| `pve-powerscheduler enable` | Enables and starts the background service. |

---

## 🗑 Uninstallation

Run the uninstallation script to stop the service, remove all binaries/configs, and automatically clean up the tags from Proxmox Datacenter, LXCs, and VMs:

```bash
chmod +x uninstall.sh
sudo ./uninstall.sh
```

---

## 🤖 Disclaimer / AI Notice

The documentation in this README and all code comments within this project were generated and structured with the assistance of AI.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).