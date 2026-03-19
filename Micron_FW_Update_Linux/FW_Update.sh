#!/bin/bash
# =============================================================================
# Micron Firmware Update Tool - Linux/Ubuntu Version
#
# Requirements:
#   - Run as root (sudo)
#   - nvme-cli:  auto-installed if missing
#   - jq:        auto-installed if missing
#   - findmnt:   included in util-linux (standard on Ubuntu)
#
# Firmware files must be in the same directory as this script.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/UpdateLog.txt"

# =============================================================================
# FIRMWARE UPDATE MAP
# Key   = first 4 characters of the current firmware revision
# Update this section if new firmware versions are released.
# =============================================================================
declare -A FW_MODEL FW_LATEST FW_FILE

FW_MODEL["E2MU"]="7450"
FW_LATEST["E2MU"]="E2MU300"
FW_FILE["E2MU"]="Micron_7450_E2MU300_release.ubi"

FW_MODEL["E3MQ"]="7500"
FW_LATEST["E3MQ"]="E3MQ005"
FW_FILE["E3MQ"]="Micron_7500_E3MQ005_release.ubi"

# =============================================================================
# HELPERS
# =============================================================================
RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; CYAN='\e[36m'; NC='\e[0m'

log() {
    # Writes to both screen and log file
    local ts; ts=$(date "+%Y-%m-%d %H:%M:%S")
    printf "[%s] %s\n" "$ts" "$1" | tee -a "$LOG_FILE"
}

log_only() {
    # Writes to log file only — keeps screen output clean
    local ts; ts=$(date "+%Y-%m-%d %H:%M:%S")
    printf "[%s] %s\n" "$ts" "$1" >> "$LOG_FILE"
}

