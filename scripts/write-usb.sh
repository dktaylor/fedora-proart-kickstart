#!/usr/bin/env bash
# ==============================================================================
# write-usb.sh — write kickstart ISO to USB + populate FEDORA_DATA flatpak partition
# ==============================================================================
# Usage:
#   sudo ./scripts/write-usb.sh /dev/sdX                  # ISO + flatpak data
#   sudo ./scripts/write-usb.sh /dev/sdX --no-flatpaks    # ISO only
#   sudo ./scripts/write-usb.sh /dev/sdX --flatpaks-only  # re-populate data only
#   sudo ./scripts/write-usb.sh /dev/sdX --mode=manual    # use manual-partitioning ISO
#
# What it does:
#   1. Writes the kickstart ISO to the device with dd
#   2. Expands the GPT to fill the actual disk (dd leaves backup GPT at ISO boundary)
#   3. Creates a FEDORA_DATA ext4 partition in the remaining space
#   4. Reads flatpaks.conf and runs 'flatpak create-usb' for each listed app
#
# Flatpak sideload notes:
#   - 'flatpak create-usb' preserves Flathub as each app's update origin.
#     After OS install, 'flatpak update' pulls from Flathub automatically.
#     No remote reconfiguration needed.
#   - Apps must be installed locally before write-usb.sh can bundle them.
#     Install missing ones with: flatpak install flathub <app-id>
#
# Requirements:
#   - gdisk / sgdisk   (dnf install gdisk)
#   - flatpak          (for --flatpaks-only or combined run)
#   - ISO built first  (run scripts/build-fedora-ks-iso.sh <mode>)
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FLATPAKS_CONF="$REPO_ROOT/flatpaks.conf"

DEVICE=""
MODE="auto"
DO_ISO=1
DO_FLATPAKS=1

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; X=$'\e[0m'
else
    B=""; G=""; Y=""; R=""; X=""
fi

info() { printf "${B}>>>${X} %s\n" "$*"; }
ok()   { printf "  ${G}[ok]${X} %s\n" "$*"; }
warn() { printf "  ${Y}[warn]${X} %s\n" "$*"; }
err()  { printf "  ${R}[err]${X} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ── Arg parsing ───────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        /dev/*)          DEVICE="$arg" ;;
        --mode=*)        MODE="${arg#--mode=}" ;;
        --no-flatpaks)   DO_FLATPAKS=0 ;;
        --flatpaks-only) DO_ISO=0 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -25; exit 0 ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

[[ -n "$DEVICE" ]]    || die "Usage: $0 /dev/sdX [--no-flatpaks|--flatpaks-only] [--mode=auto|manual|vm]"
[[ -b "$DEVICE" ]]    || die "Not a block device: $DEVICE"
[[ "$EUID" -eq 0 ]]   || die "Must run as root (sudo $0 ...)"

# VM ISOs don't need flatpaks (skipped by VM_INSTALL=1 during install)
[[ "$MODE" == "vm" ]] && DO_FLATPAKS=0

# ── Select ISO ────────────────────────────────────────────────────────────────
case "$MODE" in
    auto)   ISO="$REPO_ROOT/fedora-everything-ks.iso" ;;
    manual) ISO="$REPO_ROOT/fedora-everything-ks-manual.iso" ;;
    vm)     ISO="$REPO_ROOT/fedora-everything-ks-vm.iso" ;;
    *)      die "Unknown mode: $MODE (use auto|manual|vm)" ;;
esac

