#!/usr/bin/env bash

# ==============================================================================
# Proxmox PowerScheduler
# Automated time- and weekday-based power management for Proxmox VE guests
# ==============================================================================

# Config & Paths (uses /etc if installed, or local repository folder as fallback)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
CONFIG_DIR="/etc/pve-powerscheduler"
CONFIG_FILE="${CONFIG_DIR}/pve-powerscheduler.conf"
if [ ! -f "$CONFIG_FILE" ] && [ -f "${SCRIPT_DIR}/pve-powerscheduler.conf" ]; then
    CONFIG_FILE="${SCRIPT_DIR}/pve-powerscheduler.conf"
    CONFIG_DIR="${SCRIPT_DIR}"
fi
STATE_DIR="/var/lib/pve-powerscheduler"
STATE_FILE="${STATE_DIR}/running_guests.list"
SERVICE_NAME="pve-powerscheduler.service"

# Default values
ENABLE_VMS=false

# Default weekly schedule (START and STOP times in HH:MM)
MON_START="08:00"; MON_STOP="22:30"
TUE_START="08:30"; TUE_STOP="22:30"
WED_START="08:00"; WED_STOP="22:30"
THU_START="08:00"; THU_STOP="22:30"
FRI_START="08:00"; FRI_STOP="03:00"
SAT_START="09:00"; SAT_STOP="03:00"
SUN_START="09:00"; SUN_STOP="22:30"

STAGE_DELAY_SECONDS=5
START_DELAY_SECONDS=2

TAG_IGNORE="power-ignore"
TAG_START_FIRST="power-start-first"
TAG_START_LAST="power-start-last"

TAG_STOP_FIRST="power-stop-first"
TAG_STOP_LAST="power-stop-last"

# Load configuration if present
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Compatibility fallback if previous tag variables were used in an existing config
TAG_START_FIRST="${TAG_START_FIRST:-${TAG_START_STAGE1:-${TAG_START_PRIO1:-power-start-first}}}"
TAG_START_LAST="${TAG_START_LAST:-${TAG_START_STAGE2:-${TAG_START_PRIO2:-power-start-last}}}"
TAG_STOP_FIRST="${TAG_STOP_FIRST:-${TAG_STOP_STAGE1:-${TAG_STOP_PRIO1:-power-stop-first}}}"
TAG_STOP_LAST="${TAG_STOP_LAST:-${TAG_STOP_STAGE2:-${TAG_STOP_PRIO2:-power-stop-last}}}"

mkdir -p "$STATE_DIR"

# ------------------------------------------------------------------------------
# Schedule Calculation Helpers
# ------------------------------------------------------------------------------
# Converts an HH:MM string to total minutes since midnight (0..1439)
time_to_minutes() {
    local t="$1"
    local h m
    h=$(echo "$t" | cut -d':' -f1 | sed 's/^0*//')
    m=$(echo "$t" | cut -d':' -f2 | sed 's/^0*//')
    [ -z "$h" ] && h=0
    [ -z "$m" ] && m=0
    echo $(( h * 60 + m ))
}

# Return start and stop time for a given day (1=Mon ... 7=Sun)
get_day_schedule() {
    local d="$1"
    case "$d" in
        1) echo "${MON_START:-08:00} ${MON_STOP:-22:30}" ;;
        2) echo "${TUE_START:-08:30} ${TUE_STOP:-22:30}" ;;
        3) echo "${WED_START:-08:00} ${WED_STOP:-22:30}" ;;
        4) echo "${THU_START:-08:00} ${THU_STOP:-22:30}" ;;
        5) echo "${FRI_START:-08:00} ${FRI_STOP:-03:00}" ;;
        6) echo "${SAT_START:-09:00} ${SAT_STOP:-03:00}" ;;
        7) echo "${SUN_START:-09:00} ${SUN_STOP:-22:30}" ;;
    esac
}

