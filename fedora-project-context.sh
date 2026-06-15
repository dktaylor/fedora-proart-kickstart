#!/usr/bin/env bash
# ==============================================================================
# FEDORA 44 PROVISIONING PROJECT CONTEXT
# ==============================================================================
# Export this file and source it to resume the project from terminal
# Usage: source fedora-project-context.sh
# ==============================================================================

# Project metadata
export PROJECT_NAME="Fedora 44 ProArt Kickstart"
export PROJECT_DATE="2026-06-14"
export PROJECT_STATUS="ISO build successful — ready for installation"
export HARDWARE="Asus ProArt 16 7606WV (AMD Ryzen AI iGPU + RTX 4060)"
export USERNAME="devuser"
export FEDORA_VERSION="44"

# Key directories
export FEDORA_BUILD_DIR="$HOME/fedora-build"
export SCRIPTS_DIR="$FEDORA_BUILD_DIR/scripts"
export KS_DIR="$FEDORA_BUILD_DIR/kickstart"
export ISO_DIR="$FEDORA_BUILD_DIR/iso"
export TESTING_DIR="$FEDORA_BUILD_DIR/testing"
export HERMES_DIR="$FEDORA_BUILD_DIR/hermes"
export DOCS_DIR="$FEDORA_BUILD_DIR/docs"
export OUTPUT_DIR="$HOME/.local/share/fedora-builds"

# ISO information
export ISO_FILENAME="Fedora-Everything-netinst-x86_64-44-1.7.iso"
export ISO_PATH="$ISO_DIR/$ISO_FILENAME"
export CUSTOM_ISO_AUTO="$FEDORA_BUILD_DIR/fedora-everything-ks.iso"
export CUSTOM_ISO_MANUAL="$FEDORA_BUILD_DIR/fedora-everything-ks-manual.iso"
export CUSTOM_ISO_VM="$FEDORA_BUILD_DIR/fedora-everything-ks-vm.iso"

# Kickstart files
export KS_AUTO="$KS_DIR/fedora-ks-auto.cfg"
export KS_MANUAL="$KS_DIR/fedora-ks-manual.cfg"
export KS_VM="$KS_DIR/fedora-ks-vm.cfg"

# Build scripts
export BUILD_SCRIPT="$SCRIPTS_DIR/build-fedora-ks-iso.sh"
export FETCH_SCRIPT="$SCRIPTS_DIR/fetch-fedora-iso.sh"
export VERIFY_SCRIPT="$SCRIPTS_DIR/verify.sh"
export OLLAMA_GPU_SCRIPT="$SCRIPTS_DIR/ollama-gpu-mode.sh"
export POSTINSTALL_SCRIPT="$SCRIPTS_DIR/fedora-postinstall-setup.sh"

# ==============================================================================
# PROJECT PROGRESS
# ==============================================================================
# 
# COMPLETED:
# ✓ Fedora 44 KDE installed and dual-booting
# ✓ 44-step postinstall script created and verified
# ✓ All 9 bug fixes applied (HOME env vars, Xdebug, mesa-va-drivers, etc.)
# ✓ Ollama + RAG stack configured (qwen2.5-coder:7b-instruct-q5_K_M)
# ✓ Open WebUI running on port 3000
# ✓ GPU mode switching scripts (local/remote/toggle)
# ✓ Custom kickstart ISO builder created
# ✓ Custom ISO built successfully (1.2GB, with embedded kickstart)
# ✓ verify.sh status check (63 PASS / 0 FAIL / 4 SKIP)
#
# NEXT STEPS:
# 1. Flash custom ISO to USB: sudo dd if=$CUSTOM_ISO_AUTO of=/dev/sdX bs=4M status=progress
# 2. Boot from USB on bare metal or VM
# 3. Kickstart should auto-load and begin unattended installation
# 4. After install, run postinstall: $POSTINSTALL_SCRIPT
# 5. Verify with: $VERIFY_SCRIPT
#
# PENDING MANUAL ACTIONS:
# - Set DESKTOP_IP in /etc/ollama-backend.conf (from: tailscale ip -4 on desktop)
# - Change devuser password (currently: placeholder)
# - Run: mokutil --import /etc/pki/akmods/certs/public_key.der (Secure Boot)
# - Run: tailscale up
# - Run: gh auth login
# - Run: fwupdmgr update
#

# ==============================================================================
# OLLAMA + RAG CONFIGURATION
# ==============================================================================
export OLLAMA_MODEL="qwen2.5-coder:7b-instruct-q5_K_M"
export OLLAMA_DESKTOP_MODEL="qwen2.5-coder:7b-instruct-q8_0"
export OLLAMA_PORT="11434"
export WEBUI_PORT="3000"
export WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"

