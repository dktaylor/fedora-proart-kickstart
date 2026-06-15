#!/usr/bin/env bash
# ==============================================================================
# test-vm.sh — KVM/QEMU full kickstart test runner
# ==============================================================================
# Builds the VM kickstart ISO and boots it in a KVM virtual machine so the
# full Anaconda install + %post script can be validated without bare metal.
#
# GPU drivers, Asus hardware, and Nvidia PRIME steps are automatically skipped
# inside the VM (controlled by VM_INSTALL=1 in fedora-ks-vm.cfg %post).
#
# Usage:
#   ./testing/test-vm.sh              # build VM ISO + create + start VM
#   ./testing/test-vm.sh --no-build   # skip ISO build (reuse existing)
#   ./testing/test-vm.sh --destroy    # delete the test VM and disk image
#
# Requirements:
#   - qemu-kvm, libvirt, virt-install (installed automatically if missing)
#   - The Fedora 44 base ISO in iso/ (run scripts/fetch-fedora-iso.sh first)
#   - ~250 GB free disk space for the VM image
#   - Active internet connection (packages downloaded during install)
#
# After install completes, connect with:
#   virt-manager                        # GUI console
#   virsh console fedora44-ks-test      # text console
#   ssh devuser@$(virsh domifaddr fedora44-ks-test | awk '/ipv4/{print $4}' | cut -d/ -f1)
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VM_NAME="fedora44-ks-test"
VM_RAM_MB=8192
VM_VCPUS=4
VM_DISK_GB=200
VM_DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
VM_ISO="${REPO_ROOT}/fedora-everything-ks-vm.iso"

BUILD_ISO=1
DESTROY=0

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
        --no-build) BUILD_ISO=0 ;;
        --destroy)  DESTROY=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
            exit 0 ;;
        *) die "Unknown option: $arg (use --help)" ;;
    esac
done

# ── Destroy mode ──────────────────────────────────────────────────────────────
if [[ "$DESTROY" -eq 1 ]]; then
    info "Destroying VM: $VM_NAME"
    virsh destroy  "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
    ok "VM $VM_NAME destroyed"
    exit 0
fi

# ── Install KVM/libvirt if needed ─────────────────────────────────────────────
PKGS_NEEDED=()
for pkg in qemu-kvm libvirt virt-install; do
    rpm -q "$pkg" >/dev/null 2>&1 || PKGS_NEEDED+=("$pkg")
done

if [[ ${#PKGS_NEEDED[@]} -gt 0 ]]; then
    info "Installing KVM prerequisites: ${PKGS_NEEDED[*]}"
    sudo dnf install -y "${PKGS_NEEDED[@]}"
fi

# ── Enable + start libvirtd ───────────────────────────────────────────────────
if ! systemctl is-active libvirtd >/dev/null 2>&1; then
    info "Starting libvirtd..."
    sudo systemctl enable --now libvirtd
fi
ok "libvirtd running"

# ── Build VM ISO ──────────────────────────────────────────────────────────────
if [[ "$BUILD_ISO" -eq 1 ]]; then
    info "Building VM kickstart ISO..."
    bash "${REPO_ROOT}/scripts/build-fedora-ks-iso.sh" vm
else
    warn "--no-build: skipping ISO build, using existing: $VM_ISO"
fi

[[ -f "$VM_ISO" ]] || die "VM ISO not found: $VM_ISO — run without --no-build first"
ok "VM ISO: $VM_ISO ($(du -h "$VM_ISO" | cut -f1))"

# ── Remove existing VM if present ─────────────────────────────────────────────
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    warn "VM '$VM_NAME' already exists — removing it first"
    virsh destroy  "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
fi

# ── Create and boot VM ────────────────────────────────────────────────────────
info "Creating VM: $VM_NAME (${VM_RAM_MB}MB RAM, ${VM_VCPUS} vCPUs, ${VM_DISK_GB}GB disk)..."

sudo virt-install \
    --name          "$VM_NAME" \
    --ram           "$VM_RAM_MB" \
    --vcpus         "$VM_VCPUS" \
    --disk          "path=${VM_DISK_PATH},size=${VM_DISK_GB},format=qcow2,bus=virtio" \
    --cdrom         "$VM_ISO" \
    --os-variant    fedora39 \
    --network       network=default,model=virtio \
    --graphics      vnc,listen=127.0.0.1 \
    --video         virtio \
    --boot          cdrom,hd \
    --noautoconsole \
    --wait          -1 2>&1 | grep -v "^$" || true

echo ""
echo "${B}============================================================${X}"
echo " VM install started: ${VM_NAME}"
echo "${B}============================================================${X}"
echo ""
echo " Monitor progress:"
echo "   virt-manager                    # GUI (recommended)"
echo "   virsh console $VM_NAME   # text console (Ctrl+] to exit)"
echo ""
echo " After install completes, the VM will reboot automatically."
echo " Then run verify.sh inside the VM:"
echo "   ssh devuser@<vm-ip> 'bash /path/to/scripts/verify.sh --no-hw'"
echo ""
echo " Get VM IP:"
echo "   virsh domifaddr $VM_NAME"
echo ""
echo " To destroy the VM when done:"
echo "   ./testing/test-vm.sh --destroy"
echo "${B}============================================================${X}"