get_day_name() {
    local d="$1"
    case "$d" in
        1) echo "Monday" ;;
        2) echo "Tuesday" ;;
        3) echo "Wednesday" ;;
        4) echo "Thursday" ;;
        5) echo "Friday" ;;
        6) echo "Saturday" ;;
        7) echo "Sunday" ;;
    esac
}

# Returns 0 if OFF (night/shutdown window), 1 if ON (active window)
should_be_off() {
    local now_min today_day yesterday_day
    now_min=$(time_to_minutes "$(date +%H:%M)")
    today_day=$(date +%u)
    yesterday_day=$(( (today_day + 5) % 7 + 1 ))

    # 1. Check if today's active window applies
    local today_sched today_start_str today_stop_str
    today_sched=$(get_day_schedule "$today_day")
    today_start_str=$(echo "$today_sched" | awk '{print $1}')
    today_stop_str=$(echo "$today_sched" | awk '{print $2}')

    local t_start t_stop
    t_start=$(time_to_minutes "$today_start_str")
    t_stop=$(time_to_minutes "$today_stop_str")

    if [ "$t_stop" -ge "$t_start" ]; then
        # Normal same-day window (e.g. 08:00 to 22:30)
        if [ "$now_min" -ge "$t_start" ] && [ "$now_min" -lt "$t_stop" ]; then
            return 1 # Active (ON)
        fi
    else
        # Window spans past midnight into the next morning (e.g. 08:00 to 03:00)
        if [ "$now_min" -ge "$t_start" ]; then
            return 1 # Active (ON)
        fi
    fi

    # 2. Check if yesterday's window spanned past midnight and is still active today
    local yest_sched yest_start_str yest_stop_str
    yest_sched=$(get_day_schedule "$yesterday_day")
    yest_start_str=$(echo "$yest_sched" | awk '{print $1}')
    yest_stop_str=$(echo "$yest_sched" | awk '{print $2}')

    local y_start y_stop
    y_start=$(time_to_minutes "$yest_start_str")
    y_stop=$(time_to_minutes "$yest_stop_str")

    if [ "$y_stop" -lt "$y_start" ]; then
        # Yesterday spanned past midnight into today (e.g. Fri 08:00 to 03:00 Sat morning)
        if [ "$now_min" -lt "$y_stop" ]; then
            return 1 # Active (ON)
        fi
    fi

    # Outside all active windows -> OFF
    return 0
}

# ------------------------------------------------------------------------------
# Helper Functions: Proxmox Guests (LXC & QEMU/KVM VMs)
# ------------------------------------------------------------------------------
is_vm_enabled() {
    [ "$ENABLE_VMS" = "true" ] || [ "$ENABLE_VMS" = "1" ]
}

get_running_guests() {
    local running_lxc=""
    local running_vm=""
    running_lxc=$(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}')
    if is_vm_enabled; then
        running_vm=$(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}')
    fi
    echo "$running_lxc $running_vm" | xargs
}

get_running_ctids() {
    get_running_guests
}

get_stopped_guests() {
    local stopped_lxc=""
    local stopped_vm=""
    stopped_lxc=$(pct list 2>/dev/null | awk 'NR>1 && $2=="stopped" {print $1}')
    if is_vm_enabled; then
        stopped_vm=$(qm list 2>/dev/null | awk 'NR>1 && $3=="stopped" {print $1}')
    fi
    echo "$stopped_lxc $stopped_vm" | xargs
}

get_stopped_ctids() {
    get_stopped_guests
}

# Identify whether a guest is an LXC container or a QEMU VM
get_guest_label() {
    local id="$1"
    if pct status "$id" >/dev/null 2>&1; then
        echo "LXC $id"
    elif qm status "$id" >/dev/null 2>&1; then
        echo "VM $id"
    else
        echo "Guest $id"
    fi
}

# Retrieve all tags of a guest (space-separated)
get_guest_tags() {
    local id="$1"
    local tags=""
    if pct status "$id" >/dev/null 2>&1; then
        tags=$(pct config "$id" 2>/dev/null | grep -E '^tags:' | sed 's/^tags:[[:space:]]*//' | tr ';,' ' ')
    elif qm status "$id" >/dev/null 2>&1; then
        tags=$(qm config "$id" 2>/dev/null | grep -E '^tags:' | sed 's/^tags:[[:space:]]*//' | tr ';,' ' ')
    fi
    echo "$tags"
}

