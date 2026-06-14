#!/usr/bin/env bash
# ==============================================================================
# build-fedora-ks-iso.sh — embed kickstart into Fedora ISO for unattended install
# ==============================================================================
# Usage:
#   ./build-fedora-ks-iso.sh auto       # auto-partitioning kickstart
#   ./build-fedora-ks-iso.sh manual     # manual LVM partitioning
#
# Requirements:
#   - xorriso and mkisofs (dnf install xorriso)
#   - The Fedora 44 Everything ISO already downloaded
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KS_AUTO="$SCRIPT_DIR/fedora-ks.cfg"
KS_MANUAL="$SCRIPT_DIR/fedora-ks-manualpart.cfg"
ISO_DIR="$SCRIPT_DIR/iso"
WORK_DIR="${WORK_DIR:-.}"

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

# Parse mode
MODE="${1:-}"
case "$MODE" in
    auto)   KS_FILE="$KS_AUTO"; OUTPUT="$(cd "$WORK_DIR" && pwd)/fedora-everything-ks.iso" ;;
    manual) KS_FILE="$KS_MANUAL"; OUTPUT="$(cd "$WORK_DIR" && pwd)/fedora-everything-ks-manual.iso" ;;
    *)      echo "Usage: $0 {auto|manual}"; exit 1 ;;
esac

[[ -f "$KS_FILE" ]] || die "Kickstart not found: $KS_FILE"

# Find the ISO (check multiple locations)
ORIGINAL_ISO=""
for path in "$ISO_DIR/Fedora-Everything-netinst-x86_64-44-1.7.iso" \
            "$WORK_DIR/Fedora-Everything-netinst-x86_64-44-1.7.iso" \
            "iso/Fedora-Everything-netinst-x86_64-44-1.7.iso"; do
    if [[ -f "$path" ]]; then
        ORIGINAL_ISO="$path"
        break
    fi
done

[[ -n "$ORIGINAL_ISO" ]] || die "Fedora 44 ISO not found. Place it in ./iso/ directory."
ok "ISO: $(basename "$ORIGINAL_ISO")"
ok "KS:  $(basename "$KS_FILE")"

# Create temp work directory
BUILD_DIR=$(mktemp -d)
trap "rm -rf '$BUILD_DIR'" EXIT

info "Extracting ISO..."
# Mount the ISO read-only
MOUNT_POINT=$(mktemp -d)
trap "sudo umount -l '$MOUNT_POINT' 2>/dev/null; rmdir '$MOUNT_POINT' 2>/dev/null; sudo rm -rf '$BUILD_DIR'" EXIT

sudo mount -o loop,ro "$ORIGINAL_ISO" "$MOUNT_POINT" 2>/dev/null || die "Failed to mount ISO"
ok "ISO mounted"

# Use sudo rsync to copy everything
sudo rsync -a "$MOUNT_POINT/" "$BUILD_DIR/" 2>&1 | tail -5

# Fix permissions so we can modify files
sudo chown -R "$USER:$USER" "$BUILD_DIR" 2>/dev/null || true

sudo umount -l "$MOUNT_POINT" 2>/dev/null || true

# This is a UEFI-only netinstall ISO (no isolinux), verify we have boot configs
[[ -f "$BUILD_DIR/boot/grub2/grub.cfg" ]] || die "Extract failed: no boot/grub2/grub.cfg found"
ok "ISO extracted"

# Inject kickstart
info "Injecting kickstart..."
cp "$KS_FILE" "$BUILD_DIR/ks.cfg"
ok "Kickstart added"

# Modify boot configs to auto-load kickstart
# For UEFI netinstall: modify grub.cfg files
for grub_cfg in "$BUILD_DIR/boot/grub2/grub.cfg" "$BUILD_DIR/EFI/BOOT/grub.cfg"; do
    if [[ -f "$grub_cfg" ]]; then
        # Append kickstart option to boot lines
        sed -i 's|\(inst\.stage2=[^ ]*\)|\1 inst.ks=cdrom:/ks.cfg|g' "$grub_cfg" 2>/dev/null || true
    fi
done
ok "Boot configs modified"

# Build ISO
info "Building ISO..."
rm -f "$OUTPUT"

cd "$BUILD_DIR" || die "cd failed"

# For UEFI netinstall ISO: simple approach without EFI boot images
# The EFI firmware will find boot files via the EFI directory structure
mkisofs -o "$OUTPUT" \
    -J -R \
    -V "Fedora-44" \
    . 2>&1 | tail -5

echo "Checking if ISO was created..."
ls -lh "$OUTPUT" 2>&1

cd - >/dev/null

if [[ -f "$OUTPUT" && -s "$OUTPUT" ]]; then
    ok "ISO created: $OUTPUT"
    ok "Size: $(du -h "$OUTPUT" | cut -f1)"
else
    echo "File exists: $(test -f "$OUTPUT" && echo yes || echo no)"
    echo "File size: $(stat -c%s "$OUTPUT" 2>/dev/null || echo unknown)"
    die "ISO build check failed"
fi

echo ""
echo "${B}ISO ready for installation:${X}"
echo "  Write to USB: sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress"
echo ""