# Local vs remote configuration
export OLLAMA_MODE="local"  # Change to "remote" for desktop endpoint
export DESKTOP_HOST="desktop"
export DESKTOP_IP=""  # TODO: fill in with: tailscale ip -4

# Shell aliases for Ollama management
alias ob='ollama-backend'
alias ob-local='ollama-backend local'
alias ob-remote='ollama-backend remote'
alias ob-toggle='ollama-backend toggle'
alias ob-status='ollama-backend status'
alias gpu-local='sudo ollama-local'
alias gpu-remote='sudo ollama-remote'
alias qwen='ollama run qwen2.5-coder:7b-instruct-q5_K_M'
alias qwen-list='ollama list'
alias qwen-ps='ollama ps'

# ==============================================================================
# DISK LAYOUT
# ==============================================================================
# nvme0n1p1:    260MiB EFI (shared with Windows)
# nvme0n1p2:     16MiB Windows MSR
# nvme0n1p3:    1.87TiB NTFS (Windows C:)
# nvme0n1p4:     2GiB Asus restore (do not delete)
# nvme0n1p5:     260MiB recovery
# nvme0n1p6:     - (MYASUS)
# Fedora:
#   /boot/efi:  reused (nvme0n1p1)
#   /boot:      2GiB ext4
#   LVM VG fedora-os:
#     /         150GiB ext4
#     /home     ~1.7TiB ext4
#

# ==============================================================================
# USEFUL COMMANDS
# ==============================================================================

# Build custom ISO
build_iso_auto() {
    cd "$FEDORA_BUILD_DIR" && bash "$BUILD_SCRIPT" auto
}

build_iso_manual() {
    cd "$FEDORA_BUILD_DIR" && bash "$BUILD_SCRIPT" manual
}

build_iso_vm() {
    cd "$FEDORA_BUILD_DIR" && bash "$BUILD_SCRIPT" vm
}

# Flash ISO to USB (REQUIRES: device path)
flash_iso() {
    local device="${1:?Usage: flash_iso /dev/sdX}"
    echo "Flashing $CUSTOM_ISO_AUTO to $device..."
    sudo dd if="$CUSTOM_ISO_AUTO" of="$device" bs=4M status=progress
    echo "Done! Safely eject with: sudo eject $device"
}

# Run verification checks
verify_install() {
    bash "$VERIFY_SCRIPT"
}

# Run postinstall setup
postinstall() {
    bash "$POSTINSTALL_SCRIPT"
}

# Switch Ollama to local GPU mode
gpu_mode_local() {
    sudo bash "$OLLAMA_GPU_SCRIPT" local --yes
}

# Switch Ollama to remote endpoint
gpu_mode_remote() {
    sudo bash "$OLLAMA_GPU_SCRIPT" remote --yes
}

# Quick status check
project_status() {
    echo "=== Fedora 44 Provisioning Project Status ==="
    echo "Project: $PROJECT_NAME"
    echo "Status: $PROJECT_STATUS"
    echo ""
    echo "Key files:"
    echo "  Build dir: $FEDORA_BUILD_DIR"
    echo "  Custom ISO: $CUSTOM_ISO_AUTO ($(du -h "$CUSTOM_ISO_AUTO" 2>/dev/null | cut -f1))"
    echo "  Postinstall: $POSTINSTALL_SCRIPT"
    echo ""
    echo "Quick commands:"
    echo "  build_iso_auto          # Build kickstart ISO"
    echo "  flash_iso /dev/sdX      # Flash to USB"
    echo "  verify_install          # Run verify.sh"
    echo "  postinstall             # Run postinstall setup"
    echo "  gpu_mode_local          # Switch Ollama to local"
    echo "  gpu_mode_remote         # Switch Ollama to remote"
}

# ==============================================================================
# CHAT CONTEXT SUMMARY
# ==============================================================================
# 
# This project involved:
# 1. Creating Fedora 44 KDE provisioning scripts for Asus ProArt 16 7606WV
# 2. Developing 44-step postinstall setup with Docker/Ollama/RAG stack
# 3. Fixing 9 critical bugs in provisioning (env vars, permissions, etc.)
# 4. Building custom kickstart ISO for unattended installation
# 5. Creating GPU mode switching scripts for local/remote Ollama endpoints
# 6. Implementing verify.sh with 63+ comprehensive checks
#
# All scripts are syntax-verified and production-ready.
# ISO is built and ready for bare-metal installation.
#
# ==============================================================================

echo "✓ Fedora 44 Provisioning Project Context Loaded"
echo "  Run 'project_status' for overview"
echo "  All variables exported for terminal use"
