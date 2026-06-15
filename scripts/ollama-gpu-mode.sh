#!/usr/bin/env bash
# ==============================================================================
# ollama-gpu-mode.sh — unified toggle: switch between local GPU and remote
#                      desktop inference, including GPU mode changes
# ==============================================================================
# Switches the Asus ProArt between two complete configurations:
#
#   local   : GPU mode -> Hybrid  (iGPU on display, RTX 4060 free for CUDA)
#             + local Ollama daemon running on the dGPU
#             + Open WebUI -> localhost:11434
#
#   remote  : GPU mode -> Integrated (dGPU powered OFF, max battery)
#             + local Ollama daemon STOPPED
#             + all clients point at desktop Ollama over Tailscale
#             + Open WebUI -> desktop:11434
#
# GPU mode changes require a LOGOUT (driver reload, display manager restart).
# All Ollama configuration happens immediately; GPU switch takes effect at logout.
#
# Run as your normal user (NOT root). Uses sudo only for systemd/privileged ops.
#
# Usage:
#   ./ollama-gpu-mode.sh local              # Hybrid + local CUDA inference
#   ./ollama-gpu-mode.sh remote             # Integrated + remote inference
#   ./ollama-gpu-mode.sh local --yes        # skip GPU confirmation prompt
#   ./ollama-gpu-mode.sh remote --no-webui  # don't reconfigure Open WebUI
#
# Configuration (set before running, or edit defaults below):
#   DESKTOP_HOST       Tailscale MagicDNS name              (default: desktop)
#   DESKTOP_IP         Tailscale IP (for container DNS)     (default: empty)
#   DESKTOP_PORT       Ollama port on desktop               (default: 11434)
#   LOCAL_CUDA_DEVICE  CUDA device index for local dGPU     (default: 0)
#   WEBUI_CONTAINER    Open WebUI container name            (default: open-webui)
#   WEBUI_PORT         WebUI host port                      (default: 3000)
#   KB_REPO_DIR        optional git-synced knowledge base    (default: empty)
#
# If DESKTOP_IP is not set, the container may fail to resolve the desktop
# hostname via Tailscale MagicDNS. Get it from the desktop:
#   $ tailscale ip -4
# Then export DESKTOP_IP="<ip>" before running, or edit this script.
# ==============================================================================

set -uo pipefail

# ============================================================================
# Configuration (override via environment or edit here)
# ============================================================================
DESKTOP_HOST="${DESKTOP_HOST:-desktop}"
DESKTOP_IP="${DESKTOP_IP:-}"
DESKTOP_PORT="${DESKTOP_PORT:-11434}"
LOCAL_CUDA_DEVICE="${LOCAL_CUDA_DEVICE:-0}"
WEBUI_CONTAINER="${WEBUI_CONTAINER:-open-webui}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
WEBUI_INTERNAL_PORT="${WEBUI_INTERNAL_PORT:-8080}"
WEBUI_IMAGE="${WEBUI_IMAGE:-ghcr.io/open-webui/open-webui:main}"
KB_REPO_DIR="${KB_REPO_DIR:-}"

DESKTOP_URL="http://${DESKTOP_HOST}:${DESKTOP_PORT}"

# ============================================================================
# Argument parsing
# ============================================================================
MODE=""
ASSUME_YES=0
MANAGE_WEBUI=1

for arg in "$@"; do
    case "$arg" in
        local|remote)  MODE="$arg" ;;
        --yes|-y)      ASSUME_YES=1 ;;
        --no-webui)    MANAGE_WEBUI=0 ;;
        -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 40; exit 0 ;;
        *)             echo "Unknown argument: $arg (see --help)"; exit 1 ;;
    esac
done

if [[ -z "$MODE" ]]; then
    echo "Usage: $0 {local|remote} [--yes] [--no-webui]"
    echo "       $0 --help"
    exit 1
fi

# ============================================================================
# Color output (disable in non-interactive shells)
# ============================================================================
if [[ -t 1 ]]; then
    G=$'\e[32m'  # green
    R=$'\e[31m'  # red
    Y=$'\e[33m'  # yellow
    B=$'\e[1m'   # bold
    X=$'\e[0m'   # reset
else
    G=""; R=""; Y=""; B=""; X=""
fi