# ── Load flatpaks list ────────────────────────────────────────────────────────
FLATPAK_APPS=()
if [[ "$DO_FLATPAKS" -eq 1 ]]; then
    [[ -f "$FLATPAKS_CONF" ]] || die "flatpaks.conf not found: $FLATPAKS_CONF"
    while IFS= read -r line; do
        line="${line%%#*}"   # strip inline comments
        line="${line%% *}"   # strip trailing spaces/fields
        [[ -z "$line" ]] && continue
        FLATPAK_APPS+=("$line")
    done < "$FLATPAKS_CONF"
    [[ ${#FLATPAK_APPS[@]} -gt 0 ]] || die "No apps found in $FLATPAKS_CONF"
fi

# ── Safety confirmation ───────────────────────────────────────────────────────
echo ""
printf "${R}${B}WARNING: This will ERASE all data on %s${X}\n\n" "$DEVICE"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT "$DEVICE" 2>/dev/null || lsblk "$DEVICE"
echo ""
[[ "$DO_ISO" -eq 1 ]] && printf "  ISO:     %s\n" "$ISO"
if [[ "$DO_FLATPAKS" -eq 1 ]]; then
    printf "  Flatpaks (%d apps):\n" "${#FLATPAK_APPS[@]}"
    for app in "${FLATPAK_APPS[@]}"; do printf "    %s\n" "$app"; done
fi
echo ""
printf "Type the device name to confirm (%s): " "$DEVICE"
read -r CONFIRM
[[ "$CONFIRM" == "$DEVICE" ]] || die "Aborted"
echo ""

# ── Phase 1: Write ISO ────────────────────────────────────────────────────────
if [[ "$DO_ISO" -eq 1 ]]; then
    [[ -f "$ISO" ]] || die "ISO not found: $ISO — run scripts/build-fedora-ks-iso.sh $MODE first"

    info "Unmounting any existing partitions on $DEVICE..."
    umount "${DEVICE}"* 2>/dev/null || true

    info "Writing ISO to $DEVICE  ($(du -h "$ISO" | cut -f1))..."
    dd if="$ISO" of="$DEVICE" bs=4M status=progress conv=fsync
    sync
    ok "ISO written"

    # After dd the backup GPT header sits at the ISO boundary, not the disk end.
    # sgdisk --move-second-header relocates it so we can add partitions after.
    info "Expanding GPT to fill disk..."
    command -v sgdisk >/dev/null 2>&1 || die "sgdisk not found — run: sudo dnf install gdisk"
    sgdisk --move-second-header "$DEVICE"
    partprobe "$DEVICE" 2>/dev/null || true
    sleep 1
    ok "GPT expanded"
fi

# ── Phase 2: FEDORA_DATA partition ────────────────────────────────────────────
if [[ "$DO_FLATPAKS" -eq 1 ]]; then
    # Locate existing FEDORA_DATA or create it
    DATA_PART=$(blkid -L FEDORA_DATA 2>/dev/null || true)

    if [[ -z "$DATA_PART" ]]; then
        info "Creating FEDORA_DATA partition in remaining space..."
        command -v sgdisk >/dev/null 2>&1 || die "sgdisk not found — run: sudo dnf install gdisk"

        # Find the highest existing partition number
        LAST_PART=$(sgdisk -p "$DEVICE" 2>/dev/null | awk '/^[[:space:]]+[0-9]/{print $1}' | tail -1)
        NEXT_NUM=$(( ${LAST_PART:-0} + 1 ))

        sgdisk -n "${NEXT_NUM}:0:0" \
               -t "${NEXT_NUM}:8300" \
               -c "${NEXT_NUM}:FEDORA_DATA" \
               "$DEVICE"
        partprobe "$DEVICE" 2>/dev/null || true
        sleep 2

        # Resolve the partition device node (sda3 vs nvme0n1p3)
        if [[ -b "${DEVICE}${NEXT_NUM}" ]]; then
            DATA_PART="${DEVICE}${NEXT_NUM}"
        elif [[ -b "${DEVICE}p${NEXT_NUM}" ]]; then
            DATA_PART="${DEVICE}p${NEXT_NUM}"
        else
            die "Could not find new partition — try running partprobe manually"
        fi

        info "Formatting $DATA_PART as ext4 (label: FEDORA_DATA)..."
        mkfs.ext4 -L FEDORA_DATA -F "$DATA_PART"
        ok "FEDORA_DATA created: $DATA_PART"
    else
        ok "FEDORA_DATA already exists: $DATA_PART — updating contents"
    fi

    # ── Phase 3: Bundle Flatpaks via flatpak create-usb ───────────────────────
    command -v flatpak >/dev/null 2>&1 || die "flatpak not found"

    MOUNT_TMP=$(mktemp -d)
    trap "umount '$MOUNT_TMP' 2>/dev/null || true; rm -rf '$MOUNT_TMP'" EXIT

    mount "$DATA_PART" "$MOUNT_TMP"
    mkdir -p "$MOUNT_TMP/flatpaks"

    info "Bundling ${#FLATPAK_APPS[@]} Flatpak app(s) with flatpak create-usb..."
    MISSING=()
    for app in "${FLATPAK_APPS[@]}"; do
        if flatpak info "$app" >/dev/null 2>&1; then
            info "  Bundling $app..."
            flatpak create-usb "$MOUNT_TMP/flatpaks" "$app"
            ok "$app"
        else
            MISSING+=("$app")
            warn "$app not installed locally — skipping"
        fi
    done

    umount "$MOUNT_TMP"
    trap - EXIT
    rm -rf "$MOUNT_TMP"

    if [[ ${#MISSING[@]} -gt 0 ]]; then
        echo ""
        warn "${#MISSING[@]} app(s) were not installed locally and were skipped:"
        for app in "${MISSING[@]}"; do warn "  flatpak install flathub $app"; done
        warn "Install them then re-run: sudo $0 $DEVICE --flatpaks-only"
    fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "${B}========================================================${X}"
echo " USB ready: $DEVICE"
[[ "$DO_ISO" -eq 1 ]]      && echo "  ISO:     $ISO"
[[ "$DO_FLATPAKS" -eq 1 ]] && echo "  Flatpaks: FEDORA_DATA partition (${#FLATPAK_APPS[@]} apps)"
echo ""
echo " Boot from this USB to install Fedora 44."
echo "${B}========================================================${X}"
