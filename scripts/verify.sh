#!/usr/bin/env bash
# ==============================================================================
# verify.sh — provisioning status board for the Fedora dev+gaming kickstart
# ==============================================================================
# Runs AFTER an install (VM or bare metal) and asserts that every tool the
# kickstart was supposed to install is present, and every service it was
# supposed to enable is enabled. Prints a green/red list and a final tally.
#
# Design for the VM-first pipeline:
#   - Hardware checks (Nvidia / AMD / Asus) auto-SKIP when the hardware isn't
#     present, so this script gives a clean PASS in a VirtualBox/VMware guest
#     and only asserts the GPU/Asus layer on the actual ProArt.
#   - Exit code is 0 only if there are no hard FAILs (skips don't count).
#
# Run as the SAME user the kickstart provisioned (devuser), NOT root — many
# tools live in per-user dirs (nvm, mise, cargo, ~/.npm-global, flatpak --user).
#
# Usage:
#   ./verify.sh              # full report
#   ./verify.sh --quiet      # only show FAIL lines + summary
#   ./verify.sh --no-hw      # force-skip all hardware checks (pure VM mode)
# ==============================================================================

set -uo pipefail

QUIET=0
FORCE_NO_HW=0
for arg in "$@"; do
    case "$arg" in
        --quiet)  QUIET=1 ;;
        --no-hw)  FORCE_NO_HW=1 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 22; exit 0 ;;
    esac
done

# ----- colors (disabled if not a tty) -----
if [[ -t 1 ]]; then
    G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; X=$'\e[0m'
else
    G=""; R=""; Y=""; B=""; X=""
fi

PASS=0; FAIL=0; SKIP=0
FAILED_ITEMS=()

# ----- output helpers -----
ok()   { (( PASS++ )); [[ "$QUIET" -eq 0 ]] && printf "  ${G}[ OK ]${X} %s\n" "$1"; }
bad()  { (( FAIL++ )); FAILED_ITEMS+=("$1"); printf "  ${R}[FAIL]${X} %s\n" "$1"; }
skip() { (( SKIP++ )); [[ "$QUIET" -eq 0 ]] && printf "  ${Y}[SKIP]${X} %s\n" "$1"; }
hdr()  { [[ "$QUIET" -eq 0 ]] && printf "\n${B}%s${X}\n" "$1"; }

# ----- check primitives -----
# A command exists on PATH (or in common per-user bin dirs we source below).
have() { command -v "$1" >/dev/null 2>&1; }

check_cmd() {  # check_cmd <command> [friendly-label]
    local cmd="$1" label="${2:-$1}"
    if have "$cmd"; then ok "$label ($(command -v "$cmd"))"; else bad "$label — '$cmd' not on PATH"; fi
}

check_any() {  # check_any <label> <cmd1> [cmd2...] — passes if ANY present
    local label="$1"; shift
    local c
    for c in "$@"; do
        if have "$c"; then ok "$label ($c)"; return; fi
    done
    bad "$label — none of: $* found"
}

check_file() {  # check_file <path> <label>
    if [[ -e "$1" ]]; then ok "$2"; else bad "$2 — missing $1"; fi
}

check_rpm() {  # check_rpm <pkg> [label]
    local pkg="$1" label="${2:-$1}"
    if rpm -q "$pkg" >/dev/null 2>&1; then ok "$label (rpm)"; else bad "$label — rpm '$pkg' not installed"; fi
}

check_service() {  # check_service <unit> <label> — enabled (not necessarily running)
    local unit="$1" label="$2"
    if systemctl list-unit-files "$unit" >/dev/null 2>&1 && \
       systemctl is-enabled "$unit" >/dev/null 2>&1; then
        ok "$label (enabled)"
    elif systemctl is-active "$unit" >/dev/null 2>&1; then
        ok "$label (active)"
    else
        bad "$label — '$unit' not enabled"
    fi
}

check_flatpak() {  # check_flatpak <app-id> <label>
    if have flatpak && flatpak info "$1" >/dev/null 2>&1; then
        ok "$2 (flatpak)"
    else
        bad "$2 — flatpak '$1' not installed"
    fi
}

