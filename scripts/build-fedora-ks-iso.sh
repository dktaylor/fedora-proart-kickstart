#!/usr/bin/env bash
# ==============================================================================
# build-fedora-ks-iso.sh — embed kickstart into Fedora ISO for unattended install
# ==============================================================================
# Usage:
#   ./scripts/build-fedora-ks-iso.sh auto       # auto-partitioning kickstart
#   ./scripts/build-fedora-ks-iso.sh manual     # manual LVM partitioning
#   ./scripts/build-fedora-ks-iso.sh vm         # VM testing (vda, clearpart --all)
#
# Requirements:
#   - xorriso (dnf install xorriso)
#   - The Fedora 44 Everything ISO already downloaded
#
# Approach: use xorriso to splice files into the original ISO while replaying
# its boot catalog verbatim. This preserves UEFI + legacy BIOS bootability
# without needing to mount, rsync, or repack with mkisofs.
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
KS_AUTO="$REPO_ROOT/kickstart/fedora-ks-auto.cfg"
KS_MANUAL="$REPO_ROOT/kickstart/fedora-ks-manual.cfg"
KS_VM="$REPO_ROOT/kickstart/fedora-ks-vm.cfg"
ISO_DIR="$REPO_ROOT/iso"
WORK_DIR="${WORK_DIR:-$REPO_ROOT}"

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
    auto)   KS_FILE="$KS_AUTO";   OUTPUT="$(cd "$WORK_DIR" && pwd)/fedora-everything-ks.iso" ;;
    manual) KS_FILE="$KS_MANUAL"; OUTPUT="$(cd "$WORK_DIR" && pwd)/fedora-everything-ks-manual.iso" ;;
    vm)     KS_FILE="$KS_VM";     OUTPUT="$(cd "$WORK_DIR" && pwd)/fedora-everything-ks-vm.iso" ;;
    *)      echo "Usage: $0 {auto|manual|vm}"; exit 1 ;;
esac

[[ -f "$KS_FILE" ]] || die "Kickstart not found: $KS_FILE"
command -v xorriso >/dev/null 2>&1 || die "xorriso not found — run: sudo dnf install xorriso"

# Find the ISO
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

# Temp dir for modified grub configs (avoid clobbering $TMPDIR env var)
WORK_TMP=$(mktemp -d)
trap "rm -rf '$WORK_TMP'" EXIT

# Extract grub configs from the original ISO, patch them, then splice back in
info "Patching boot configs..."
for iso_path in /boot/grub2/grub.cfg /EFI/BOOT/grub.cfg; do
    local_name="${iso_path//\//_}"          # /boot/grub2/grub.cfg → _boot_grub2_grub.cfg
    local_file="$WORK_TMP/$local_name"
    # Extract silently; skip if the file doesn't exist in this ISO
    xorriso -indev "$ORIGINAL_ISO" -osirrox on -extract "$iso_path" "$local_file" -- 2>/dev/null || true
    [[ -f "$local_file" ]] || { warn "Not found in ISO: $iso_path (skipping)"; continue; }
    # Set default to entry 0 (Install) instead of 1 (Test media & install)
    sed -i 's/^set default="1"/set default="0"/' "$local_file"
    # Reduce GRUB timeout from 60s to 10s
    sed -i 's/^set timeout=.*/set timeout=10/' "$local_file"
    # For VM mode: replace hd:LABEL= stage2 search with cdrom so dracut finds the
    # ISO immediately rather than waiting for the IDE CD-ROM to enumerate by label.
    if [[ "$MODE" == "vm" ]]; then
        sed -i 's|inst\.stage2=hd:LABEL=[^ ]*|inst.stage2=cdrom|g' "$local_file"
    fi
    # Inject kickstart boot parameter after inst.stage2=
    sed -i 's|\(inst\.stage2=[^ ]*\)|\1 inst.ks=cdrom:/ks.cfg|g' "$local_file"
    grep -q "inst.ks" "$local_file" \
        && ok "Patched $iso_path" \
        || warn "sed matched nothing in $iso_path — check grub.cfg format"
done

# Build new ISO: start from original, splice in ks.cfg + patched grub configs,
# replay the original boot catalog so UEFI and legacy BIOS both work.
info "Building ISO (xorriso splice)..."
rm -f "$OUTPUT"

XORRISO_ARGS=(
    -indev  "$ORIGINAL_ISO"
    -outdev "$OUTPUT"
    -map    "$KS_FILE" /ks.cfg
    -chmod  0444 /ks.cfg --
)

# Add patched grub configs if we produced them
for iso_path in /boot/grub2/grub.cfg /EFI/BOOT/grub.cfg; do
    local_name="${iso_path//\//_}"
    local_file="$WORK_TMP/$local_name"
    [[ -f "$local_file" ]] && XORRISO_ARGS+=(-map "$local_file" "$iso_path")
done

XORRISO_ARGS+=(-boot_image any replay)

xorriso "${XORRISO_ARGS[@]}" 2>&1 | grep -E "^xorriso|ERROR|WARNING|Added|Replaced|writing|done\." || true

if [[ -f "$OUTPUT" && -s "$OUTPUT" ]]; then
    ok "ISO created: $OUTPUT"
    ok "Size: $(du -h "$OUTPUT" | cut -f1)"
else
    die "ISO build failed — output missing or empty"
fi

# Embed MD5 checksum so Anaconda's media check passes
if command -v implantisomd5 >/dev/null 2>&1; then
    info "Embedding ISO checksum..."
    implantisomd5 "$OUTPUT"
    ok "Checksum embedded"
else
    warn "implantisomd5 not found — media check will show 'NA' (install still works)"
    warn "Install: sudo dnf install isomd5sum"
fi

echo ""
echo "${B}ISO ready for installation:${X}"
echo "  Write to USB: sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress"
echo ""