get_ct_tags() {
    get_guest_tags "$1"
}

# Check if a guest has a specific tag
guest_has_tag() {
    local id="$1"
    local target_tag="$2"
    [ -z "$target_tag" ] && return 1
    local tags
    tags=$(get_guest_tags "$id")
    for t in $tags; do
        if [ "$t" = "$target_tag" ]; then
            return 0
        fi
    done
    return 1
}

ct_has_tag() {
    guest_has_tag "$1" "$2"
}

# Stop an individual guest (LXC or VM)
stop_guest() {
    local id="$1"
    local label
    label=$(get_guest_label "$id")
    if pct status "$id" 2>/dev/null | grep -q "status: running"; then
        echo "Stopping $label..."
        pct shutdown "$id" --timeout 60 2>/dev/null || pct stop "$id" 2>/dev/null &
    elif is_vm_enabled && qm status "$id" 2>/dev/null | grep -q "status: running"; then
        echo "Stopping $label..."
        qm shutdown "$id" --timeout 60 2>/dev/null || qm stop "$id" 2>/dev/null &
    fi
}

# Start an individual guest (LXC or VM)
start_guest() {
    local id="$1"
    local label
    label=$(get_guest_label "$id")
    if pct status "$id" 2>/dev/null | grep -q "status: stopped"; then
        echo "Starting $label..."
        pct start "$id" 2>/dev/null &
        sleep "$START_DELAY_SECONDS"
    elif qm status "$id" 2>/dev/null | grep -q "status: stopped"; then
        if is_vm_enabled; then
            echo "Starting $label..."
            qm start "$id" 2>/dev/null &
            sleep "$START_DELAY_SECONDS"
        else
            echo "Skipping $label (VM management is currently disabled in config)."
        fi
    fi
}

# Register all configured tags in the Proxmox cluster (Datacenter Options)
register_proxmox_tags() {
    echo "Registering PowerScheduler tags in Proxmox VE (Datacenter Options)..."
    if ! command -v pvesh >/dev/null 2>&1; then
        echo "Notice: 'pvesh' not found (not a Proxmox host). Skipping automatic registration."
        return 0
    fi

    local tags_to_add=("$TAG_IGNORE" "$TAG_START_FIRST" "$TAG_START_LAST" "$TAG_STOP_FIRST" "$TAG_STOP_LAST")
    local current_tags=""

    if [ -f /etc/pve/datacenter.cfg ]; then
        current_tags=$(grep -E '^\s*registered-tags:' /etc/pve/datacenter.cfg 2>/dev/null | sed -E 's/^\s*registered-tags:\s*//')
    fi
    if [ -z "$current_tags" ]; then
        current_tags=$(pvesh get /cluster/options --output-format json 2>/dev/null | grep -o '"registered-tags":\s*"[^"]*"' | cut -d'"' -f4)
    fi

    local combined_tags="$current_tags"
    for tag in "${tags_to_add[@]}"; do
        if [ -n "$tag" ]; then
            if [[ ";${combined_tags};" != *";${tag};"* ]]; then
                if [ -z "$combined_tags" ]; then
                    combined_tags="$tag"
                else
                    combined_tags="${combined_tags};${tag}"
                fi
            fi
        fi
    done

    combined_tags=$(echo "$combined_tags" | sed -E 's/^;+//; s/;+$//; s/;+/;/g')

    if pvesh set /cluster/options --registered-tags "$combined_tags" >/dev/null 2>&1; then
        echo "The following tags were successfully registered in Proxmox Datacenter:"
        for tag in "${tags_to_add[@]}"; do
            [ -n "$tag" ] && echo "  - $tag"
        done
    else
        echo "Warning: 'pvesh set /cluster/options --registered-tags' failed. Please check permissions."
    fi
}