check_docker_running() {
    # Stronger than is-enabled: a daemon can be "enabled" yet crash-loop on
    # startup (e.g. firewalld ZONE_CONFLICT binding docker0). Assert it's
    # actually active AND the socket responds to `docker info`.
    if ! systemctl is-enabled docker.service >/dev/null 2>&1 \
       && ! systemctl is-active docker.service >/dev/null 2>&1; then
        bad "Docker daemon — docker.service not enabled or active"
        return
    fi
    if ! systemctl is-active docker.service >/dev/null 2>&1; then
        bad "Docker daemon — enabled but NOT running (check: journalctl -u docker -- often a firewalld docker0 zone conflict)"
        return
    fi
    # Daemon claims active — confirm it actually answers. `docker info` needs a
    # live socket; if it hangs/fails the daemon isn't truly serving.
    if have docker && timeout 10 docker info >/dev/null 2>&1; then
        ok "Docker daemon (running + responding to 'docker info')"
    elif have docker && timeout 10 sudo -n docker info >/dev/null 2>&1; then
        ok "Docker daemon (running; works via sudo — add \$USER to 'docker' group + re-login)"
    else
        bad "Docker daemon — active but 'docker info' failed (socket unreachable, or user not in docker group / needs re-login)"
    fi
}

# ----- source per-user toolchains so their shims are on PATH -----
# These are installed per-user by the kickstart; a non-login shell won't have
# them yet, so pull them in for the duration of this check.
export PATH="$HOME/.local/bin:$HOME/bin:$HOME/.npm-global/bin:$HOME/.cargo/bin:$PATH"
[[ -s "$HOME/.nvm/nvm.sh" ]] && . "$HOME/.nvm/nvm.sh" >/dev/null 2>&1 || true
have mise && eval "$(mise activate bash 2>/dev/null)" >/dev/null 2>&1 || true

# ----- hardware detection (gates the GPU/Asus section) -----
HW_NVIDIA=0; HW_AMD=0; HW_ASUS=0
if [[ "$FORCE_NO_HW" -eq 0 ]]; then
    have lspci && lspci | grep -qi 'nvidia'            && HW_NVIDIA=1
    have lspci && lspci | grep -qiE 'amd/ati|advanced micro devices' && HW_AMD=1
    if [[ -r /sys/class/dmi/id/sys_vendor ]]; then
        grep -qi 'asus' /sys/class/dmi/id/sys_vendor && HW_ASUS=1
    fi
fi

# ==============================================================================
echo "${B}Fedora dev+gaming provisioning check${X}  ($(date '+%Y-%m-%d %H:%M'))"
echo "host: $(hostname)   user: $(whoami)   kernel: $(uname -r)"

# ----- repos / base -----
hdr "Repositories & base"
if have dnf; then
    if dnf repolist 2>/dev/null | grep -qi 'rpmfusion-free'; then ok "RPM Fusion free"; else bad "RPM Fusion free — repo not enabled"; fi
    if dnf repolist 2>/dev/null | grep -qi 'rpmfusion-nonfree'; then ok "RPM Fusion nonfree"; else bad "RPM Fusion nonfree — repo not enabled"; fi
else
    bad "dnf — package manager missing (?!)"
fi
check_cmd flatpak "Flatpak"

# ----- container / orchestration -----
hdr "Containers & Kubernetes"
check_cmd docker "Docker CLI"
check_docker_running
check_any "docker compose" docker-compose
have docker && docker compose version >/dev/null 2>&1 && ok "docker compose (v2 plugin)" || skip "docker compose v2 plugin (check after first 'docker' run)"
check_cmd podman "Podman"
check_cmd kubectl "kubectl"
check_cmd helm "Helm"
check_cmd k9s "k9s"
check_cmd kind "kind"
check_any "kubectx/kubens" kubectx kubens
check_cmd ctop "ctop"
check_cmd dive "dive"

# ----- PHP / dev toolchain -----
hdr "PHP & dev toolchain"
check_cmd php "PHP"
check_cmd composer "Composer"
check_cmd symfony "Symfony CLI"
check_cmd drush "Drush"
check_any "PHPStan" phpstan
check_any "php-cs-fixer" php-cs-fixer php-cs-fixer.phar
check_cmd mkcert "mkcert"
# Xdebug is a PHP extension, not a binary. Optional for local dev (use dump/dd instead).
if have php && php -m 2>/dev/null | grep -qi xdebug; then 
    ok "Xdebug (php extension, optional)"
