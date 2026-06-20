#!/usr/bin/env bash
# ==============================================================================
# rag-ctl — RAG stack lifecycle manager (Open WebUI + Qdrant + Ollama)
# ==============================================================================
# Direct usage (after install):
#   rag-start    rag-stop    rag-restart    rag-status
#
# Or via rag-ctl directly:
#   rag-ctl {start|stop|restart|status}
#
# First-time setup (run once after cloning — installs commands + systemd):
#   sudo ./scripts/rag-ctl.sh install
#
# Systemd integration (available after install):
#   sudo systemctl start   rag-stack
#   sudo systemctl stop    rag-stack
#   sudo systemctl restart rag-stack
#   sudo systemctl status  rag-stack
#
# rag-start/stop/restart do NOT require sudo when devuser is in the docker group.
# ==============================================================================

set -uo pipefail

SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
RAG_DIR="${RAG_DIR:-/opt/rag-stack}"
COMPOSE_FILE="$RAG_DIR/docker-compose.yml"
WEBUI_PORT="${WEBUI_PORT:-3000}"
QDRANT_PORT="${QDRANT_PORT:-6333}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
INSTALL_DIR="/usr/local/bin"
UNIT_NAME="rag-stack"

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; X=$'\e[0m'
else
    B=""; G=""; Y=""; R=""; C=""; X=""
fi

info()  { printf "${B}>>>${X} %s\n" "$*"; }
ok()    { printf "  ${G}[ok]${X}   %s\n" "$*"; }
warn()  { printf "  ${Y}[warn]${X} %s\n" "$*"; }
fail()  { printf "  ${R}[fail]${X} %s\n" "$*"; }
die()   { fail "$*" >&2; exit 1; }
hdr()   { printf "\n${B}%s${X}\n" "$*"; }

# ── Command detection ─────────────────────────────────────────────────────────
# Invoked as a symlink (rag-start, rag-stop, rag-restart, rag-status)?
SELF="$(basename "$0" .sh)"
case "$SELF" in
    rag-start)   CMD="start"   ;;
    rag-stop)    CMD="stop"    ;;
    rag-restart) CMD="restart" ;;
    rag-status)  CMD="status"  ;;
    *)           CMD="${1:-status}" ;;
esac

# ── Helpers ───────────────────────────────────────────────────────────────────

require_rag_dir() {
    [[ -f "$COMPOSE_FILE" ]] || die "RAG stack not found at $RAG_DIR — run setup first or set RAG_DIR="
}

compose() {
    docker compose -f "$COMPOSE_FILE" "$@"
}