# ------------------------------------------------------------------------------
# Shutdown active guests: Stop-First -> wait -> Default -> wait -> Stop-Last
# ------------------------------------------------------------------------------
stop_all_containers() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Shutting down active guests..."
    local raw_running
    raw_running=$(get_running_guests)

    if [ -z "$raw_running" ]; then
        echo "No active guests found."
        return 0
    fi

    # Filter blacklist: exclude guests with TAG_IGNORE
    local running_filtered=""
    for id in $raw_running; do
        if [ -n "$TAG_IGNORE" ] && guest_has_tag "$id" "$TAG_IGNORE"; then
            echo "$(get_guest_label "$id") is excluded (Blacklist tag: $TAG_IGNORE)."
        else
            running_filtered="${running_filtered} ${id}"
        fi
    done
    running_filtered=$(echo "$running_filtered" | xargs)

    if [ -z "$running_filtered" ]; then
        echo "All running guests are excluded ($TAG_IGNORE). Nothing to stop."
        return 0
    fi

    # Create/update state file (preserve existing list if present)
    local save_list="$running_filtered"
    if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
        save_list=$(echo -e "$(cat "$STATE_FILE")\n$running_filtered" | tr ' ' '\n' | sort -u | grep -v '^$')
    fi
    echo "$save_list" > "$STATE_FILE"

    echo "The following guests will be shut down (Stop-First -> Default -> Stop-Last):"
    echo "$running_filtered"

    # Separate guests into shutdown stages: Stop-First, Default, Stop-Last
    local stage_first="" default_stage="" stage_last=""
    for id in $running_filtered; do
        if [ -n "$TAG_STOP_FIRST" ] && guest_has_tag "$id" "$TAG_STOP_FIRST"; then
            stage_first="${stage_first} ${id}"
        elif [ -n "$TAG_STOP_LAST" ] && guest_has_tag "$id" "$TAG_STOP_LAST"; then
            stage_last="${stage_last} ${id}"
        else
            default_stage="${default_stage} ${id}"
        fi
    done

    # 1. Stop-First stage shutdown (stops FIRST)
    if [ -n "$(echo "$stage_first" | xargs)" ]; then
        echo "--- Stop-First ($TAG_STOP_FIRST): Stopping guests: $stage_first"
        for id in $stage_first; do
            stop_guest "$id"
        done
        wait
        if [ -n "$(echo "$default_stage $stage_last" | xargs)" ]; then
            echo "Waiting ${STAGE_DELAY_SECONDS}s before next stage..."
            sleep "$STAGE_DELAY_SECONDS"
        fi
    fi

    # 2. Default stage shutdown (untagged, stops in the middle)
    if [ -n "$(echo "$default_stage" | xargs)" ]; then
        echo "--- Default Stage (untagged): Stopping guests: $default_stage"
        for id in $default_stage; do
            stop_guest "$id"
        done
        wait
        if [ -n "$(echo "$stage_last" | xargs)" ]; then
            echo "Waiting ${STAGE_DELAY_SECONDS}s before next stage..."
            sleep "$STAGE_DELAY_SECONDS"
        fi
    fi

    # 3. Stop-Last stage shutdown (stops LAST)
    if [ -n "$(echo "$stage_last" | xargs)" ]; then
        echo "--- Stop-Last ($TAG_STOP_LAST): Stopping guests: $stage_last"
        for id in $stage_last; do
            stop_guest "$id"
        done
        wait
    fi

    echo "All active guests have been shut down."
}