else 
    skip "Xdebug — not loaded (optional; use dump()/dd() or logs instead)"
fi

# ----- language version managers / runtimes -----
hdr "Runtimes & version managers"
check_cmd mise "mise"
if have mise; then
    for t in php python ruby node; do
        if mise ls --installed 2>/dev/null | grep -qi "^$t\|  *$t "; then
            ok "mise: $t installed"
        else
            skip "mise: $t — not yet installed (run 'mise install')"
        fi
    done
fi
check_any "Node.js" node
check_any "npm" npm
check_cmd bun "Bun"
check_cmd deno "Deno"

# ----- gaming -----
hdr "Gaming"
check_any "Steam" steam steam-runtime || check_rpm steam "Steam"
check_flatpak com.heroicgameslauncher.hgl "Heroic (Flatpak)"
check_cmd lutris "Lutris"
check_any "GameMode" gamemoded gamemode
check_any "MangoHud" mangohud
check_flatpak net.davidotek.pupgui2 "ProtonUp-Qt (Flatpak)" 2>/dev/null || skip "ProtonUp-Qt — flatpak not found (optional)"

# ----- networking / infra tools -----
hdr "Networking & infra"
check_cmd tailscale "Tailscale CLI"
check_service tailscaled.service "tailscaled"
check_any "dnsmasq" dnsmasq
check_cmd gh "GitHub CLI"
check_cmd starship "Starship prompt"
check_cmd fwupdmgr "fwupd"
check_service thermald.service "thermald"
check_service fail2ban.service "fail2ban"
check_service dnf-automatic.timer "dnf-automatic (timer)"

# ----- IDE / workstation -----
hdr "IDE & workstation tooling"
# JetBrains Toolbox installs to ~/.local/share/JetBrains or similar:
if have jetbrains-toolbox || ls "$HOME"/.local/share/JetBrains/Toolbox* >/dev/null 2>&1 \
   || [[ -x "$HOME/.local/bin/jetbrains-toolbox" ]]; then
    ok "JetBrains Toolbox"
else
    bad "JetBrains Toolbox — not found in PATH or ~/.local"
fi
check_any "Chef Workstation" chef chef-client knife
check_any "Claude Code" claude

# ----- Ollama + RAG stack -----
hdr "Ollama & RAG"
check_service ollama.service "Ollama daemon"
if have ollama; then
    if ollama list 2>/dev/null | grep -q 'qwen2.5-coder:7b-instruct-q5_K_M'; then
        ok "Qwen2.5 Coder 7B (Q5_K_M) model downloaded"
    else
        bad "Qwen2.5 Coder 7B model — not downloaded (run: ollama pull qwen2.5-coder:7b-instruct-q5_K_M)"
    fi
else
    bad "ollama CLI — not on PATH"
fi
have docker && docker inspect open-webui >/dev/null 2>&1 && \
    ok "Open WebUI container running (http://localhost:3000)" || \
    bad "Open WebUI container — not running"
check_file /usr/local/bin/ollama-backend "ollama-backend script"
check_file /usr/local/bin/ollama-local "ollama-local script (GPU mode)"
check_file /usr/local/bin/ollama-remote "ollama-remote script (GPU mode)"
check_file /etc/ollama-backend.conf "Ollama backend config"
[[ -f /etc/systemd/system/ollama.service.d/override.conf ]] && \
    ok "Ollama systemd drop-in (CUDA_VISIBLE_DEVICES=0)" || \
    bad "Ollama systemd config — drop-in not found"

# ----- memory / system tuning -----
hdr "System tuning"
if swapon --show 2>/dev/null | grep -qi zram || systemctl is-active systemd-zram-setup@zram0.service >/dev/null 2>&1; then
    ok "ZRAM active"
else
    bad "ZRAM — no zram swap device active"
fi
check_file /etc/systemd/zram-generator.conf "ZRAM generator config"