port_up() {
    curl -sf --connect-timeout 2 "http://localhost:$1" >/dev/null 2>&1 \
    || curl -sf --connect-timeout 2 "http://localhost:$1/healthz" >/dev/null 2>&1 \
    || curl -sf --connect-timeout 2 "http://localhost:$1/api/version" >/dev/null 2>&1 \
    || curl -sf --connect-timeout 2 "http://localhost:$1/api/tags" >/dev/null 2>&1
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_start() {
    require_rag_dir
    info "Starting RAG stack..."
    compose up -d --remove-orphans
    sleep 2
    cmd_status
}

cmd_stop() {
    require_rag_dir
    info "Stopping RAG stack..."
    compose down
    ok "RAG stack stopped"
}

cmd_restart() {
    require_rag_dir
    info "Restarting RAG stack..."
    compose down
    sleep 1
    compose up -d --remove-orphans
    sleep 2
    cmd_status
}

cmd_status() {
    hdr "RAG Stack — Containers"
    local found=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        found=1
        name="${line%%	*}"
        rest="${line#*	}"
        if echo "$rest" | grep -q "^Up"; then
            printf "  ${G}[up]${X}   %s  %s\n" "$name" "$rest"
        else
            printf "  ${Y}[--]${X}   %s  %s\n" "$name" "$rest"
        fi
    done < <(docker ps -a \
        --filter "name=open-webui" \
        --filter "name=qdrant" \
        --format $'{{.Names}}\t{{.Status}}' 2>/dev/null || true)
    [[ "$found" -eq 0 ]] && warn "No RAG containers found (stack not started or no containers deployed)"

    # Ollama
    hdr "Ollama — Daemon"
    if systemctl is-active --quiet ollama 2>/dev/null; then
        local pid; pid=$(systemctl show ollama -p MainPID --value 2>/dev/null || echo "?")
        ok "ollama.service  active (PID $pid)"
    else
        warn "ollama.service  inactive — sudo systemctl start ollama"
    fi

    hdr "Port Health"
    local labels=("Open WebUI  :$WEBUI_PORT" "Qdrant      :$QDRANT_PORT" "Ollama      :$OLLAMA_PORT")
    local ports=("$WEBUI_PORT" "$QDRANT_PORT" "$OLLAMA_PORT")
    for i in 0 1 2; do
        if port_up "${ports[$i]}"; then
            ok "${labels[$i]}"
        else
            fail "${labels[$i]}  — not responding"
        fi
    done

    hdr "Ollama — Models"
    if command -v ollama >/dev/null 2>&1 && systemctl is-active --quiet ollama 2>/dev/null; then
        local models
        models=$(ollama list 2>/dev/null | tail -n +2)
        if [[ -n "$models" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                name=$(echo "$line" | awk '{print $1}')
                size=$(echo "$line" | awk '{print $3, $4}')
                printf "  ${C}*${X} %-44s %s\n" "$name" "$size"
            done <<< "$models"
        else
            warn "No models loaded"
        fi
    else
        warn "Ollama not running — models unavailable"
    fi
    echo ""
}

cmd_install() {
    [[ "$EUID" -eq 0 ]] || die "install requires root: sudo $0 install"

    hdr "Installing rag-ctl to $INSTALL_DIR..."

    # Install the script itself
    cp "$SCRIPT_PATH" "$INSTALL_DIR/rag-ctl"
    chmod +x "$INSTALL_DIR/rag-ctl"
    ok "rag-ctl"

    # Symlinks for each shortcut command
    for cmd in rag-start rag-stop rag-restart rag-status; do
        ln -sf "$INSTALL_DIR/rag-ctl" "$INSTALL_DIR/$cmd"
        ok "$cmd  →  rag-ctl"
    done

    hdr "Installing systemd service ($UNIT_NAME.service)..."

    cat > "/etc/systemd/system/${UNIT_NAME}.service" << UNIT
[Unit]
Description=RAG Stack — Open WebUI + Qdrant
Documentation=https://github.com/open-webui/open-webui
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${RAG_DIR}
ExecStart=/usr/bin/docker compose -f ${RAG_DIR}/docker-compose.yml up -d --remove-orphans
ExecStop=/usr/bin/docker compose -f ${RAG_DIR}/docker-compose.yml down
TimeoutStartSec=120
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable "${UNIT_NAME}.service"
    ok "${UNIT_NAME}.service  enabled (auto-starts on boot)"

    echo ""
    printf "${B}════════════════════════════════════════════${X}\n"
    printf " RAG control commands ready:\n"
    echo ""
    printf "  ${G}rag-start${X}            start Open WebUI + Qdrant\n"
    printf "  ${G}rag-stop${X}             stop  Open WebUI + Qdrant\n"
    printf "  ${G}rag-restart${X}          restart the stack\n"
    printf "  ${G}rag-status${X}           health + container + model list\n"
    echo ""
    printf "  Systemd (requires sudo):\n"
    printf "  ${C}sudo systemctl start   ${UNIT_NAME}${X}\n"
    printf "  ${C}sudo systemctl stop    ${UNIT_NAME}${X}\n"
    printf "  ${C}sudo systemctl restart ${UNIT_NAME}${X}\n"
    printf "  ${C}sudo systemctl status  ${UNIT_NAME}${X}\n"
    echo ""
    printf "  Stack auto-starts at boot (${UNIT_NAME}.service enabled).\n"
    printf "${B}════════════════════════════════════════════${X}\n"
    echo ""
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$CMD" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    status)  cmd_status  ;;
    install) cmd_install ;;
    *)
        echo "Usage: rag-ctl {start|stop|restart|status|install}"
        echo "       rag-start | rag-stop | rag-restart | rag-status"
        echo ""
        echo "First-time setup: sudo $(basename "$0") install"
        exit 1
        ;;
esac