# ============================================================================
# Output helpers
# ============================================================================
info() { printf "${B}>>>${X} %s\n" "$*"; }
ok()   { printf "  ${G}[ok]${X} %s\n" "$*"; }
warn() { printf "  ${Y}[warn]${X} %s\n" "$*"; }
err()  { printf "  ${R}[err]${X} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
    [[ "$ASSUME_YES" -eq 1 ]] && return 0
    local reply
    read -r -p "  ?  $1 [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ============================================================================
# Preflight checks
# ============================================================================
[[ "$(id -u)" -ne 0 ]] || die "Run as your normal user, not root (uses sudo where needed)."
have supergfxctl || die "supergfxctl not found — is asus-linux installed?"

# ============================================================================
# GPU mode utilities
# ============================================================================
current_gpu_mode() {
    supergfxctl -g 2>/dev/null | tr -d '[:space:]'
}

set_gpu_mode() {
    local target="$1"
    local cur
    cur="$(current_gpu_mode)"
    
    if [[ "$cur" == "$target" ]]; then
        ok "GPU already in $target mode."
        return 0
    fi
    
    info "Switching GPU mode: ${cur:-unknown} → $target"
    warn "This reloads the Nvidia driver and requires a LOGOUT to complete."
    
    if ! confirm "Proceed with GPU mode switch to $target?"; then
        warn "GPU switch cancelled. Ollama config was still applied."
        return 0
    fi
    
    local out
    if out="$(supergfxctl -m "$target" 2>&1)"; then
        ok "supergfxctl: ${out:-mode set}"
        GPU_SWITCHED=1
        return 0
    else
        err "supergfxctl failed: $out"
        return 1
    fi
}

# ============================================================================
# Ollama systemd configuration
# ============================================================================
write_ollama_dropin() {
    # Write a systemd drop-in for the ollama.service with environment overrides
    local env_lines=("$@")
    
    sudo install -d -m 0755 /etc/systemd/system/ollama.service.d
    {
        echo "[Service]"
        for line in "${env_lines[@]}"; do
            echo "Environment=\"$line\""
        done
    } | sudo tee /etc/systemd/system/ollama.service.d/override.conf >/dev/null
    
    sudo systemctl daemon-reload
}

# ============================================================================
# Open WebUI management
# ============================================================================
reconfigure_webui() {
    # Reconfigure Open WebUI container to point at a different Ollama backend
    # Usage: reconfigure_webui <ollama_base_url> [docker args...]
    
    [[ "$MANAGE_WEBUI" -eq 1 ]] || {
        info "Skipping Open WebUI (--no-webui flag)."
        return 0
    }
    
    have docker || {
        warn "docker not found; skipping Open WebUI configuration."
        return 0
    }
    
    if ! docker info >/dev/null 2>&1; then
        warn "Docker daemon unreachable; skipping WebUI. Start docker and re-run."
        return 0
    fi
    
    local base_url="$1"
    shift
    local extra_args=("$@")
    
    # Stop and remove the old container
    if docker inspect "$WEBUI_CONTAINER" >/dev/null 2>&1; then
        info "Recreating '$WEBUI_CONTAINER' → $base_url"
        docker rm -f "$WEBUI_CONTAINER" >/dev/null 2>&1 || true
    else
        info "Starting '$WEBUI_CONTAINER' → $base_url"
    fi
    
    # Run the new container with the updated base URL
    # The 'open-webui' named volume persists RAG docs, chats, and settings
    if docker run -d \
        -p "${WEBUI_PORT}:${WEBUI_INTERNAL_PORT}" \
        "${extra_args[@]}" \
        -e OLLAMA_BASE_URL="$base_url" \
        -v open-webui:/app/backend/data \
        --name "$WEBUI_CONTAINER" \
        --restart unless-stopped \
        "$WEBUI_IMAGE" >/dev/null 2>&1; then
        ok "Open WebUI running on http://localhost:${WEBUI_PORT} → $base_url"
    else
        err "Failed to start Open WebUI container."
        return 1
    fi
}

# ============================================================================
# Mode: LOCAL (Hybrid GPU + local CUDA inference)
# ============================================================================
apply_local() {
    info "Mode: LOCAL  (Hybrid GPU + RTX 4060 CUDA inference)"
    
    have ollama || warn "ollama not on PATH (daemon config still written)."
    
    # 1. Configure the local Ollama daemon to use the dGPU (CUDA device 0)
    write_ollama_dropin "CUDA_VISIBLE_DEVICES=$LOCAL_CUDA_DEVICE"
    ok "Ollama systemd drop-in written (CUDA_VISIBLE_DEVICES=$LOCAL_CUDA_DEVICE)."
    
    # 2. Clear any system-wide remote client endpoint
    sudo rm -f /etc/profile.d/ollama-endpoint.sh 2>/dev/null || true
    ok "Cleared remote endpoint (CLI clients now use localhost)."
    
    # 3. Enable and restart the local Ollama daemon
    sudo systemctl enable ollama >/dev/null 2>&1 || true
    if sudo systemctl restart ollama 2>/dev/null; then
        ok "Local Ollama daemon enabled and restarted."
    else
        warn "Could not restart ollama.service (is it installed?)."
    fi
    
    # 4. Point Open WebUI at the local Ollama
    # From inside the container, use host.docker.internal to reach the host
    reconfigure_webui "http://host.docker.internal:11434" \
        --add-host=host.docker.internal:host-gateway
    
    # 5. Switch GPU mode to Hybrid (requires logout)
    set_gpu_mode "Hybrid"
}

# ============================================================================
# Mode: REMOTE (Integrated GPU + desktop Ollama over Tailscale)
# ============================================================================
apply_remote() {
    info "Mode: REMOTE  (Integrated GPU + desktop Ollama @ $DESKTOP_URL)"
    
    # 1. Optional: sync git-based knowledge base before switching
    if [[ -n "$KB_REPO_DIR" && -d "$KB_REPO_DIR/.git" ]]; then
        info "Syncing knowledge base in $KB_REPO_DIR..."
        if git -C "$KB_REPO_DIR" pull --ff-only >/dev/null 2>&1; then
            ok "Knowledge base synchronized."
        else
            warn "git pull failed in $KB_REPO_DIR (uncommitted? offline?). Continuing."
        fi
    fi
    
    # 2. Check if the desktop Ollama is reachable
    if have curl; then
        if curl -fsS --max-time 5 "${DESKTOP_URL}/api/tags" >/dev/null 2>&1; then
            ok "Desktop Ollama reachable at $DESKTOP_URL."
        else
            warn "Desktop Ollama NOT reachable at $DESKTOP_URL."
            warn "Check: desktop is on, Ollama running, Tailscale connected."
            warn "Continuing anyway; clients will fail until reachable."
        fi
    fi
    
    # 3. Stop the local daemon BEFORE powering off the dGPU
    # (CUDA must release the device first; Integrated mode won't work otherwise)
    if sudo systemctl disable --now ollama >/dev/null 2>&1; then
        ok "Local Ollama daemon stopped and disabled."
    else
        warn "Could not disable ollama.service (may not be installed)."
    fi
    
    # 4. Set system-wide Ollama endpoint for CLI clients
    # New shells will auto-source this and point at the desktop
    sudo tee /etc/profile.d/ollama-endpoint.sh >/dev/null <<EOF
# Set by ollama-gpu-mode.sh (remote mode): Ollama clients use desktop.
export OLLAMA_HOST="$DESKTOP_URL"
EOF
    ok "CLI endpoint set to $DESKTOP_URL (source /etc/profile.d/ollama-endpoint.sh in current shell)."
    
    # 5. Point Open WebUI at the desktop
    # If DESKTOP_IP is provided, add it as a host entry so the container can resolve
    # the Tailscale MagicDNS name (Docker's resolver doesn't know Tailscale)
    local webui_args=()
    if [[ -n "$DESKTOP_IP" ]]; then
        webui_args=(--add-host="${DESKTOP_HOST}:${DESKTOP_IP}")
        ok "Using DESKTOP_IP=$DESKTOP_IP for container DNS."
    else
        warn "DESKTOP_IP not set — container may fail to resolve '$DESKTOP_HOST'."
        warn "Set DESKTOP_IP (get it from 'tailscale ip -4' on the desktop) and re-run."
    fi
    
    reconfigure_webui "$DESKTOP_URL" "${webui_args[@]}"
    
    # 6. Switch GPU mode to Integrated (requires logout)
    set_gpu_mode "Integrated"
}

# ============================================================================
# Main dispatch
# ============================================================================
GPU_SWITCHED=0

case "$MODE" in
    local)  apply_local ;;
    remote) apply_remote ;;
    *)      die "Unknown mode: $MODE" ;;
esac

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "${B}==================== ${MODE} mode configured ==================${X}"

if [[ "$GPU_SWITCHED" -eq 1 ]]; then
    echo "  ${Y}⚠ GPU mode changed → LOG OUT (or reboot) to complete the switch.${X}"
    echo ""
    echo "  After logging back in:"
    if [[ "$MODE" == "local" ]]; then
        echo "    • nvidia-smi          # confirm RTX 4060 is available"
        echo "    • ollama ps           # check if GPU is in use"
        echo "    • qwen                # test the local model"
    else
        echo "    • nvidia-smi          # should show no devices (dGPU off)"
        echo "    • curl http://localhost:3000  # test Open WebUI"
        echo "    • ollama list         # should list desktop's models"
    fi
else
    echo "  Ollama configuration applied. (GPU mode unchanged.)"
fi

echo "${B}=====================================================================${X}"
echo ""