# ------------------------------------------------------------------------------
# Start saved guests: Start-First -> wait -> Default -> wait -> Start-Last
# ------------------------------------------------------------------------------
start_all_containers() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting guests..."

    local to_start=""
    if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
        to_start=$(cat "$STATE_FILE")
    else
        # Fallback for manual CLI start-all: check for any stopped guests
        to_start=$(get_stopped_guests)
        if [ -n "$to_start" ]; then
            echo "No state file found. Starting stopped guests (Start-First -> Default -> Start-Last)..."
        else
            echo "No guests available to start."
            return 0
        fi
    fi

    if [ -z "$to_start" ]; then
        echo "No guests available to start."
        rm -f "$STATE_FILE"
        return 0
    fi

    # Filter blacklist in case guest was tagged ignore in the meantime
    local to_start_filtered=""
    for id in $to_start; do
        if [ -n "$TAG_IGNORE" ] && guest_has_tag "$id" "$TAG_IGNORE"; then
            echo "$(get_guest_label "$id") is excluded (Blacklist tag: $TAG_IGNORE)."
        else
            to_start_filtered="${to_start_filtered} ${id}"
        fi
    done
    to_start_filtered=$(echo "$to_start_filtered" | xargs)

    if [ -z "$to_start_filtered" ]; then
        echo "No remaining guests to start (all excluded)."
        rm -f "$STATE_FILE"
        return 0
    fi

    # Separate guests into start stages: Start-First, Default, Start-Last
    local stage_first="" default_stage="" stage_last=""
    for id in $to_start_filtered; do
        if [ -n "$TAG_START_FIRST" ] && guest_has_tag "$id" "$TAG_START_FIRST"; then
            stage_first="${stage_first} ${id}"
        elif [ -n "$TAG_START_LAST" ] && guest_has_tag "$id" "$TAG_START_LAST"; then
            stage_last="${stage_last} ${id}"
        else
            default_stage="${default_stage} ${id}"
        fi
    done

    start_guest_group() {
        local group="$1"
        for id in $group; do
            start_guest "$id"
        done
        wait
    }

    # 1. Start-First stage start (starts FIRST)
    if [ -n "$(echo "$stage_first" | xargs)" ]; then
        echo "--- Start-First ($TAG_START_FIRST): Starting guests: $stage_first"
        start_guest_group "$stage_first"
        if [ -n "$(echo "$default_stage $stage_last" | xargs)" ]; then
            echo "Waiting ${STAGE_DELAY_SECONDS}s before next stage..."
            sleep "$STAGE_DELAY_SECONDS"
        fi
    fi

    # 2. Default stage start (untagged, starts in the middle)
    if [ -n "$(echo "$default_stage" | xargs)" ]; then
        echo "--- Default Stage (untagged): Starting guests: $default_stage"
        start_guest_group "$default_stage"
        if [ -n "$(echo "$stage_last" | xargs)" ]; then
            echo "Waiting ${STAGE_DELAY_SECONDS}s before next stage..."
            sleep "$STAGE_DELAY_SECONDS"
        fi
    fi

    # 3. Start-Last stage start (starts LAST)
    if [ -n "$(echo "$stage_last" | xargs)" ]; then
        echo "--- Start-Last ($TAG_START_LAST): Starting guests: $stage_last"
        start_guest_group "$stage_last"
    fi

    # Clean up state file
    rm -f "$STATE_FILE"
    echo "All saved guests have been started."
}