cprint() {
    printf "${1}%s${NC}\n" "$2"
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

if [[ $EUID -ne 0 ]]; then
    cprint "$RED" "CRITICAL: This script must be run as root."
    echo "  Usage: sudo $0"
    exit 1
fi

# Auto-install nvme-cli if missing
if ! command -v nvme &>/dev/null; then
    cprint "$YELLOW" "nvme-cli not found. Installing..."
    if ! apt-get install -y nvme-cli >> "$LOG_FILE" 2>&1; then
        cprint "$RED" "ERROR: Failed to install nvme-cli. Install manually: sudo apt install nvme-cli"
        exit 1
    fi
    cprint "$GREEN" "nvme-cli installed successfully."
fi

# Auto-install jq if missing
if ! command -v jq &>/dev/null; then
    cprint "$YELLOW" "jq not found. Installing..."
    if ! apt-get install -y jq >> "$LOG_FILE" 2>&1; then
        cprint "$RED" "ERROR: Failed to install jq. Install manually: sudo apt install jq"
        exit 1
    fi
    cprint "$GREEN" "jq installed successfully."
fi

# findmnt is part of util-linux and should always be present, but verify
if ! command -v findmnt &>/dev/null; then
    cprint "$RED" "ERROR: findmnt is missing. Install with: sudo apt install util-linux"
    exit 1
fi

# =============================================================================
# DETECT BOOT CONTROLLER
# =============================================================================
BOOT_CTRL=""
BOOT_PART=$(findmnt -n -o SOURCE / 2>/dev/null || true)
if [[ -n "$BOOT_PART" ]]; then
    BOOT_CTRL=$(echo "$BOOT_PART" | sed -E 's/p[0-9]+$//; s/n[0-9]+$//')
fi

# =============================================================================
# HELPER: Resolve namespace device path -> NVMe controller device
#
#   /dev/nvme0n1  -> /dev/nvme0   (standard regex strip)
#   /dev/ng0n1    -> sysfs walk   (NVMe generic character device)
#   Any other     -> sysfs walk, then number-assumption fallback
# =============================================================================
get_controller() {
    local ns_dev="$1"
    local ns_name
    ns_name=$(basename "$ns_dev")

    # Standard nvme block namespace: nvme0n1 -> nvme0
    if [[ "$ns_name" =~ ^(nvme[0-9]+)n[0-9]+$ ]]; then
        local ctrl="/dev/${BASH_REMATCH[1]}"
        if [[ -c "$ctrl" ]]; then
            echo "$ctrl"
            return 0
        fi
    fi

    # Sysfs walk for standard block devices
    local sysfs_block="/sys/class/block/$ns_name"
    if [[ -e "$sysfs_block" ]]; then
        local p
        p=$(readlink -f "$sysfs_block" 2>/dev/null)
        while [[ -n "$p" && "$p" != "/" ]]; do
            local bn; bn=$(basename "$p")
            if [[ "$bn" =~ ^nvme[0-9]+$ ]] && [[ -c "/dev/$bn" ]]; then
                echo "/dev/$bn"
                return 0
            fi
            p=$(dirname "$p")
        done
    fi

    # Sysfs walk for NVMe generic (ng) character devices
    local sysfs_ng="/sys/class/nvme-generic/$ns_name"
    if [[ -e "$sysfs_ng" ]]; then
        local p
        p=$(readlink -f "$sysfs_ng" 2>/dev/null)
        while [[ -n "$p" && "$p" != "/" ]]; do
            local bn; bn=$(basename "$p")
            if [[ "$bn" =~ ^nvme[0-9]+$ ]] && [[ -c "/dev/$bn" ]]; then
                echo "/dev/$bn"
                return 0
            fi
            p=$(dirname "$p")
        done
    fi

    # Last resort: assume ng number maps to nvme number (ng0n1 -> nvme0)
    if [[ "$ns_name" =~ ^ng([0-9]+)n[0-9]+$ ]]; then
        local ctrl="/dev/nvme${BASH_REMATCH[1]}"
        if [[ -c "$ctrl" ]]; then
            log_only "WARNING: Sysfs lookup failed. Assumed controller mapping: $ns_dev -> $ctrl"
            echo "$ctrl"
            return 0
        fi
    fi

    echo ""
    return 1
}

# =============================================================================
# SCAN NVMe DEVICES
# Runs silently before showing any prompts to the user.
# =============================================================================
cprint "$CYAN" "Scanning for Micron NVMe drives..."
log_only "--- Puget Firmware Updater for Micron 7450/7500 | Host: $(hostname) | $(date) ---"
log_only "Scanning system hardware..."

NVME_JSON=$(nvme list -o json 2>/dev/null)

if [[ -z "$NVME_JSON" ]]; then
    log_only "ERROR: 'nvme list' returned no output."
    cprint "$RED" "ERROR: No NVMe devices found, or nvme-cli failed to run."
    exit 1
fi

if ! echo "$NVME_JSON" | jq empty 2>/dev/null; then
    log_only "ERROR: Failed to parse JSON from 'nvme list'."
    cprint "$RED" "ERROR: nvme-cli JSON output is malformed. Try updating nvme-cli."
    exit 1
fi

PENDING_CTRL=()
PENDING_NS=()
PENDING_MODEL_NAME=()
PENDING_CURRENT_FW=()
PENDING_TARGET_FW=()
PENDING_PREFIX=()
PENDING_IS_BOOT=()
PENDING_FILE_OK=()

while IFS= read -r dev_json; do
    ns_path=$(echo "$dev_json" | jq -r '.DevicePath  // empty')
    fw_rev=$( echo "$dev_json" | jq -r '.Firmware    // empty' | tr -d ' ')
    model=$(   echo "$dev_json" | jq -r '.ModelNumber // empty')

    [[ -z "$ns_path" || -z "$fw_rev" ]] && continue

    prefix="${fw_rev:0:4}"

    if [[ -z "${FW_LATEST[$prefix]+x}" ]]; then
        log_only "INFO: $ns_path has unrecognized firmware prefix '$prefix' — skipping."
        continue
    fi

    latest="${FW_LATEST[$prefix]}"

    if [[ "$fw_rev" == "$latest" ]]; then
        log_only "INFO: $ns_path is already on latest firmware ($fw_rev) — skipping."
        continue
    fi

    ctrl=$(get_controller "$ns_path")
    if [[ -z "$ctrl" ]]; then
        log_only "WARNING: Could not determine controller for $ns_path — skipping."
        continue
    fi

    is_boot="No"
    [[ "$ctrl" == "$BOOT_CTRL" ]] && is_boot="YES (OS Drive)"

    # Pre-check firmware file existence now so the table can warn the user upfront
    fw_file="$SCRIPT_DIR/${FW_FILE[$prefix]}"
    file_ok="Yes"
    if [[ ! -f "$fw_file" ]]; then
        file_ok="FILE MISSING"
        log_only "WARNING: Firmware file not found for $ns_path: $fw_file"
    fi

    PENDING_CTRL+=("$ctrl")
    PENDING_NS+=("$ns_path")
    PENDING_MODEL_NAME+=("Micron ${FW_MODEL[$prefix]}")
    PENDING_CURRENT_FW+=("$fw_rev")
    PENDING_TARGET_FW+=("$latest")
    PENDING_PREFIX+=("$prefix")
    PENDING_IS_BOOT+=("$is_boot")
    PENDING_FILE_OK+=("$file_ok")

done < <(echo "$NVME_JSON" | jq -c '.Devices[]?' 2>/dev/null)

# =============================================================================
# NOTHING TO DO — exit cleanly without showing the full UI
# =============================================================================
if [[ ${#PENDING_CTRL[@]} -eq 0 ]]; then
    cprint "$GREEN" "No firmware updates are necessary for this system."
    log_only "Scan complete. No updates required."
    exit 0
fi

# =============================================================================
# HEADER & MANDATORY WARNINGS
# Only shown when updates are actually needed.
# =============================================================================
clear
log "--- Micron Firmware Update Tool ---"

cprint "$CYAN" "=================================================================="
cprint "$CYAN" "             Micron Firmware Update Tool  |  Linux               "
cprint "$CYAN" "=================================================================="
echo
cprint "$YELLOW" "****************************************************************"
cprint "$YELLOW" " [!] MANDATORY PREPARATION:"
echo   "     1. CLOSE ALL APPLICATIONS (Browsers, Office, Teams, etc.)"
echo   "     2. ENSURE NO FILE TRANSFERS OR DISK OPERATIONS ARE RUNNING."
echo   "     3. BACK UP ALL CRITICAL DATA BEFORE PROCEEDING."
cprint "$YELLOW" "****************************************************************"
echo
read -rp "Have you closed all apps and wish to proceed? (y/n): " confirm
if [[ "${confirm,,}" != "y" ]]; then
    echo "Exiting. No changes were made."
    exit 0
fi

# =============================================================================
# DISPLAY PLANNED CHANGES
# =============================================================================
echo
cprint "$CYAN" "Planned Firmware Changes:"
echo "--------------------------------------------------------------------------------------"
printf "%-18s %-14s %-12s %-12s %-16s %s\n" "Namespace" "Model" "Current FW" "Target FW" "Boot Drive" "File"
echo "--------------------------------------------------------------------------------------"
for i in "${!PENDING_CTRL[@]}"; do
    printf "%-18s %-14s %-12s %-12s %-16s %s\n" \
        "${PENDING_NS[$i]}" \
        "${PENDING_MODEL_NAME[$i]}" \
        "${PENDING_CURRENT_FW[$i]}" \
        "${PENDING_TARGET_FW[$i]}" \
        "${PENDING_IS_BOOT[$i]}" \
        "${PENDING_FILE_OK[$i]}"
done
echo "--------------------------------------------------------------------------------------"

# Warn if any firmware files are missing
for file_flag in "${PENDING_FILE_OK[@]}"; do
    if [[ "$file_flag" == "FILE MISSING" ]]; then
        echo
        cprint "$RED" " [!!] WARNING: One or more firmware files are missing from the script directory."
        cprint "$RED" "      Those drives will be skipped during the update."
        break
    fi
done

# Warn if the OS boot drive is included
for boot_flag in "${PENDING_IS_BOOT[@]}"; do
    if [[ "$boot_flag" != "No" ]]; then
        echo
        cprint "$RED" " [!!] WARNING: Your OS boot drive is included in this update!"
        cprint "$RED" "      The system may briefly lag or freeze — this is normal."
        break
    fi
done

echo
read -rp "Confirm you want to apply these firmware updates? (y/n): " flash_confirm
if [[ "${flash_confirm,,}" != "y" ]]; then
    echo "Aborted. No changes were made."
    exit 0
fi

# =============================================================================
# FLASH LOOP
# =============================================================================
NEEDS_SHUTDOWN=false
FLASH_SUCCESS=0
FLASH_ERRORS=0

for i in "${!PENDING_CTRL[@]}"; do
    ctrl="${PENDING_CTRL[$i]}"
    ns="${PENDING_NS[$i]}"
    model="${PENDING_MODEL_NAME[$i]}"
    prefix="${PENDING_PREFIX[$i]}"
    fw_file="$SCRIPT_DIR/${FW_FILE[$prefix]}"
    current_fw="${PENDING_CURRENT_FW[$i]}"
    target_fw="${PENDING_TARGET_FW[$i]}"

    echo
    log "--- Updating $ns ($model) | $current_fw -> $target_fw ---"
    cprint "$YELLOW" "Updating: $ns ($model)  |  $current_fw -> $target_fw"

    if [[ "${PENDING_IS_BOOT[$i]}" != "No" ]]; then
        cprint "$RED" "  >> NOTE: This is the OS boot drive. Brief system lag is expected."
    fi

    # Skip drives whose firmware file was missing at scan time
    if [[ "${PENDING_FILE_OK[$i]}" == "FILE MISSING" ]]; then
        cprint "$RED" "  >> SKIPPED: Firmware file not found: $(basename "$fw_file")"
        log_only "SKIPPED: $ns — firmware file not found: $fw_file"
        (( FLASH_ERRORS++ )) || true
        continue
    fi

    # Step 1: Download firmware image to drive's transfer buffer
    cprint "$YELLOW" "  >> [1/2] Transferring firmware image..."
    log_only "  >> fw-download: $ctrl <- $fw_file"

    if ! nvme fw-download "$ctrl" --fw="$fw_file" >> "$LOG_FILE" 2>&1; then
        log_only "ERROR: fw-download failed for $ctrl."
        cprint "$RED" "  >> ERROR: Firmware transfer failed. See log for details: $LOG_FILE"
        (( FLASH_ERRORS++ )) || true
        continue
    fi
    log_only "  >> fw-download: SUCCESS"

    # Step 2: Commit and activate
    # --slot=2 --action=3: Replace slot 2 image and activate immediately.
    # The controller resets itself on the spot, which is why nvme-cli almost
    # always returns non-zero here — the drive disconnects mid-command as it
    # resets. This is expected behavior, not an error.
    cprint "$YELLOW" "  >> [2/2] Activating firmware (drive will reset briefly)..."
    log_only "  >> fw-commit: $ctrl --slot=2 --action=3"

    if ! nvme fw-commit "$ctrl" --slot=2 --action=3 >> "$LOG_FILE" 2>&1; then
        log_only "NOTE: fw-commit returned non-zero for $ctrl — expected if drive reset itself mid-command."
    else
        log_only "  >> fw-commit: SUCCESS"
    fi

    cprint "$CYAN" "  >> Waiting 30 seconds for drive re-initialization..."
    log_only "  >> Waiting 30s for drive re-initialization..."
    sleep 30

    # Post-flash verification: re-read firmware version to confirm update applied
    new_fw=$(nvme list -o json 2>/dev/null \
        | jq -r --arg dev "$ns" '.Devices[]? | select(.DevicePath==$dev) | .Firmware // empty' \
        | tr -d ' ')

    if [[ -n "$new_fw" ]]; then
        if [[ "$new_fw" == "$target_fw" ]]; then
            cprint "$GREEN" "  >> Verified: Firmware now reports $new_fw"
            log_only "  >> Post-flash verification PASSED: $ns reports $new_fw"
        else
            cprint "$YELLOW" "  >> NOTE: Drive reports firmware $new_fw (expected $target_fw)."
            cprint "$YELLOW" "           A cold boot may be required before the version updates."
            log_only "  >> Post-flash verification: $ns reports $new_fw (expected $target_fw) — may need cold boot."
        fi
    else
        log_only "  >> Post-flash verification: could not re-read firmware version for $ns."
    fi

    NEEDS_SHUTDOWN=true
    (( FLASH_SUCCESS++ )) || true
    cprint "$GREEN" "  >> Done: $ns updated successfully."
    log_only "SUCCESS: $ns firmware update applied."
done

# =============================================================================
# SUMMARY & SHUTDOWN
# =============================================================================
echo
log "Flash loop complete. Success: $FLASH_SUCCESS  |  Errors: $FLASH_ERRORS"

if [[ "$NEEDS_SHUTDOWN" == true ]]; then

    if [[ $FLASH_ERRORS -gt 0 ]]; then
        cprint "$YELLOW" "$FLASH_SUCCESS drive(s) updated. $FLASH_ERRORS drive(s) had errors — see log: $LOG_FILE"
    else
        cprint "$GREEN" "All $FLASH_SUCCESS drive(s) updated successfully."
    fi

    echo
    cprint "$CYAN"   "****************************************************************"
    cprint "$CYAN"   " THE SYSTEM MUST BE SHUT DOWN TO FINALIZE FIRMWARE CHANGES."
    cprint "$CYAN"   " Use a full POWER OFF (cold boot) — do NOT use Restart."
    cprint "$CYAN"   "****************************************************************"
    echo
    read -rp "Shut down the system now? (y/n): " shut_confirm
    if [[ "${shut_confirm,,}" == "y" ]]; then
        log "User confirmed shutdown. Shutting down in 10 seconds..."
        cprint "$YELLOW" "Shutting down in 10 seconds... (Ctrl+C to cancel)"
        sleep 10
        shutdown -h now
    else
        cprint "$YELLOW" "Please perform a full shutdown as soon as possible to complete the update."
        log_only "User declined automatic shutdown."
    fi

else
    cprint "$RED" "No drives were successfully updated. Review log: $LOG_FILE"
fi