# ----- SSH hardening -----
hdr "SSH hardening"
if [[ -r /etc/ssh/sshd_config ]] || ls /etc/ssh/sshd_config.d/* >/dev/null 2>&1; then
    if grep -rqiE '^\s*PasswordAuthentication\s+no' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null; then
        ok "SSH password auth disabled"
    else
        bad "SSH — PasswordAuthentication not set to no"
    fi
else
    skip "SSH config — sshd not configured (fine if headless VM)"
fi

# ==============================================================================
# HARDWARE-GATED SECTION — auto-skips in a VM
# ==============================================================================
hdr "Hardware: Nvidia RTX 4060"
if [[ "$HW_NVIDIA" -eq 1 ]]; then
    check_rpm akmod-nvidia "akmod-nvidia package"
    # The akmod must have actually BUILT against the running kernel:
    if ls /lib/modules/"$(uname -r)"/extra/nvidia/nvidia.ko* >/dev/null 2>&1; then
        ok "nvidia.ko built for running kernel"
    else
        bad "nvidia kernel module — not built for $(uname -r) yet (akmods may still be compiling; check after reboot)"
    fi
    if have nvidia-smi && nvidia-smi >/dev/null 2>&1; then
        ok "nvidia-smi responds (driver loaded)"
    else
        bad "nvidia-smi — driver not loaded/responding"
    fi
    check_file /usr/local/bin/prime-run "prime-run helper"
    check_any "libva nvidia driver" /usr/lib64/dri/nvidia_drv_video.so 2>/dev/null || check_rpm libva-nvidia-driver "libva-nvidia-driver"
else
    skip "Nvidia checks — no Nvidia GPU detected (VM or iGPU-only)"
fi

hdr "Hardware: AMD iGPU (Mesa)"
if [[ "$HW_AMD" -eq 1 ]]; then
    # Vulkan is the primary acceleration path on modern Fedora; VA-API is legacy.
    # mesa-va-drivers package was renamed/restructured in Fedora 44.
    check_any "Vulkan loader" vulkaninfo
    [[ -e /dev/dri/renderD128 ]] && ok "DRI render node present" || bad "AMD — no /dev/dri render node"
else
    skip "AMD Mesa checks — no AMD GPU detected"
fi

hdr "Hardware: Asus ProArt (asusctl/supergfxctl)"
if [[ "$HW_ASUS" -eq 1 ]]; then
    check_cmd asusctl "asusctl"
    check_cmd supergfxctl "supergfxctl"
    check_service supergfxd.service "supergfxd"
    check_any "ROG Control Center" rog-control-center
else
    skip "Asus checks — not an Asus chassis"
fi

hdr "GPU default: iGPU rendering policy"
KWIN_ENV="$HOME/.config/plasma-workspace/env/kwin-gpu.sh"
if [[ -f "$KWIN_ENV" ]]; then
    grep -q "KWIN_DRM_DEVICES=/dev/dri/card1" "$KWIN_ENV" \
        && ok "KWin bound to AMD iGPU (card1)" \
        || bad "kwin-gpu.sh present but KWIN_DRM_DEVICES not set to card1"
    grep -q "__EGL_VENDOR_LIBRARY_FILENAMES.*50_mesa" "$KWIN_ENV" \
        && ok "EGL vendor forced to Mesa (AMD)" \
        || bad "kwin-gpu.sh present but __EGL_VENDOR_LIBRARY_FILENAMES not set to Mesa"
    grep -q "__GLX_VENDOR_LIBRARY_NAME=mesa" "$KWIN_ENV" \
        && ok "GLX vendor forced to Mesa (AMD)" \
        || bad "kwin-gpu.sh present but __GLX_VENDOR_LIBRARY_NAME not set to mesa"
else
    bad "~/.config/plasma-workspace/env/kwin-gpu.sh missing — apps may default to Nvidia GPU"
fi

# ==============================================================================
# SUMMARY
# ==============================================================================
echo ""
echo "${B}========================= SUMMARY =========================${X}"
printf "  ${G}PASS: %d${X}    ${R}FAIL: %d${X}    ${Y}SKIP: %d${X}\n" "$PASS" "$FAIL" "$SKIP"
if [[ "$FAIL" -gt 0 ]]; then
    echo ""
    echo "  ${R}Failed items:${X}"
    for item in "${FAILED_ITEMS[@]}"; do
        echo "    - $item"
    done
    echo ""
    echo "  ${Y}Note:${X} on a fresh bare-metal install, akmod-nvidia may still be"
    echo "  compiling — re-run after a reboot before treating Nvidia as broken."
    echo "${B}==========================================================${X}"
    exit 1
else
    echo "  ${G}All present checks passed.${X}"
    echo "${B}==========================================================${X}"
    exit 0
fi