# ------------------------------------------------------------------------------
# Daemon loop for background service with dynamic config hot-reloading
# ------------------------------------------------------------------------------
run_daemon() {
    echo "Proxmox PowerScheduler Service started (VMs enabled: $ENABLE_VMS)."
    local last_state=""
    local last_vms="$ENABLE_VMS"

    # Detect initial state upon service start
    if should_be_off; then
        last_state="OFF"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Service initialized in shutdown window (Target: OFF)."
        stop_all_containers
    else
        last_state="ON"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Service initialized in active window (Target: ON)."
        # If an existing state file exists (e.g. after host reboot during active hours):
        if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
            echo "Existing state file found. Restoring previous state..."
            start_all_containers
        fi
    fi

    while true; do
        # Hot-reload configuration dynamically if changed
        if [ -f "$CONFIG_FILE" ]; then
            # shellcheck source=/dev/null
            source "$CONFIG_FILE"
            TAG_START_FIRST="${TAG_START_FIRST:-${TAG_START_STAGE1:-${TAG_START_PRIO1:-power-start-first}}}"
            TAG_START_LAST="${TAG_START_LAST:-${TAG_START_STAGE2:-${TAG_START_PRIO2:-power-start-last}}}"
            TAG_STOP_FIRST="${TAG_STOP_FIRST:-${TAG_STOP_STAGE1:-${TAG_STOP_PRIO1:-power-stop-first}}}"
            TAG_STOP_LAST="${TAG_STOP_LAST:-${TAG_STOP_STAGE2:-${TAG_STOP_PRIO2:-power-stop-last}}}"

            if [ "$ENABLE_VMS" != "$last_vms" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuration reloaded: ENABLE_VMS changed to '$ENABLE_VMS'."
                last_vms="$ENABLE_VMS"
            fi
        fi

        if should_be_off; then
            current_target="OFF"
        else
            current_target="ON"
        fi

        if [ "$current_target" != "$last_state" ]; then
            if [ "$current_target" == "OFF" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Scheduled stop time reached. Shutting down guests..."
                stop_all_containers
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Scheduled start time reached. Starting guests..."
                start_all_containers
            fi
            last_state="$current_target"
        fi

        sleep 30
    done
}

# ------------------------------------------------------------------------------
# CLI Subcommands
# ------------------------------------------------------------------------------
case "$1" in
    daemon)
        run_daemon
        ;;
    stop-all)
        stop_all_containers
        ;;
    start-all)
        start_all_containers
        ;;
    register-tags)
        register_proxmox_tags
        ;;
    disable)
        echo "Disabling automatic PowerScheduler service..."
        systemctl stop "$SERVICE_NAME"
        systemctl disable "$SERVICE_NAME"
        echo "Service stopped and disabled."
        ;;
    enable)
        echo "Enabling and starting automatic PowerScheduler service..."
        systemctl enable --now "$SERVICE_NAME"
        echo "Service enabled and started."
        ;;
    status)
        systemctl status "$SERVICE_NAME" --no-pager
        echo "--------------------------------------------------"
        echo "General Configuration:"
        echo "  - Manage VMs (QEMU/KVM): $ENABLE_VMS"
        echo "  - Stage delay: ${STAGE_DELAY_SECONDS}s | Guest I/O delay: ${START_DELAY_SECONDS}s"
        echo "Configured Weekly Schedule:"
        for d in 1 2 3 4 5 6 7; do
            dname=$(get_day_name "$d")
            read -r s_str e_str <<< "$(get_day_schedule "$d")"
            s_min=$(time_to_minutes "$s_str")
            e_min=$(time_to_minutes "$e_str")
            note=""
            if [ "$e_min" -lt "$s_min" ]; then
                note=" (until next morning)"
            fi
            printf "  - %-9s %s - %s%s\n" "${dname}:" "$s_str" "$e_str" "$note"
        done
        echo "Configured Tags:"
        echo "  - Blacklist / Exclude: $TAG_IGNORE"
        echo "  - Start sequence: $TAG_START_FIRST -> wait ${STAGE_DELAY_SECONDS}s -> Default (untagged) -> wait ${STAGE_DELAY_SECONDS}s -> $TAG_START_LAST"
        echo "  - Stop sequence:  $TAG_STOP_FIRST -> wait ${STAGE_DELAY_SECONDS}s -> Default (untagged) -> wait ${STAGE_DELAY_SECONDS}s -> $TAG_STOP_LAST"
        echo "--------------------------------------------------"
        today_num=$(date +%u)
        read -r t_start_cur t_stop_cur <<< "$(get_day_schedule "$today_num")"
        echo "Current Time: $(date '+%Y-%m-%d %H:%M:%S (%A)')"
        echo "Today's Schedule: Active from $t_start_cur to $t_stop_cur"
        if should_be_off; then
            echo "Current Target State: OFF (Shutdown window)"
        else
            echo "Current Target State: ON (Active window)"
        fi
        if [ -f "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
            echo "Guests saved for next start: $(cat "$STATE_FILE" | tr '\n' ' ')"
        fi
        ;;
    *)
        echo "Usage: $0 {status|start-all|stop-all|enable|disable|register-tags|daemon}"
        exit 1
        ;;
esac