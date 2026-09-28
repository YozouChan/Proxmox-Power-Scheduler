# Proxmox PowerScheduler

An automated, time- and weekday-based power management system for Proxmox VE. It automatically stops and starts LXC containers (and optionally QEMU/KVM Virtual Machines) according to individual daily schedules and prioritized stages, ensuring maximum energy efficiency and seamless orchestration.

---

## 🚀 Features

- **⏰ Individual Day-by-Day Schedules (24h `HH:MM` format):**
  - Set exact **START** (wake-up) and **STOP** (shutdown) times individually for every single day of the week (e.g. Monday 22:30 Stop, Tuesday 08:30 Start).
  - Supports overnight spans (e.g., Friday start at 08:00 and stop at 03:00 on Saturday morning).
- **🖥️ Multi-Guest Support (LXC Containers & VMs):**
  - Native support for LXC containers (`pct`).
  - Optional support for QEMU/KVM Virtual Machines (`qm`) via `ENABLE_VMS=true` (disabled by default to prevent unintentional VM shutdowns).
- **🏷️ Intuitive Staged Proxmox Tag Integration:**
  - **Blacklist / Exclusion Tag (`power-ignore`):** Guests with this tag run 24/7 and are completely excluded from automatic shutdowns.
  - **Start Flow:** `power-start-first` (runs first) -> wait 5s -> `Default` (untagged guests) -> wait 5s -> `power-start-last` (runs last).
  - **Stop Flow:** `power-stop-first` (runs first) -> wait 5s -> `Default` (untagged guests) -> wait 5s -> `power-stop-last` (runs last).
  - **Configurable Stage Delays:** The waiting time between stages is fully configurable in seconds (`STAGE_DELAY_SECONDS`).
  - **Automatic Cluster Registration:** All tags are automatically registered in Proxmox Datacenter Options upon installation, making them instantly selectable via the Proxmox Web GUI dropdown/autocomplete.
- **🧠 Intelligent State Restoration:**
  - Starts up **only** those guests that were actively running prior to the scheduled shutdown.
  - Manually or intentionally stopped guests remain powered off.
- **🛡️ Storage & Host I/O Protection:**
  - Staggered guest starts with configurable delays prevent massive I/O load spikes on storage and CPU.
- **⚡ Minimal Footprint:**
  - Runs as a lightweight systemd background service consuming virtually zero resources (< 0.1% CPU/RAM).

---

## 🏷️ Proxmox Tags in Detail

The tags are automatically registered in Proxmox during installation and can be assigned to any LXC container or VM in the Web GUI under **Guest -> Tags**:

| Tag | Start Behavior | Stop Behavior |
| :--- | :--- | :--- |
| `power-ignore` | Never touched (runs 24/7) | Never touched (runs 24/7) |
| `power-start-first` | Powered on **FIRST** (before all other guests, e.g. databases, shared storage) | — |
| *(no start tag)* | Powered on **IN THE MIDDLE** (after `power-start-first` finishes + delay) | — |
| `power-start-last` | Powered on **LAST** (after all default guests finish + delay, e.g. web frontends) | — |
| `power-stop-first` | — | Powered off **FIRST** (before all other guests, e.g. web frontends, ingress) |
| *(no stop tag)* | — | Powered off **IN THE MIDDLE** (after `power-stop-first` finishes + delay) |
| `power-stop-last` | — | Powered off **LAST** (after all default guests finish + delay, e.g. core databases) |

> [!TIP]
> The stage delay (default: 5 seconds), individual container I/O pause (default: 2 seconds), and tag names can be customized in the configuration file.

---

## ⚙️ Configuration

The configuration file is located at `/etc/pve-powerscheduler/pve-powerscheduler.conf`:

```bash
# Enable power scheduling for QEMU/KVM Virtual Machines (Default: false)
ENABLE_VMS=false

# ------------------------------------------------------------------------------
# ⏰ WEEKLY SCHEDULE (24h format HH:MM)
# ------------------------------------------------------------------------------
# Configure individual START (wake-up) and STOP (shutdown) times for each weekday.

# Monday
MON_START="08:00"
MON_STOP="22:30"

# Tuesday
TUE_START="08:30"
TUE_STOP="22:30"

# Wednesday
WED_START="08:00"
WED_STOP="22:30"

# Thursday
THU_START="08:00"
THU_STOP="22:30"

# Friday (stays active past midnight until 03:00 Saturday morning)
FRI_START="08:00"
FRI_STOP="03:00"

# Saturday (stays active past midnight until 03:00 Sunday morning)
SAT_START="09:00"
SAT_STOP="03:00"

# Sunday
SUN_START="09:00"
SUN_STOP="22:30"

# ------------------------------------------------------------------------------
# ⏳ DELAYS (in seconds)
# ------------------------------------------------------------------------------
# Delay between priority stages (First -> wait -> Default -> wait -> Last)
STAGE_DELAY_SECONDS=5

# Short pause between individual guest starts (smoothes I/O spikes)
START_DELAY_SECONDS=2

# ------------------------------------------------------------------------------
# 🏷️ PROXMOX TAGS
# ------------------------------------------------------------------------------
TAG_IGNORE="power-ignore"

# Start sequence: power-start-first -> wait -> Default (untagged) -> wait -> power-start-last
TAG_START_FIRST="power-start-first"
TAG_START_LAST="power-start-last"

# Stop sequence: power-stop-first -> wait -> Default (untagged) -> wait -> power-stop-last
TAG_STOP_FIRST="power-stop-first"
TAG_STOP_LAST="power-stop-last"
```

Changes made to the configuration take effect immediately after restarting the service (`systemctl restart pve-powerscheduler.service`). If you change tag names, you can re-register them in Proxmox Datacenter using `pve-powerscheduler register-tags`.

---

## 📋 Prerequisites

- Proxmox VE (PVE 7.x / 8.x)
- Root access on the Proxmox host

---

## 📦 Installation

```bash
git clone https://github.com/YozouChan/proxmox-power-scheduler.git
cd proxmox-power-scheduler
chmod +x install.sh
sudo ./install.sh
```

The installer will:
1. Create the configuration directory and install `/etc/pve-powerscheduler/pve-powerscheduler.conf`.
2. Install the CLI tool to `/usr/local/bin/pve-powerscheduler`.
3. Automatically register all tags in Proxmox VE Datacenter Options.
4. Set up and start the background systemd service (`pve-powerscheduler.service`).

---

## 🛠 Usage & CLI Commands

Once installed, the `pve-powerscheduler` command is available globally on the Proxmox host.

| Command | Description |
| :--- | :--- |
| `pve-powerscheduler status` | Displays service status, VM enablement, full weekly schedule table, active tags, and current day/night target mode. |
| `pve-powerscheduler stop-all` | Shuts down all active guests in configured priority stages (`power-stop-first` -> wait -> Default -> wait -> `power-stop-last`), respecting the blacklist tag. |
| `pve-powerscheduler start-all` | Starts all saved/stopped guests in configured priority stages (`power-start-first` -> wait -> Default -> wait -> `power-start-last`). |
| `pve-powerscheduler register-tags` | Re-registers configured tags into Proxmox VE (e.g. after changing tag names in config). |
| `pve-powerscheduler disable` | Pauses/disables the automatic background service (useful for maintenance). |
| `pve-powerscheduler enable` | Enables and starts the automatic background service. |

---

## 🗑 Uninstallation

To completely remove the script, service, and configuration from your system:

```bash
pve-powerscheduler disable
rm -f /usr/local/bin/pve-powerscheduler
rm -f /etc/systemd/system/pve-powerscheduler.service
systemctl daemon-reload
rm -rf /var/lib/pve-powerscheduler
rm -rf /etc/pve-powerscheduler
```

---

## 🤖 Disclaimer / AI Notice

The documentation in this README, as well as all code comments throughout this project, were generated and structured with the assistance of AI.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).