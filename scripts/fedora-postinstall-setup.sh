#!/usr/bin/env bash
# ==============================================================================
# Fedora ProArt Post-Install Setup — standalone re-runnable version
# ==============================================================================
# WHY THIS EXISTS:
#   During the kickstart install, %post ran inside the installed-system chroot
#   BEFORE WiFi/NetworkManager was active, so every network-dependent step
#   (Steam/RPM Fusion, Heroic/Flatpak, mise tools, GitHub-hosted binaries,
#   COPR repos, Tailscale, etc.) failed with "IO error talking to the server".
#   This script re-runs that whole %post on the LIVE, networked system.
#
# HOW TO RUN:
#   1. Make sure you're booted into the installed Fedora with WiFi connected:
#        ping -c 3 github.com
#   2. Copy this script to your home dir, then:
#        chmod +x fedora-postinstall-setup.sh
#        sudo ./fedora-postinstall-setup.sh
#
# NOTES:
#   - Uses 'set +e' (continue on error) so a single failure won't abort the run.
#     A summary of failed steps prints at the end.
#   - Most steps are idempotent (they check-before-install), so anything that
#     already succeeded during the install is skipped harmlessly.
#   - Run as root (sudo). User-specific steps target 'devuser' explicitly.
#   - Re-running is safe. If a step fails (e.g. transient network), just run
#     the whole script again.
# ==============================================================================

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run with sudo:  sudo ./fedora-postinstall-setup.sh"
    exit 1
fi

# The original %post ran as root with $HOME=/root and operated on the new
# system directly. A few steps write into the dev user's home; we define it
# here so those steps target the right place when run post-boot.
TARGET_USER="devuser"
TARGET_HOME="/home/${TARGET_USER}"

# Continue on error — collect failures instead of aborting
set +e
FAILED_STEPS=()
trap 'FAILED_STEPS+=("line $LINENO: $BASH_COMMAND")' ERR

# Confirm network before doing anything
echo "Checking network connectivity..."
if ! ping -c 2 -W 3 github.com &>/dev/null; then
    echo "WARNING: github.com unreachable. WiFi may not be connected."
    echo "Connect to WiFi first, then re-run. Continuing anyway in 5s..."
    sleep 5
fi

# ------------------------------------------------------------------------------
# Fedora 44 ca-certificates compatibility (Change: droppingOfCertPemFile)
# Fedora 44 deletes the legacy CA bundle files — /etc/pki/tls/cert.pem,
# /etc/pki/tls/certs/ca-bundle.crt, ca-certificates.crt — and the /etc/ssl/certs
# symlinked copies, moving to the directory-hash format. Tools that hardcode
# those old bundle paths (notably Go binaries doing strict SystemCertPool
# lookups, and some installer scripts — this is what breaks the Symfony CLI
# repo install) then fail TLS verification. Point cert-aware tools at the
# canonical bundle that DOES still exist, per Fedora's own guidance. This is the
# recommended path, NOT the discouraged `update-ca-trust extract --rhbz...` hack.
CANON_CA_BUNDLE="/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem"
if [ -f "$CANON_CA_BUNDLE" ]; then
    export SSL_CERT_FILE="$CANON_CA_BUNDLE"    # Go, openssl, many libs honor this
    export CURL_CA_BUNDLE="$CANON_CA_BUNDLE"   # curl
    export SSL_CERT_DIR="/etc/pki/tls/certs"   # directory-hash form (still present)
    echo "  CA bundle pinned to $CANON_CA_BUNDLE (Fedora 44 cert-path compat)."
fi


echo "=============================================="
echo " Fedora Post-Install Configuration Starting"
echo "=============================================="

# ------------------------------------------------------------------------------
# RPM Fusion (Free + Non-Free)
# Required for: Steam, media codecs, Nvidia/AMD drivers, MangoHud
# ------------------------------------------------------------------------------
echo "[1/41] Enabling RPM Fusion repositories..."
dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

dnf group upgrade -y core || true
dnf group upgrade -y multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin

# ------------------------------------------------------------------------------
# GPU Drivers — Asus ProArt 16 7606WV
# Hardware: AMD Ryzen AI iGPU (display output) + Nvidia RTX 4060 (dGPU)
#
# This is a hybrid MUX-switch laptop. The display is driven by the AMD iGPU
# by default; the RTX 4060 handles heavy rendering via PRIME offload or
# direct MUX-switch mode (controlled by asusctl/supergfxctl, configured
# in the Asus hardware step later).
#
# DRIVER STRATEGY:
#   - AMD iGPU: open source amdgpu driver (built into kernel, auto-loaded)
#   - Nvidia dGPU: proprietary akmod-nvidia from RPM Fusion
#   - Both coexist via PRIME — no conflict
#
# SECURE BOOT NOTE:
#   akmod-nvidia builds a kernel module that must be signed to work with
#   Secure Boot. Since we disabled Secure Boot in BIOS pre-install, the
#   module builds and loads without signing. If you re-enable Secure Boot
#   later, enroll the MOK key: mokutil --import /etc/pki/akmods/certs/public_key.der
#   Then reboot and confirm enrollment in the MOK manager screen.
# ------------------------------------------------------------------------------
echo "[2/41] Installing GPU drivers (Nvidia RTX 4060 + AMD hybrid)..."

# AMD iGPU — open driver stack (Mesa already installed via RPM Fusion above)
# The amdgpu kernel module loads automatically; these add userspace support
dnf install -y --skip-unavailable \
    mesa-dri-drivers \
    mesa-vulkan-drivers \
    mesa-va-drivers \
    mesa-vdpau-drivers \
    xorg-x11-drv-amdgpu

# Nvidia RTX 4060 — proprietary driver via RPM Fusion nonfree
# akmod-nvidia builds the kernel module automatically on each kernel update
# nvidia-vaapi-driver enables VA-API video decode via Nvidia (for media playback)
dnf install -y --skip-unavailable \
    akmod-nvidia \
    xorg-x11-drv-nvidia \
    xorg-x11-drv-nvidia-cuda \
    xorg-x11-drv-nvidia-cuda-libs \
    xorg-x11-drv-nvidia-power \
    libva-nvidia-driver \
    nvidia-settings \
    libvdpau \
    vdpauinfo

# Wait for akmods to finish building the Nvidia kernel module
# This can take 2-5 minutes — the module must be built before first boot
echo "Waiting for akmod-nvidia to build kernel module..."
akmods --force --kernels "$(uname -r)" 2>/dev/null || true

# 32-bit libs required for Steam/Proton Nvidia path
dnf install -y \
    mesa-dri-drivers.i686 \
    mesa-vulkan-drivers.i686 \
    vulkan-loader.i686 \
    nvidia-driver-libs.i686 \
    wine-core.i686 2>/dev/null || true

# Nvidia DRM kernel parameter — already set in bootloader --append above
# (nvidia-drm.modeset=1) — required for Wayland + Nvidia to work correctly

# Configure Nvidia power management for hybrid laptop use
# NVreg_DynamicPowerManagement=0x02 = fine-grained power management
# Allows the RTX 4060 to fully power off when not in use (battery life)
cat > /etc/modprobe.d/nvidia-power.conf << 'NVPWR'
options nvidia NVreg_DynamicPowerManagement=0x02
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia-drm modeset=1
NVPWR

# Blacklist nouveau — must not coexist with proprietary driver
cat > /etc/modprobe.d/blacklist-nouveau.conf << 'NOUVEAU'
blacklist nouveau
options nouveau modeset=0
NOUVEAU

# Regenerate initramfs with nouveau blacklisted
dracut --force 2>/dev/null || true

# ------------------------------------------------------------------------------
# Asus ProArt hardware support
# asusctl — Asus control daemon: fan curves, keyboard backlight, performance
#            profiles, battery charge limit, MUX switch control
# supergfxctl — GPU switching daemon: handles iGPU/dGPU/hybrid/VFIO modes
#
# Both require the asus-linux COPR repository — not in standard Fedora repos.
# COPR: https://copr.fedorainfracloud.org/coprs/lukenukem/asus-linux/
# ------------------------------------------------------------------------------
echo "[3/41] Installing Asus ProArt hardware support (asusctl + supergfxctl)..."

# Enable asus-linux COPR repository
dnf copr enable -y lukenukem/asus-linux

# Install asusctl and supergfxctl
dnf install -y \
    asusctl \
    supergfxctl \
    rog-control-center

# Enable daemons
systemctl enable asusd
systemctl enable supergfxd

# Default asusctl profile — Balanced on AC, Quiet on battery
# Performance profiles: Quiet, Balanced, Performance
# Change with: asusctl profile -P Performance
mkdir -p /etc/asusd
cat > /etc/asusd/asusd-user.conf << 'ASUSCONF'
[power_profiles_linked_epp]
ac = "Performance"
battery = "Balanced"

[fan_store]
fan_preset = "Balanced"
ASUSCONF

# Battery charge limit — 80% preserves long-term battery health
# For prolonged AC use, increase to 100 with: asusctl -c 100
asusctl -c 80 2>/dev/null || true

# ------------------------------------------------------------------------------
# Nvidia PRIME + MUX switch configuration for ProArt hybrid GPU
# supergfxctl manages three modes:
#   Integrated  — AMD iGPU only (best battery life, Nvidia fully off)
#   Hybrid      — AMD iGPU renders desktop, Nvidia available via PRIME offload
#   NvidiaNoModeset — Nvidia drives display directly (best gaming performance)
#
# Default is Hybrid — best balance for dev + gaming use.
# Switch modes with: supergfxctl -m Integrated / Hybrid / NvidiaNoModeset
# MUX switch changes require logout/login (or reboot for NvidiaNoModeset).
# ------------------------------------------------------------------------------
echo "[4/41] Configuring Nvidia PRIME and MUX switch..."

# Set default GPU mode to Hybrid
# Nvidia available on-demand for Steam/Heroic/Lutris via PRIME offload
# Desktop and light apps run on AMD iGPU (power efficient)
supergfxctl -m Hybrid 2>/dev/null || true

# PRIME offload helper script — run any app on the RTX 4060 explicitly
# Usage: prime-run steam, prime-run %command% in Steam launch options
cat > /usr/local/bin/prime-run << 'PRIMERUN'
#!/usr/bin/env bash
# Force-run any application on the Nvidia RTX 4060 via PRIME offload
# Usage: prime-run <application> [args...]
export __NV_PRIME_RENDER_OFFLOAD=1
export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json
exec "$@"
PRIMERUN
chmod +x /usr/local/bin/prime-run

# Udev rules — ensure Nvidia dGPU power management works correctly
cat > /etc/udev/rules.d/80-nvidia-pm.rules << 'UDEVRULES'
# Enable runtime power management for Nvidia GPU
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", \
    ATTR{class}=="0x030200", TEST=="power/control", \
    ATTR{power/control}="auto"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", \
    ATTR{class}=="0x030000", TEST=="power/control", \
    ATTR{power/control}="auto"
# Enable runtime power management for Nvidia audio device
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", \
    ATTR{class}=="0x040300", TEST=="power/control", \
    ATTR{power/control}="auto"
UDEVRULES

udevadm control --reload-rules 2>/dev/null || true

# KDE desktop entries for quick GPU mode switching
mkdir -p /usr/share/applications
cat > /usr/share/applications/gpu-mode-hybrid.desktop << 'HYBRIDDE'
[Desktop Entry]
Name=GPU Mode: Hybrid (AMD+Nvidia)
Exec=supergfxctl -m Hybrid
Icon=preferences-system
Type=Application
Categories=System;
Comment=Switch to Hybrid GPU mode (AMD display, Nvidia on-demand)
HYBRIDDE

cat > /usr/share/applications/gpu-mode-integrated.desktop << 'INTEGRATEDDE'
[Desktop Entry]
Name=GPU Mode: Integrated (AMD only)
Exec=supergfxctl -m Integrated
Icon=preferences-system
Type=Application
Categories=System;
Comment=Switch to Integrated GPU mode (AMD only, best battery life)
INTEGRATEDDE

cat > /usr/share/applications/gpu-mode-nvidia.desktop << 'NVDE'
[Desktop Entry]
Name=GPU Mode: Nvidia (dGPU direct)
Exec=supergfxctl -m NvidiaNoModeset
Icon=preferences-system
Type=Application
Categories=System;
Comment=Switch to Nvidia-only mode (RTX 4060 drives display, best gaming)
NVDE

# Default all KDE/app rendering to AMD iGPU — RTX 4060 reserved for CUDA/Ollama
# and explicit prime-run. Takes effect at next KDE login.
# card0 = Nvidia (RTX 4060), card1 = AMD iGPU on this machine.
# Override per-app with: prime-run <app>  OR  prime-run %command% in Steam
mkdir -p /home/devuser/.config/plasma-workspace/env
cat > /home/devuser/.config/plasma-workspace/env/kwin-gpu.sh << 'KWINENV'
# Default all rendering to AMD iGPU — RTX 4060 reserved for CUDA/Ollama and explicit prime-run
export KWIN_DRM_DEVICES=/dev/dri/card1
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
export __GLX_VENDOR_LIBRARY_NAME=mesa
KWINENV
chown -R devuser:devuser /home/devuser/.config/plasma-workspace

# ------------------------------------------------------------------------------
# Steam
# ------------------------------------------------------------------------------
echo "[5/41] Installing Steam..."
dnf install -y steam

# ------------------------------------------------------------------------------
# Heroic Games Launcher (Epic + GoG)
# ------------------------------------------------------------------------------
echo "[6/41] Installing Heroic Games Launcher..."
# Flathub is the officially recommended Heroic install method and is far more
# reliable than guessing the GitHub RPM asset filename (which changes format).
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub com.heroicgameslauncher.hgl

# ------------------------------------------------------------------------------
# Proton-GE via ProtonUp-Qt (Flatpak)
# ------------------------------------------------------------------------------
echo "[7/41] Setting up Flatpak + ProtonUp-Qt..."
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub net.davidotek.pupgui2     # ProtonUp-Qt
flatpak install -y flathub com.github.tchx84.Flatseal # Flatpak permissions manager

# ------------------------------------------------------------------------------
# GameMode + MangoHud tweaks
# ------------------------------------------------------------------------------
echo "[8/41] Configuring GameMode and MangoHud..."
dnf install -y gamemode gamemode-devel mangohud

# MangoHud global config
mkdir -p /etc/MangoHud
cat > /etc/MangoHud/MangoHud.conf << 'MANGOHUD_CONF'
fps
gpu_stats
cpu_stats
ram
vram
frame_timing
MANGOHUD_CONF

# ------------------------------------------------------------------------------
# Docker CE (Official Docker repo — not Fedora's package)
# ------------------------------------------------------------------------------
echo "[9/41] Installing Docker CE..."
dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo --overwrite || dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable docker
systemctl enable containerd

# Add devuser to docker group (already set in user --groups above, this is a safety net)
usermod -aG docker devuser

# Fix Fedora firewalld ZONE_CONFLICT: on first start dockerd tries to create the
# docker0 bridge, but firewalld may have already bound docker0 to the 'trusted'
# zone (leftover from a prior install or firewalld auto-assignment), causing
# dockerd to abort. Start once to trigger the binding, remove it, then restart.
systemctl start docker 2>/dev/null || true
firewall-cmd --permanent --zone=trusted --remove-interface=docker0 2>/dev/null || true
firewall-cmd --reload 2>/dev/null || true
systemctl restart docker 2>/dev/null || true

# ------------------------------------------------------------------------------
# Kubernetes tooling
# ------------------------------------------------------------------------------
echo "[10/41] Installing Kubernetes tooling..."

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# k9s (Kubernetes TUI)
K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
curl -L "https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz" \
    -o /tmp/k9s.tar.gz
tar -xzf /tmp/k9s.tar.gz -C /usr/local/bin k9s
rm -f /tmp/k9s.tar.gz

# kubectx + kubens (context/namespace switcher)
curl -L https://github.com/ahmetb/kubectx/releases/latest/download/kubectx \
    -o /usr/local/bin/kubectx && chmod +x /usr/local/bin/kubectx
curl -L https://github.com/ahmetb/kubectx/releases/latest/download/kubens \
    -o /usr/local/bin/kubens && chmod +x /usr/local/bin/kubens

# ------------------------------------------------------------------------------
# PHP Composer + Symfony CLI
# ------------------------------------------------------------------------------
echo "[11/41] Installing Symfony CLI and Composer tools..."

# Symfony CLI — installed from the official GitHub release binary, NOT the
# cloudsmith dnf repo. The cloudsmith repo (still listed on symfony.com/download)
# is unreliable on Fedora: repo metadata + GPG handling under dnf5 fail, which is
# what broke this step. The release binary needs no repo, no GPG import, and no
# per-user HOME path — it's a single static binary dropped into /usr/local/bin.
# Idempotent: skips if already present.
if command -v symfony >/dev/null 2>&1; then
    echo "  Symfony CLI already installed ($(symfony version 2>/dev/null | head -1)), skipping."
else
    SF_ARCH="amd64"   # ProArt 16 7606WV is x86_64
    SF_TMP="$(mktemp -d)"
    for attempt in 1 2 3; do
        if curl -sSL "https://github.com/symfony-cli/symfony-cli/releases/latest/download/symfony-cli_linux_${SF_ARCH}.tar.gz" \
              | tar -xz -C "$SF_TMP" 2>/dev/null && [ -f "$SF_TMP/symfony" ]; then
            install -m 0755 "$SF_TMP/symfony" /usr/local/bin/symfony
            echo "  Symfony CLI installed to /usr/local/bin/symfony"
            break
        fi
        echo "  Symfony CLI download failed (attempt $attempt/3), retrying..."; sleep 3
    done
    rm -rf "$SF_TMP"
    command -v symfony >/dev/null 2>&1 \
        || echo "  WARNING: Symfony CLI still not installed; grab it manually from https://symfony.com/download"
fi

# Global Composer tools
sudo -u devuser composer global require \
    drupal/core-composer-scaffold \
    drush/drush \
    phpstan/phpstan \
    squizlabs/php_codesniffer \
    friendsofphp/php-cs-fixer

# Add Composer global bin to PATH for devuser
echo 'export PATH="$HOME/.config/composer/vendor/bin:$PATH"' >> /home/devuser/.bashrc
echo 'export PATH="$HOME/.config/composer/vendor/bin:$PATH"' >> /home/devuser/.zshrc 2>/dev/null || true

# ------------------------------------------------------------------------------
# Node.js global tools (Drupal/Symfony frontend tooling)
# ------------------------------------------------------------------------------
echo "[12/41] Installing Node.js global tools..."
npm install -g yarn
npm install -g @symfony/webpack-encore

# ------------------------------------------------------------------------------
# JetBrains Toolbox + IDEs (PHPStorm, DataGrip, PyCharm, RubyMine)
# Toolbox manages installs, updates, and licenses for all JetBrains products
# ------------------------------------------------------------------------------
echo "[13/41] Installing JetBrains Toolbox..."

TOOLBOX_URL=$(curl -s "https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release" \
    | python3 -c "import sys,json; data=json.load(sys.stdin); print(data['TBA'][0]['downloads']['linux']['link'])")

curl -L "$TOOLBOX_URL" -o /tmp/jetbrains-toolbox.tar.gz
mkdir -p /opt/jetbrains-toolbox
tar -xzf /tmp/jetbrains-toolbox.tar.gz -C /tmp/jetbrains-toolbox-extract --strip-components=1 2>/dev/null || \
    tar -xzf /tmp/jetbrains-toolbox.tar.gz -C /tmp/

# Find and move the binary
TOOLBOX_BIN=$(find /tmp -name "jetbrains-toolbox" -type f 2>/dev/null | head -1)
if [ -n "$TOOLBOX_BIN" ]; then
    install -o root -g root -m 0755 "$TOOLBOX_BIN" /usr/local/bin/jetbrains-toolbox
fi
rm -rf /tmp/jetbrains-toolbox* /tmp/jetbrains-toolbox-extract

# Required libs for JetBrains IDEs on Fedora
dnf install -y \
    fuse-libs \
    libxcb \
    libX11-xcb \
    libXrender \
    libXtst \
    libXi \
    mesa-libGL \
    freetype \
    fontconfig

# Desktop entry so devuser can launch Toolbox from KDE app menu
cat > /usr/share/applications/jetbrains-toolbox.desktop << 'DESKTOP'
[Desktop Entry]
Name=JetBrains Toolbox
Exec=/usr/local/bin/jetbrains-toolbox
Icon=jetbrains-toolbox
Type=Application
Categories=Development;IDE;
Comment=Manage JetBrains IDEs (PHPStorm, DataGrip, PyCharm, RubyMine)
DESKTOP

# NOTE: JetBrains IDEs (PHPStorm, DataGrip, PyCharm, RubyMine) must be installed
# through the Toolbox GUI on first login — they require user-level install and
# a JetBrains account/license. Launch Toolbox from the app menu after first boot.

# ------------------------------------------------------------------------------
# Chef Workstation (cookbooks + chef-solo)
# ------------------------------------------------------------------------------
echo "[14/41] Installing Chef Workstation..."
CHEF_VERSION=$(curl -s https://omnitruck.chef.io/stable/chef-workstation/metadata?p=fedora\&pv=40\&m=x86_64 \
    | grep "^version" | awk '{print $2}' | head -1)

# Use the Chef install script (handles version detection automatically)
curl -L https://omnitruck.chef.io/install.sh | bash -s -- -P chef-workstation

# Verify chef-solo is available (it's bundled inside Chef Workstation)
/opt/chef-workstation/bin/chef-solo --version || true

# Add Chef Workstation to PATH system-wide
cat > /etc/profile.d/chef-workstation.sh << 'CHEFPATH'
export PATH="/opt/chef-workstation/bin:$PATH"
CHEFPATH

# Add to devuser's zshrc (written later in step 15)
# PATH entry handled in the ZSHRC heredoc below

# ------------------------------------------------------------------------------
# GitHub CLI
# ------------------------------------------------------------------------------
echo "[15/41] Configuring GitHub CLI..."
# gh is installed via %packages — just verify and set up shell completion
gh completion -s zsh > /usr/share/zsh/site-functions/_gh 2>/dev/null || true
gh completion -s bash > /etc/bash_completion.d/gh 2>/dev/null || true

# ------------------------------------------------------------------------------
# Claude Code CLI
# NOTE: Requires Node.js 18+ (already installed). Do NOT use sudo with npm.
# Installed as devuser to avoid npm permission issues per Anthropic's guidance.
# Auth is done interactively on first run: claude auth login
# Requires Claude Pro, Max, Teams, Enterprise, or Anthropic API key.
# ------------------------------------------------------------------------------
echo "[16/41] Installing Claude Code CLI..."
# Configure a user-writable npm global prefix so 'npm -g' doesn't try to write
# to /usr/local/lib (which fails with EACCES when run as the unprivileged user).
sudo -u devuser mkdir -p /home/devuser/.npm-global
sudo -u devuser npm config set prefix /home/devuser/.npm-global
sudo -u devuser env PATH="/home/devuser/.npm-global/bin:$PATH" npm install -g @anthropic-ai/claude-code

# Verify install
sudo -u devuser /home/devuser/.npm-global/bin/claude --version 2>/dev/null || \
    echo "Claude Code installed — run 'claude auth login' after first boot"

# ------------------------------------------------------------------------------
# Shell & Terminal Setup
# ------------------------------------------------------------------------------
echo "[17/41] Configuring shell environment..."

# Set zsh as default shell for devuser
chsh -s /usr/bin/zsh devuser

# Install Oh My Zsh for devuser (idempotent: the installer exits non-zero if
# ~/.oh-my-zsh already exists, so skip when it's already there). HOME is set
# explicitly because `sudo -u` does not reliably reset it to devuser's home.
if [ ! -f /home/devuser/.oh-my-zsh/oh-my-zsh.sh ]; then
    sudo -u devuser env HOME=/home/devuser sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
    echo "  Oh My Zsh already installed for devuser, skipping."
fi

# Install zsh plugins (idempotent: clone if absent, else fast-forward pull).
clone_or_update_devuser() {  # <repo-url> <dest-dir>
    if [ -d "$2/.git" ]; then
        sudo -u devuser env HOME=/home/devuser git -C "$2" pull --ff-only 2>/dev/null || true
    else
        sudo -u devuser env HOME=/home/devuser git clone --depth=1 "$1" "$2"
    fi
}
clone_or_update_devuser https://github.com/zsh-users/zsh-autosuggestions \
    /home/devuser/.oh-my-zsh/custom/plugins/zsh-autosuggestions
clone_or_update_devuser https://github.com/zsh-users/zsh-syntax-highlighting \
    /home/devuser/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting

# Zsh config for devuser
cat > /home/devuser/.zshrc << 'ZSHRC'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="agnoster"
plugins=(
    git
    docker
    kubectl
    ansible
    composer
    symfony
    php
    zsh-autosuggestions
    zsh-syntax-highlighting
)
source $ZSH/oh-my-zsh.sh

# PATH additions
export PATH="$HOME/.config/composer/vendor/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
export PATH="/usr/local/bin:$PATH"
export PATH="/opt/chef-workstation/bin:$PATH"
export PATH="$HOME/.npm-global/bin:$PATH"

# Aliases — Dev
alias sail='[ -f sail ] && sh sail || sh vendor/bin/sail'
alias art='php artisan'
alias sf='symfony'
alias drush='vendor/bin/drush'

# Aliases — Chef
alias ks='knife status'
alias kn='knife node list'
alias cs='chef-solo'

# Aliases — Docker
alias dps='docker ps'
alias dco='docker compose'
alias dcup='docker compose up -d'
alias dcdown='docker compose down'

# Aliases — Kubernetes
alias k='kubectl'
alias kx='kubectx'
alias kns='kubens'

# Aliases — GitHub CLI
alias gpr='gh pr create'
alias gprl='gh pr list'
alias giss='gh issue list'

# Aliases — System
alias update='sudo dnf update -y'
alias cls='clear'
alias ll='ls -alF'
ZSHRC

chown devuser:devuser /home/devuser/.zshrc

# ------------------------------------------------------------------------------
# MariaDB initial setup
# ------------------------------------------------------------------------------
systemctl enable mariadb
systemctl enable postgresql
systemctl enable redis

# ------------------------------------------------------------------------------
# SSH Server Hardening
# Writes /etc/ssh/sshd_config.d/99-hardening.conf — drop-in overrides only,
# so the base sshd_config from the openssh-server package is left untouched
# and future package updates won't clobber these settings.
#
# Key decisions made here:
#   - Password auth disabled — key-only login enforced from day one
#   - Root login disabled — sudo via devuser only
#   - AllowUsers whitelist — only devuser can SSH in at all
#   - Port stays 22 — security through obscurity isn't worth the ops friction
#     on a dev machine, but change it here if your threat model differs
#   - X11 forwarding off — not needed; JetBrains and KDE run locally
#   - Strict ciphers/MACs/KexAlgorithms — removes CBC, MD5, SHA1, DH group1/14
#   - LoginGraceTime 30s — limits window for incomplete handshakes
#   - MaxAuthTries 3 — locks out brute-force attempts per connection quickly
#   - ClientAliveInterval — drops idle sessions after ~10 min
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# SSH Key Injection — Layer 2 (belt-and-suspenders %post)
#
# This block runs after Anaconda's sshkey directive (Layer 1) and guarantees:
#   1. The .ssh directory exists with correct 700 permissions and ownership
#   2. authorized_keys exists with correct 600 permissions and ownership
#   3. SELinux context on .ssh is correct (ssh_home_t) so sshd can read it
#   4. Supports multiple keys — add one per line inside the heredoc
#   5. Supports optional GitHub key fetch — uncomment the curl block below
#
# HOW TO USE:
#   Replace the placeholder line(s) inside the SSH_KEYS heredoc with your
#   actual public key(s). One key per line. Lines starting with # are ignored.
#
#   OPTION A — Paste keys directly (recommended for air-gapped installs):
#     Add your key(s) between the heredoc markers below.
#
#   OPTION B — Fetch from GitHub (convenient for netboot/PXE installs):
#     Uncomment the curl block and set GITHUB_USER to your GitHub username.
#     GitHub exposes all your public keys at https://github.com/<user>.keys
#
#   Both options can be used together — direct keys are written first,
#   then GitHub keys are appended if the fetch succeeds.
# ------------------------------------------------------------------------------
echo "[18/41] Injecting SSH authorized keys..."

SSH_DIR="/home/devuser/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

# Create .ssh directory with strict permissions
mkdir -p "${SSH_DIR}"

# -- OPTION A: Paste your public key(s) here, one per line --
# Lines starting with # are skipped. Replace the placeholder below.
cat >> "${AUTH_KEYS}" << 'SSH_KEYS'
# ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI_REPLACE_WITH_YOUR_PUBLIC_KEY devuser@fedora-dev
# ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI_OPTIONAL_SECOND_KEY laptop@home
SSH_KEYS

# Strip comment lines (lines starting with #) from authorized_keys
# so the placeholder lines above don't cause sshd parse warnings
sed -i '/^[[:space:]]*#/d' "${AUTH_KEYS}" 2>/dev/null || true
sed -i '/^[[:space:]]*$/d' "${AUTH_KEYS}" 2>/dev/null || true

# -- OPTION B: Fetch keys from GitHub (uncomment to enable) --
# Set GITHUB_USER to your GitHub username. All public keys attached to
# your GitHub account will be appended to authorized_keys automatically.
# This requires network access during the kickstart %post phase.
#
# GITHUB_USER="your-github-username"
# if [ -n "${GITHUB_USER}" ]; then
#     echo "Fetching SSH keys from GitHub for user: ${GITHUB_USER}"
#     curl -fsSL "https://github.com/${GITHUB_USER}.keys" >> "${AUTH_KEYS}" \
#         && echo "GitHub keys fetched successfully" \
#         || echo "WARNING: GitHub key fetch failed — check network and username"
# fi

# -- Enforce correct permissions regardless of how keys got here --
# sshd is strict: wrong perms = key auth silently refused
chmod 700 "${SSH_DIR}"
chmod 600 "${AUTH_KEYS}"
chown -R devuser:devuser "${SSH_DIR}"

# -- SELinux context: ssh_home_t lets sshd read authorized_keys --
# Without this, SELinux enforcing mode silently blocks key auth
restorecon -Rv "${SSH_DIR}" 2>/dev/null || \
    chcon -Rt ssh_home_t "${SSH_DIR}" 2>/dev/null || true

# -- Validate: report key count so the install log confirms injection --
KEY_COUNT=$(grep -c "^ssh-" "${AUTH_KEYS}" 2>/dev/null || echo 0)
if [ "${KEY_COUNT}" -gt 0 ]; then
    echo "SSH key injection: ${KEY_COUNT} key(s) written to ${AUTH_KEYS}"
else
    echo "WARNING: No SSH keys found in ${AUTH_KEYS}."
    echo "         Password auth is disabled by the hardening config."
    echo "         You must add a key manually before remote SSH will work."
    echo "         See post-install reminder for instructions."
fi

echo "[19/41] Hardening SSH..."

mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-hardening.conf << 'SSHDCONF'
# =============================================================================
# SSH hardening — drop-in config (overrides /etc/ssh/sshd_config)
# Generated by Fedora Kickstart post-install
# =============================================================================

# -- Access control --
PermitRootLogin no
AllowUsers devuser
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no

# -- Auth session limits --
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 5
MaxStartups 10:30:60

# -- Keep-alive / idle timeout (~10 minutes) --
ClientAliveInterval 120
ClientAliveCountMax 3

# -- Protocol & feature flags --
Protocol 2
X11Forwarding no
AllowAgentForwarding yes
AllowTcpForwarding yes
PermitTunnel no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
Compression delayed
UseDNS no

# -- Strict ciphers (removes CBC, RC4, 3DES) --
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr

# -- Strict MACs (removes MD5, SHA1, umac-64) --
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256

# -- Strict key exchange (removes DH group1, group14, gex-sha1) --
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,ecdh-sha2-nistp521,ecdh-sha2-nistp384

# -- Host key algorithms (Ed25519 first, then ECDSA; RSA only as fallback) --
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com,ecdsa-sha2-nistp256,ecdsa-sha2-nistp384,rsa-sha2-512,rsa-sha2-256

# -- Logging --
LogLevel VERBOSE
SyslogFacility AUTH
SSHDCONF

# Ensure Ed25519 host key exists (it may not on a fresh install)
# RSA key is already generated by openssh-server; Ed25519 is lighter and preferred
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    ssh-keygen -t ed25519 -f /etc/ssh/ssh_host_ed25519_key -N ""
fi

# Restrict permissions on all host private keys
chmod 600 /etc/ssh/ssh_host_*_key
chmod 644 /etc/ssh/ssh_host_*_key.pub
chown root:root /etc/ssh/ssh_host_*_key

# Validate config before enabling — catches typos that would lock you out
sshd -t && echo "sshd config OK" || echo "WARNING: sshd config test failed — check /etc/ssh/sshd_config.d/99-hardening.conf"

systemctl enable sshd

# ------------------------------------------------------------------------------
# Firewall rules for local dev
# ------------------------------------------------------------------------------
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-port=8000/tcp   # Symfony dev server
firewall-cmd --permanent --add-port=8080/tcp   # Generic dev
firewall-cmd --permanent --add-port=3306/tcp   # MariaDB (local only)
firewall-cmd --permanent --add-port=5432/tcp   # PostgreSQL (local only)
firewall-cmd --permanent --add-port=6379/tcp   # Redis (local only)
firewall-cmd --reload

# ------------------------------------------------------------------------------
# SELinux Configuration
# Covers: PHP/web dev, Docker, container networking, and volume mounts
# SELinux stays ENFORCING — we configure it properly rather than disable it
# ------------------------------------------------------------------------------

# -- PHP / Web booleans --
setsebool -P httpd_can_network_connect 1       # PHP-FPM can make outbound connections
setsebool -P httpd_can_network_connect_db 1    # PHP-FPM can reach MariaDB/PostgreSQL
setsebool -P httpd_execmem 1                   # Required for some PHP opcode scenarios
setsebool -P httpd_read_user_content 1         # Apache/nginx can read user home dirs
setsebool -P httpd_enable_homedirs 1           # Serve content from ~/public_html

# -- Container / Docker booleans --
setsebool -P container_manage_cgroup 1         # Containers can manage cgroups (required for Docker)
setsebool -P container_use_devices 1           # Containers can access /dev entries (GPU passthrough etc)

# -- Docker daemon: configure overlay2 storage + SELinux label enforcement --
# overlay2 is the correct modern storage driver for Fedora (not devicemapper).
# "selinux-enabled: true" tells Docker to apply SVirt MCS labels to containers
# so SELinux enforcing mode controls what containers can access on the host.
# "live-restore: true" keeps containers running if dockerd restarts (handy for dev).
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DOCKERDAEMON'
{
  "storage-driver": "overlay2",
  "selinux-enabled": true,
  "live-restore": true,
  "log-driver": "journald",
  "log-opts": {
    "tag": "{{.Name}}"
  }
}
DOCKERDAEMON

# -- SELinux file context for Docker socket and data directories --
# Ensure the Docker socket and storage dirs get the right context on relabel
semanage fcontext -a -t container_runtime_exec_t "/usr/bin/dockerd" 2>/dev/null || true
semanage fcontext -a -t container_var_lib_t      "/var/lib/docker(/.*)?" 2>/dev/null || true
semanage fcontext -a -t container_runtime_exec_t "/usr/bin/containerd" 2>/dev/null || true
restorecon -Rv /var/lib/docker 2>/dev/null || true
restorecon -v  /usr/bin/dockerd 2>/dev/null || true
restorecon -v  /usr/bin/containerd 2>/dev/null || true

# -- Volume mount label fix: add :Z or :z to bind mounts in compose files --
# Docker with SELinux enforcing requires bind-mounted host dirs to be relabeled.
# :Z = private unshared label (one container), :z = shared label (multiple containers).
# This is a per-project convention — reminder written to /etc/docker/SELINUX_VOLUMES.txt
cat > /etc/docker/SELINUX_VOLUMES.txt << 'SELINUXNOTE'
SELinux Volume Mount Guide for this system
==========================================
Docker runs with selinux-enabled: true.
Any bind-mounted host directory in docker-compose.yml or docker run -v
MUST include a relabel suffix or SELinux will deny access:

  Use :Z  for a volume used by ONE container (private label):
    volumes:
      - ./myapp:/var/www/html:Z

  Use :z  for a volume SHARED between multiple containers (shared label):
    volumes:
      - ./shared:/data:z

  Named Docker volumes (not host paths) do NOT need :Z/:z — Docker manages
  their labels automatically.

If you forget and get a Permission Denied inside a container, run:
  chcon -Rt svirt_sandbox_file_t /your/host/path
or add :Z to the volume mount and recreate the container.
SELINUXNOTE

# -- Podman SELinux (rootless containers — already works, this ensures defaults) --
setsebool -P container_use_cephfs 0 2>/dev/null || true   # disable unused network storage
# Rootless Podman uses user namespaces + SELinux automatically — no extra config needed

# -- Container networking through firewalld --
# IMPORTANT: Do NOT manually bind docker0 to a firewalld zone here.
# Modern Docker (27+) creates and manages its own "docker" firewalld zone and
# binds the docker0 bridge to it automatically on first daemon start. Manually
# pre-assigning docker0 to the "trusted" zone (older, widely-copied advice)
# causes the daemon to abort on startup with:
#   ZONE_CONFLICT: 'docker0' already bound to 'trusted'
# Let Docker own its zone — no firewall-cmd lines needed for the bridge.
setsebool -P domain_can_mmap_files 1 2>/dev/null || true

# ------------------------------------------------------------------------------
# ZRAM swap (replaces disk swap partition)
# zram-generator creates a compressed in-memory swap device at boot.
# Size = RAM/2 with zstd compression — 3-5x faster than NVMe swap.
# swappiness=180 tells the kernel to strongly prefer ZRAM over any disk.
# vm.page-cluster=0 disables read-ahead on swap pages — correct for ZRAM
# since there's no seek cost and batching just wastes CPU.
# ------------------------------------------------------------------------------
echo "[20/41] Configuring ZRAM swap..."
mkdir -p /etc/systemd/zram-generator.conf.d
cat > /etc/systemd/zram-generator.conf << 'ZRAMCONF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAMCONF

cat > /etc/sysctl.d/99-zram-tuning.conf << 'ZRAMSYSCTL'
# Strongly prefer ZRAM over disk swap (180 = aggressive for desktop/gaming)
vm.swappiness = 180
# Disable swap read-ahead — no seek penalty on ZRAM
vm.page-cluster = 0
# Reduce vfs cache pressure slightly — keeps file metadata in RAM longer
vm.vfs_cache_pressure = 50
ZRAMSYSCTL

systemctl enable systemd-zram-setup@zram0.service 2>/dev/null || true

# ------------------------------------------------------------------------------
# fail2ban — SSH brute-force protection
# Works alongside the SSH hardening config already in place.
# Jails repeat offenders after 5 failed attempts for 1 hour.
# Uses firewalld backend (nftables) — matches how the rest of the firewall works.
# ------------------------------------------------------------------------------
echo "[21/41] Configuring fail2ban..."
systemctl enable fail2ban

mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.conf << 'FAIL2BAN'
[sshd]
enabled   = true
backend   = systemd
maxretry  = 5
bantime   = 1h
findtime  = 10m
action    = firewallcmd-rich-rules[actiontype=<multiport>]
FAIL2BAN

cat > /etc/fail2ban/jail.d/defaults-override.conf << 'F2BDEFAULTS'
[DEFAULT]
banaction = firewallcmd-rich-rules
banaction_allports = firewallcmd-allports
F2BDEFAULTS

# ------------------------------------------------------------------------------
# dnf-automatic — unattended security updates
# Applies security-only updates nightly via a systemd timer.
# Keeps the OS patched without manual intervention.
# ------------------------------------------------------------------------------
echo "[22/41] Configuring dnf-automatic security updates..."
sed -i \
  's/^upgrade_type\s*=.*/upgrade_type = security/' \
  /etc/dnf/automatic.conf
sed -i \
  's/^apply_updates\s*=.*/apply_updates = yes/' \
  /etc/dnf/automatic.conf
sed -i \
  's/^emit_via\s*=.*/emit_via = stdio/' \
  /etc/dnf/automatic.conf

systemctl enable dnf-automatic.timer

# ------------------------------------------------------------------------------
# nvm — Node version manager
# Installs nvm as devuser so per-project .nvmrc files work automatically.
# Installs LTS Node as the default. The system nodejs/npm from packages
# stays installed (some tools need it at the system level) but nvm's Node
# takes precedence in devuser's PATH via .zshrc sourcing below.
# ------------------------------------------------------------------------------
echo "[23/41] Installing nvm (Node version manager)..."
# HOME set explicitly: `sudo -u` doesn't reliably reset it, so without this nvm
# tries to install into /root/.nvm as devuser and fails with permission denied.
sudo -u devuser env HOME=/home/devuser bash -c '
    export NVM_DIR="$HOME/.nvm"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    [ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
    nvm install --lts
    nvm alias default lts/*
    nvm use default
'

# Add nvm sourcing to devuser zshrc (appended after the main ZSHRC heredoc)
cat >> /home/devuser/.zshrc << 'NVMRC'

# nvm — Node version manager
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
NVMRC

# ------------------------------------------------------------------------------
# mise — polyglot version manager (PHP, Python, Ruby, Java, Go, etc.)
# Single tool replacing phpenv, rbenv, pyenv, sdkman for version switching.
# Reads .tool-versions files in project roots automatically.
# Installed as devuser; shims activated via eval in .zshrc.
# ------------------------------------------------------------------------------
echo "[24/41] Installing mise (polyglot version manager)..."
# PHP and Ruby compile from source via mise — ensure the build toolchain and
# dev headers are present first (these failed during the chroot %post run).
# The PHP set is the killer: PHP's default build enables curl, gd, pdo_pgsql,
# zip, intl, sodium, etc., and a single missing -devel aborts ./configure. The
# asdf-php plugin's own docs require libcurl/gd/libpq/libzip; we add the usual
# extension deps (icu, sodium, bzip2, xslt, gmp + gd's image libs) so a full
# Symfony/Drupal-capable PHP compiles in one shot.
dnf install -y \
    @c-development @development-tools gcc gcc-c++ make \
    autoconf automake bison re2c libtool pkgconf-pkg-config \
    libffi-devel openssl-devel libyaml-devel readline-devel \
    zlib-ng-devel gdbm-devel ncurses-devel libxml2-devel \
    sqlite-devel oniguruma-devel \
    libcurl-devel gd-devel libpq-devel libzip-devel \
    libsodium-devel libicu-devel bzip2-devel libxslt-devel \
    libpng-devel libjpeg-turbo-devel libwebp-devel freetype-devel \
    gmp-devel --skip-unavailable || true
# HOME set explicitly (same sudo -u pitfall as the nvm block); idempotent mise
# bootstrap so a re-run doesn't reinstall mise itself.
sudo -u devuser env HOME=/home/devuser bash -c '
    export PATH="$HOME/.local/bin:$PATH"
    command -v mise >/dev/null 2>&1 || curl https://mise.run | sh
    mise install php@8.3
    mise install python@3.12
    mise install ruby@3.3
    mise global php@8.3 python@3.12 ruby@3.3
'

cat >> /home/devuser/.zshrc << 'MISERC'

# mise — polyglot version manager (PHP, Python, Ruby, Java, Go, etc.)
export PATH="$HOME/.local/bin:$PATH"
eval "$(mise activate zsh)"
MISERC

# ------------------------------------------------------------------------------
# Xdebug configuration for PHPStorm
# php-xdebug is already installed but completely unconfigured.
# This creates a dev-appropriate ini drop-in that PHPStorm connects to
# on port 9003 with the PHPSTORM idekey. xdebug.start_with_request=yes
# means every CLI and web request is debuggable without browser extensions.
# Change to trigger_value for production-like selective debugging.
# ------------------------------------------------------------------------------
echo "[25/41] Configuring Xdebug for PHPStorm..."
cat > /etc/php.d/99-xdebug-dev.ini << 'XDEBUGINI'
; Xdebug dev configuration — generated by Fedora Kickstart
; PHPStorm: Run > Edit Configurations > PHP Remote Debug, idekey = PHPSTORM
; Port must match xdebug.client_port below (9003 is Xdebug 3.x default)

zend_extension = xdebug.so

xdebug.mode               = debug,develop
xdebug.client_host        = 127.0.0.1
xdebug.client_port        = 9003
xdebug.start_with_request = yes
xdebug.idekey             = PHPSTORM
xdebug.log_level          = 0
xdebug.max_nesting_level  = 512

; develop mode extras (var_dump formatting, error overlays)
xdebug.var_display_max_depth   = 6
xdebug.var_display_max_data    = 1024
xdebug.var_display_max_children = 256
XDEBUGINI

# Raise PHP limits for dev — long requests, big uploads, verbose errors
cat > /etc/php.d/99-dev-limits.ini << 'PHPDEV'
; Dev PHP limits — generated by Fedora Kickstart
memory_limit          = 512M
max_execution_time    = 300
max_input_time        = 300
post_max_size         = 128M
upload_max_filesize   = 128M
display_errors        = On
display_startup_errors = On
error_reporting       = E_ALL
log_errors            = On
PHPDEV

# PHP-FPM dev pool — ondemand workers, relaxed timeouts
sed -i 's/^pm = .*/pm = ondemand/'              /etc/php-fpm.d/www.conf
sed -i 's/^pm.max_children = .*/pm.max_children = 20/' /etc/php-fpm.d/www.conf
sed -i 's/^;request_terminate_timeout.*/request_terminate_timeout = 300/' /etc/php-fpm.d/www.conf

# ------------------------------------------------------------------------------
# mkcert — local SSL certificates
# Creates a local CA trusted by the system and all browsers.
# Generates a wildcard cert for *.localhost so any .localhost dev domain
# gets HTTPS without warnings. PHPStorm and the Symfony CLI both pick up
# the mkcert CA automatically.
# ------------------------------------------------------------------------------
echo "[26/41] Installing mkcert and generating local SSL certificates..."
MKCERT_VERSION=$(curl -s https://api.github.com/repos/FiloSottile/mkcert/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
curl -L "https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-${MKCERT_VERSION}-linux-amd64" \
    -o /usr/local/bin/mkcert
chmod +x /usr/local/bin/mkcert

# Install the local CA into system trust store
# Use the distro 'jre' symlink so this doesn't hardcode a JDK version
# (mkcert only needs JAVA_HOME to also install the CA into the Java trust store;
#  if Java isn't present it still installs the system CA fine).
JAVA_HOME=/usr/lib/jvm/jre CAROOT=/etc/pki/mkcert mkcert -install 2>/dev/null || \
    CAROOT=/etc/pki/mkcert mkcert -install

# Generate wildcard cert for localhost dev domains
mkdir -p /etc/pki/tls/mkcert
cd /etc/pki/tls/mkcert
CAROOT=/etc/pki/mkcert mkcert \
    "localhost" "*.localhost" \
    "127.0.0.1" "::1"

# Symlink for easy reference
ln -sf /etc/pki/tls/mkcert/localhost+3.pem    /etc/pki/tls/mkcert/dev.crt
ln -sf /etc/pki/tls/mkcert/localhost+3-key.pem /etc/pki/tls/mkcert/dev.key
cd /

# ------------------------------------------------------------------------------
# kind — local Kubernetes cluster via Docker
# Gives kubectl, Helm, k9s, kubectx something to talk to immediately.
# Creates a single-node default cluster. kind uses Docker containers
# as "nodes" so no VM overhead — starts in under 30 seconds.
# ------------------------------------------------------------------------------
echo "[27/41] Installing kind and creating default local k8s cluster..."
KIND_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
curl -L "https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-amd64" \
    -o /usr/local/bin/kind
chmod +x /usr/local/bin/kind

# Write kind alias and completion to zshrc
cat >> /home/devuser/.zshrc << 'KINDRC'

# kind — local Kubernetes
alias kc='kind create cluster'
alias kd='kind delete cluster'
alias kg='kind get clusters'
KINDRC

# Note: kind cluster creation requires Docker to be running (done post-reboot)
# A startup script is dropped here to create the default cluster on first login
cat > /usr/local/bin/kind-init << 'KINDINIT'
#!/usr/bin/env bash
if ! kind get clusters 2>/dev/null | grep -q "^kind$"; then
    echo "Creating default kind cluster..."
    kind create cluster --name kind
    echo "Default kind cluster created. kubectl context set automatically."
fi
KINDINIT
chmod +x /usr/local/bin/kind-init

# Drop a systemd user service that runs kind-init once after first login
mkdir -p /home/devuser/.config/systemd/user
cat > /home/devuser/.config/systemd/user/kind-init.service << 'KINDSVC'
[Unit]
Description=Initialize default kind Kubernetes cluster
After=docker.service
ConditionPathExists=!/home/devuser/.kube/config

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kind-init
RemainAfterExit=yes

[Install]
WantedBy=default.target
KINDSVC
chown -R devuser:devuser /home/devuser/.config

# ------------------------------------------------------------------------------
# docker-compose compatibility alias + symlink
# docker-compose-plugin installs 'docker compose' (space, plugin syntax).
# Many Drupal/Symfony stacks and legacy scripts use 'docker-compose' (hyphen).
# The symlink covers scripts; the alias covers interactive terminal use.
# ------------------------------------------------------------------------------
echo "[28/41] Adding docker-compose compatibility shim..."
cat > /usr/local/bin/docker-compose << 'DCSHIM'
#!/usr/bin/env bash
exec docker compose "$@"
DCSHIM
chmod +x /usr/local/bin/docker-compose

cat >> /home/devuser/.zshrc << 'DCALIAS'

# docker-compose compatibility (maps hyphen form to plugin form)
alias docker-compose='docker compose'
DCALIAS

# ------------------------------------------------------------------------------
# ctop — container resource monitor (like htop for Docker containers)
# Already in %packages if available in repos; this ensures the binary
# is present from GitHub release if the dnf package isn't found.
# ------------------------------------------------------------------------------
echo "[29/41] Installing ctop..."
if ! command -v ctop &>/dev/null; then
    CTOP_VERSION=$(curl -s https://api.github.com/repos/bcicen/ctop/releases/latest \
        | grep '"tag_name"' | cut -d'"' -f4)
    curl -L "https://github.com/bcicen/ctop/releases/latest/download/ctop-${CTOP_VERSION}-linux-amd64" \
        -o /usr/local/bin/ctop
    chmod +x /usr/local/bin/ctop
fi

cat >> /home/devuser/.zshrc << 'CTOPRC'

# ctop — container resource monitor
alias ct='ctop'
CTOPRC

# ------------------------------------------------------------------------------
# dive — Docker image layer inspector
# Lets you walk each layer of an image and see exactly what was added,
# which is invaluable for debugging bloated images or tracing file origins.
# ------------------------------------------------------------------------------
echo "[30/41] Installing dive..."
DIVE_VERSION=$(curl -s https://api.github.com/repos/wagoodman/dive/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
curl -L "https://github.com/wagoodman/dive/releases/latest/download/dive_${DIVE_VERSION#v}_linux_amd64.tar.gz" \
    -o /tmp/dive.tar.gz
tar -xzf /tmp/dive.tar.gz -C /usr/local/bin dive
chmod +x /usr/local/bin/dive
rm -f /tmp/dive.tar.gz

# ------------------------------------------------------------------------------
# PipeWire tuning for gaming
# Default PipeWire quantum causes audio crackling and latency spikes in games.
# 512 quantum at 48kHz is the sweet spot — low enough for responsive audio,
# high enough to avoid xruns under GPU load.
# min-quantum=32 allows PipeWire to drop lower for pro-audio apps if needed.
# ------------------------------------------------------------------------------
echo "[31/41] Tuning PipeWire for gaming..."
mkdir -p /etc/pipewire/pipewire.conf.d
cat > /etc/pipewire/pipewire.conf.d/99-gaming.conf << 'PWCONF'
context.properties = {
    default.clock.rate          = 48000
    default.clock.quantum       = 512
    default.clock.min-quantum   = 32
    default.clock.max-quantum   = 2048
}
PWCONF

# Ensure pipewire-pulse is the PulseAudio replacement (not coexisting)
systemctl --global disable pulseaudio.service pulseaudio.socket 2>/dev/null || true
systemctl --global enable  pipewire.service pipewire-pulse.service wireplumber.service 2>/dev/null || true

# ------------------------------------------------------------------------------
# GameMode daemon autostart
# gamemode is installed but gamemoded must be running as a user service
# for games to actually get the CPU governor + scheduler tweaks.
# Enabled at the system level via PAM/D-Bus; user service as belt-and-suspenders.
# ------------------------------------------------------------------------------
echo "[32/41] Enabling GameMode daemon..."
# System-level: allow devuser to use GameMode via polkit
cat > /etc/polkit-1/rules.d/99-gamemode.rules << 'POLKIT'
polkit.addRule(function(action, subject) {
    if (action.id == "com.feralinteractive.GameMode.governor" &&
        subject.isInGroup("gamemode")) {
        return polkit.Result.YES;
    }
});
POLKIT

usermod -aG gamemode devuser 2>/dev/null || groupadd gamemode && usermod -aG gamemode devuser

# Global GameMode config — CPU governor, renice, ioprio, GPU tweaks
cat > /etc/gamemode.ini << 'GAMEMODEINI'
[general]
renice = 10
ioprio = 0

[filter]
whitelist =
blacklist =

[gpu]
apply_gpu_optimisations = accept-responsibility
gpu_device = 0
amd_performance_level = high

[cpu]
park_cores = no
pin_cores = yes
GAMEMODEINI

# User-level systemd service as fallback
mkdir -p /home/devuser/.config/systemd/user
cat > /home/devuser/.config/systemd/user/gamemoded.service << 'GAMESVCC'
[Unit]
Description=GameMode daemon
After=dbus.service

[Service]
Type=simple
ExecStart=/usr/bin/gamemoded -d
Restart=on-failure

[Install]
WantedBy=default.target
GAMESVCC
chown devuser:devuser /home/devuser/.config/systemd/user/gamemoded.service

# ------------------------------------------------------------------------------
# AMD/Nvidia GPU performance environment flags
# RADV ACO compiler + async compute improve Vulkan gaming performance on AMD.
# Nvidia PRIME offload flags redirect rendering to the dGPU on hybrid laptops.
# These are written to /etc/environment so they apply system-wide to all games
# regardless of launcher — Steam, Heroic, Lutris, or terminal.
# Uncomment the block matching your GPU.
# ------------------------------------------------------------------------------
echo "[33/41] Writing GPU performance environment flags..."
cat >> /etc/environment << 'GPUENV'

# -- Nvidia PRIME offload (Asus ProArt 16 — hybrid AMD iGPU + RTX 4060) --
# These activate PRIME render offload so apps can use the RTX 4060 on demand.
# The prime-run script (at /usr/local/bin/prime-run) wraps these automatically.
# For Steam games: add "prime-run %command%" to launch options in Steam.
# For always-on Nvidia: switch to NvidiaNoModeset mode via supergfxctl.
__NV_PRIME_RENDER_OFFLOAD=1
__NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
__GLX_VENDOR_LIBRARY_NAME=nvidia
__VK_LAYER_NV_optimus=NVIDIA_only

# -- AMD iGPU (Radeon) — display + desktop rendering --
# Mesa ACO compiler — better shader compilation for AMD
RADV_PERFTEST=aco,gpl
mesa_glthread=true

# -- Common Proton/Wine performance flags --
PROTON_NO_ESYNC=0
PROTON_NO_FSYNC=0
DXVK_ASYNC=1
GPUENV

# ------------------------------------------------------------------------------
# Lutris — catch-all game launcher
# Covers everything Steam/Heroic/Heroic don't: Battlenet, EA App,
# Ubisoft Connect, older Windows games, emulators, and custom Wine prefixes.
# Also manages its own DXVK/VKD3D versions independently of Proton.
# ------------------------------------------------------------------------------
echo "[34/41] Installing Lutris..."
dnf install -y lutris

# ------------------------------------------------------------------------------
# fwupd — firmware updates
# Delivers NVMe, USB-C, Thunderbolt, and other firmware updates via LVFS.
# Enabled as a service; actual updates are applied manually post-boot.
# ------------------------------------------------------------------------------
echo "[35/41] Enabling fwupd firmware update service..."
systemctl enable fwupd
fwupdmgr refresh --force 2>/dev/null || true

# ------------------------------------------------------------------------------
# thermald — thermal management
# Prevents sustained CPU/GPU thermal throttling during gaming sessions
# and long compile runs. Works alongside the kernel's own thermal governor.
# power-profiles-daemon is included for laptop power mode switching.
# ------------------------------------------------------------------------------
echo "[36/41] Enabling thermald..."
systemctl enable thermald
systemctl enable power-profiles-daemon 2>/dev/null || true

# ------------------------------------------------------------------------------
# KVM/libvirt — virtualisation for VM testing of kickstart changes
# Enables the libvirtd daemon so virt-install and test-vm.sh work without
# requiring a separate setup step after install.
# ------------------------------------------------------------------------------
if rpm -q qemu-kvm libvirt virt-install >/dev/null 2>&1; then
    echo "[36b] Enabling libvirtd (KVM/QEMU)..."
    systemctl enable libvirtd
    usermod -aG libvirt devuser
else
    echo "[36b] KVM packages not installed — skipping libvirtd enable"
    echo "      Install with: dnf install -y qemu-kvm libvirt virt-install"
fi

# ------------------------------------------------------------------------------
# XDG base directory enforcement
# Without explicit XDG vars, tools scatter config across ~ as dotfiles.
# This centralizes everything under ~/.config, ~/.local, ~/.cache.
# Each major tool is pointed at its XDG-correct location.
# ------------------------------------------------------------------------------
echo "[37/41] Configuring XDG base directories..."
cat >> /home/devuser/.zshrc << 'XDGRC'

# XDG base directories
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"

# Tool-specific XDG overrides
export COMPOSER_HOME="$XDG_CONFIG_HOME/composer"
export NPM_CONFIG_USERCONFIG="$XDG_CONFIG_HOME/npm/npmrc"
export NODE_REPL_HISTORY="$XDG_STATE_HOME/node_repl_history"
export PYTHON_HISTORY="$XDG_STATE_HOME/python_history"
export GOPATH="$XDG_DATA_HOME/go"
export CARGO_HOME="$XDG_DATA_HOME/cargo"
export RUSTUP_HOME="$XDG_DATA_HOME/rustup"
export DOCKER_CONFIG="$XDG_CONFIG_HOME/docker"
export ANSIBLE_HOME="$XDG_CONFIG_HOME/ansible"
export ANSIBLE_CONFIG="$XDG_CONFIG_HOME/ansible/ansible.cfg"
export KUBECONFIG="$XDG_CONFIG_HOME/kube/config"
export LESSHISTFILE="$XDG_STATE_HOME/less/history"
export HISTFILE="$XDG_STATE_HOME/zsh/history"
XDGRC

mkdir -p /home/devuser/.config/npm
cat > /home/devuser/.config/npm/npmrc << 'NPMRC'
cache=${XDG_CACHE_HOME}/npm
prefix=${HOME}/.local
NPMRC

mkdir -p /home/devuser/.config/ansible
cat > /home/devuser/.config/ansible/ansible.cfg << 'ANSIBLECFG'
[defaults]
inventory = ~/.config/ansible/hosts
roles_path = ~/.local/share/ansible/roles
collections_paths = ~/.local/share/ansible/collections
retry_files_enabled = False
stdout_callback = yaml
ANSIBLECFG

chown -R devuser:devuser /home/devuser/.config /home/devuser/.local 2>/dev/null || true

# ------------------------------------------------------------------------------
# starship — cross-shell prompt (replaces agnoster)
# Works with any font — no Powerline patches required.
# Shows git branch+status, PHP version, Docker context, kubectl context,
# Python venv, Node version, and exit codes automatically.
# Faster than oh-my-zsh themes, written in Rust.
# ------------------------------------------------------------------------------
echo "[38/41] Installing starship prompt..."
curl -sS https://starship.rs/install.sh | sh -s -- --yes

mkdir -p /home/devuser/.config
cat > /home/devuser/.config/starship.toml << 'STARSHIP'
format = """
$username$hostname$directory$git_branch$git_status\
$php$nodejs$python$ruby$java$golang$rust\
$docker_context$kubernetes\
$cmd_duration$line_break$character"""

[character]
success_symbol = "[❯](green)"
error_symbol   = "[❯](red)"

[git_branch]
symbol = " "

[php]
symbol = " "
format = "[$symbol$version]($style) "

[nodejs]
symbol = " "
format = "[$symbol$version]($style) "

[python]
symbol = " "
format = "[$symbol$version]($style) "

[docker_context]
symbol = " "
format = "[$symbol$context]($style) "

[kubernetes]
disabled = false
symbol = "⎈ "
format = "[$symbol$context( \\($namespace\\))]($style) "

[cmd_duration]
min_time = 2_000
format   = "took [$duration]($style) "
STARSHIP

chown devuser:devuser /home/devuser/.config/starship.toml

# Replace agnoster with starship in .zshrc
sed -i 's/ZSH_THEME="agnoster"/ZSH_THEME=""/' /home/devuser/.zshrc
cat >> /home/devuser/.zshrc << 'STARSHIPRC'

# starship prompt (replaces oh-my-zsh theme)
eval "$(starship init zsh)"
STARSHIPRC

# ------------------------------------------------------------------------------
# Tailscale — mesh VPN
# One-command install from the Tailscale repo.
# tailscaled runs as a system service; 'tailscale up' is interactive
# (requires browser login to Tailscale account) so documented in reminders.
# ------------------------------------------------------------------------------
echo "[39/41] Enabling Tailscale..."
systemctl enable tailscaled
# tailscale up is interactive — see post-install reminder

# ------------------------------------------------------------------------------
# dnsmasq — local DNS for *.localhost and *.test domains
# Resolves *.localhost and *.test to 127.0.0.1 automatically so you never
# need to edit /etc/hosts for local dev domains again.
# NetworkManager is configured to use dnsmasq as its DNS backend.
# ------------------------------------------------------------------------------
echo "[40/41] Configuring dnsmasq for local dev DNS..."
cat > /etc/dnsmasq.d/local-dev.conf << 'DNSMASQ'
# Resolve *.localhost and *.test to loopback for local dev
address=/.localhost/127.0.0.1
address=/.test/127.0.0.1
address=/.localhost/::1
address=/.test/::1

# Don't read /etc/resolv.conf — let NetworkManager handle upstream DNS
no-resolv

# Use systemd-resolved as upstream
server=127.0.0.53
DNSMASQ

cat > /etc/NetworkManager/conf.d/dnsmasq.conf << 'NMDNS'
[main]
dns=dnsmasq
NMDNS

systemctl enable dnsmasq

# ------------------------------------------------------------------------------
# Bun + Deno runtimes
# Increasingly common in modern Drupal/Symfony frontend tooling.
# Bun is fastest for bundling; Deno for TypeScript-native scripting.
# Both are single-binary installs that don't conflict with Node/nvm.
# ------------------------------------------------------------------------------
echo "[41/41] Installing Bun and Deno runtimes..."
# HOME set explicitly (same sudo -u pitfall): without it Bun installs to
# /root/.bun and fails. BUN_INSTALL pins the target for the installer.
sudo -u devuser env HOME=/home/devuser bash -c '
    export BUN_INSTALL="$HOME/.bun"
    curl -fsSL https://bun.sh/install | bash
'
cat >> /home/devuser/.zshrc << 'BUNRC'

# Bun runtime
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
BUNRC

# Deno
curl -fsSL https://deno.land/install.sh | sh -s -- --no-modify-path
install -m 0755 /root/.deno/bin/deno /usr/local/bin/deno 2>/dev/null || \
    install -m 0755 /home/devuser/.deno/bin/deno /usr/local/bin/deno 2>/dev/null || true

# ==============================================================================
# [42/42+] Ollama + RAG stack
# ==============================================================================
# Architecture:
#   LOCAL mode  : Ollama daemon uses the RTX 4060 (CUDA, Hybrid GPU mode).
#                 Open WebUI container talks to host Ollama for RAG + chat.
#   REMOTE mode : Local Ollama daemon stopped; all clients point at the desktop
#                 over Tailscale. Open WebUI repointed to desktop endpoint.
#                 GPU switches to Integrated (max battery) — needs logout.
#
# Model: qwen2.5-coder:7b-instruct-q5_K_M
#   - 8B param Qwen2.5 instruction-tuned, 4-bit K-quant (~5 GB VRAM).
#   - Fits comfortably in the RTX 4060 8 GB with headroom for context.
#   - Strong on code, Symfony/PHP, Drupal, general dev Q&A.
#   - Also pulled on the desktop (via the separate desktop-setup step there).
#
# Switching between local and remote is handled by ollama-backend.sh (see
# /usr/local/bin/ollama-backend for the installed copy). The GPU-mode scripts
# (ollama-local.sh / ollama-remote.sh) handle the deeper Hybrid↔Integrated
# switch that requires a logout — use those when you want to fully power-cycle
# the dGPU, not just flip the inference endpoint.
# ==============================================================================

echo "=============================================="
echo "[42] Installing Ollama..."
echo "=============================================="

# Install Ollama system-wide (official installer; drops systemd unit + binary).
# Idempotent: re-running the installer is safe and updates if already present.
if command -v ollama >/dev/null 2>&1; then
    echo "  Ollama already installed ($(ollama --version 2>/dev/null)), skipping."
else
    curl -fsSL https://ollama.com/install.sh | sh
fi

# --- systemd drop-in: pin to CUDA dGPU, set conservative memory limits ---
# CUDA_VISIBLE_DEVICES=0   → Ollama talks to the RTX 4060, not CPU/iGPU
# OLLAMA_HOST=0.0.0.0      → listen on all interfaces so Docker containers
#                            (rag-stack Open WebUI) can reach the host daemon
#                            via host.docker.internal. External access is still
#                            blocked by firewalld (only docker zone allows 11434).
# OLLAMA_KEEP_ALIVE=5m     → release VRAM after 5 min idle (laptop battery)
# OLLAMA_MAX_LOADED_MODELS=1 → don't hold multiple models in VRAM simultaneously
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf << 'OLLAMACFG'
[Service]
Environment="LD_LIBRARY_PATH=/usr/local/lib/ollama/cuda_v12:/usr/lib64"
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="OLLAMA_GPU_OVERHEAD=268435456"
Environment="OLLAMA_KV_CACHE_TYPE=q4_0"
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_KEEP_ALIVE=5m"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
OLLAMACFG

systemctl daemon-reload
systemctl enable --now ollama 2>/dev/null || true

# Allow Docker containers to reach host Ollama on port 11434.
# Without this, firewalld blocks the docker bridge (172.17.0.0/16) from
# connecting to the host even though Ollama listens on 0.0.0.0.
firewall-cmd --permanent --zone=docker --add-port=11434/tcp
firewall-cmd --reload

echo "  Waiting for Ollama daemon to be ready..."
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
        echo "  Ollama daemon ready (attempt $i)."
        break
    fi
    sleep 2
done

# --- Pull qwen2.5-coder:7b-instruct-q5_K_M ---
# This is ~5 GB; on a slow connection or during %post with no network it will
# fail gracefully — re-run `ollama pull qwen2.5-coder:7b-instruct-q5_K_M` manually.
echo "  Pulling qwen2.5-coder:7b-instruct-q5_K_M (~5 GB, may take a while)..."
if ollama list 2>/dev/null | grep -q 'qwen2.5-coder:7b-instruct-q5_K_M'; then
    echo "  Model already present, skipping pull."
else
    ollama pull qwen2.5-coder:7b-instruct-q5_K_M || \
        echo "  WARNING: model pull failed — run 'ollama pull qwen2.5-coder:7b-instruct-q5_K_M' manually after install."
fi

echo "=============================================="
echo "[43] Installing Open WebUI (RAG frontend)..."
echo "=============================================="
# Open WebUI provides the chat UI, document upload, embedding, and RAG
# retrieval on top of Ollama. Runs as a Docker container with a named volume
# so the RAG store + settings survive container restarts and image updates.
#
# Port 3000 → Open WebUI (internal port 8080).
# OLLAMA_BASE_URL starts pointing at localhost (local mode); ollama-backend.sh
# repoints it to the desktop when switching to remote mode.
#
# IMPORTANT: the container uses host.docker.internal to reach host Ollama in
# local mode. This resolves to the host gateway via --add-host below.

WEBUI_CONTAINER="open-webui"
WEBUI_PORT="3000"

if docker inspect "$WEBUI_CONTAINER" >/dev/null 2>&1; then
    echo "  Open WebUI container already exists, skipping creation."
    echo "  To update: docker rm -f open-webui && re-run this section."
else
    docker pull ghcr.io/open-webui/open-webui:main
    docker run -d \
        -p "${WEBUI_PORT}:8080" \
        --add-host=host.docker.internal:host-gateway \
        -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
        -v open-webui:/app/backend/data \
        --name "$WEBUI_CONTAINER" \
        --restart unless-stopped \
        ghcr.io/open-webui/open-webui:main
    echo "  Open WebUI started on http://localhost:${WEBUI_PORT}"
fi

echo "=============================================="
echo "[44] Installing Ollama backend-toggle scripts..."
echo "=============================================="
# Three scripts installed system-wide:
#   ollama-backend  — instant endpoint toggle (local/remote/toggle/status)
#                     no GPU switch, no logout, safe to bind to a hotkey.
#   ollama-local    — full switch: Hybrid GPU + local CUDA daemon
#   ollama-remote   — full switch: Integrated GPU (dGPU off) + desktop endpoint
#                     (both require logout to complete the GPU driver reload)
# Config lives in /etc/ollama-backend.conf — edit DESKTOP_HOST/IP there.

# --- Install ollama-backend.sh ---
cat > /usr/local/bin/ollama-backend << 'OLLAMABACKEND'
#!/usr/bin/env bash
# ==============================================================================
# ollama-backend — INSTANT toggle of which Ollama endpoint clients use.
# NO GPU mode change, NO driver reload, NO logout, NO sudo needed.
# Safe to bind to a PHPStorm External Tool / keyboard shortcut.
#
#   local   : clients -> this laptop's Ollama (RTX 4060 in Hybrid mode)
#   remote  : clients -> desktop Ollama over Tailscale
#   toggle  : flip to whichever you're not on (ideal for a single hotkey)
#   status  : print active backend + reachability
# ==============================================================================
set -uo pipefail

# Load site config (edit DESKTOP_HOST and DESKTOP_IP here)
CONF="/etc/ollama-backend.conf"
DESKTOP_HOST="desktop"
DESKTOP_IP=""
DESKTOP_PORT="11434"
WEBUI_CONTAINER="open-webui"
WEBUI_PORT="3000"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
KB_REPO_DIR=""
[ -f "$CONF" ] && . "$CONF"

DESKTOP_URL="http://${DESKTOP_HOST}:${DESKTOP_PORT}"
LOCAL_URL="http://127.0.0.1:11434"
ENDPOINT_FILE="$HOME/.config/ollama-endpoint.sh"
STATE_FILE="$HOME/.config/ollama-backend.state"
mkdir -p "$HOME/.config"

if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; X=$'\e[0m'
else G=""; R=""; Y=""; B=""; X=""; fi
info() { printf "${B}>>>${X} %s\n" "$*"; }
ok()   { printf "  ${G}[ok]${X} %s\n" "$*"; }
warn() { printf "  ${Y}[warn]${X} %s\n" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
notify() { have notify-send && notify-send -a "Ollama" "$1" "${2:-}" 2>/dev/null || true; }

write_endpoint() { cat > "$ENDPOINT_FILE" <<EOF
export OLLAMA_HOST="$1"
EOF
}

reachable() { have curl && curl -fsS --max-time 5 "$1/api/tags" >/dev/null 2>&1; }

reconfigure_webui() {
    local base_url="$1"
    have docker || return 0
    docker info >/dev/null 2>&1 || { warn "Docker not running; skipping WebUI repoint."; return 0; }
    local compose_file="/opt/rag-stack/docker-compose.yml"
    local env_file="/opt/rag-stack/.env"
    if [[ -f "$compose_file" ]]; then
        # rag-stack compose-managed — update .env and recreate open-webui only
        if [[ -f "$env_file" ]]; then
            grep -q "^OLLAMA_BASE_URL=" "$env_file" \
                && sed -i "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=${base_url}|" "$env_file" \
                || echo "OLLAMA_BASE_URL=${base_url}" >> "$env_file"
        fi
        docker compose -f "$compose_file" up -d --force-recreate open-webui >/dev/null 2>&1 \
            && ok "Open WebUI -> ${base_url}  (http://localhost:${WEBUI_PORT})" \
            || warn "Open WebUI restart failed."
    else
        # Fallback: standalone container (rag-stack not installed)
        docker inspect "$WEBUI_CONTAINER" >/dev/null 2>&1 && docker rm -f "$WEBUI_CONTAINER" >/dev/null
        docker run -d -p "${WEBUI_PORT}:8080" \
            --add-host=host.docker.internal:host-gateway \
            -e OLLAMA_BASE_URL="$base_url" \
            -v open-webui:/app/backend/data \
            --name "$WEBUI_CONTAINER" --restart unless-stopped \
            "$WEBUI_IMAGE" >/dev/null \
            && ok "Open WebUI -> ${base_url}  (http://localhost:${WEBUI_PORT})" \
            || warn "Open WebUI restart failed."
    fi
}

current_state() { [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo "unknown"; }

go_local() {
    info "Backend -> LOCAL (laptop RTX 4060)"
    systemctl is-active ollama.service >/dev/null 2>&1 \
        || warn "Local ollama.service not running — start with: sudo systemctl enable --now ollama"
    write_endpoint "$LOCAL_URL"
    reconfigure_webui "http://host.docker.internal:11434"
    echo "local" > "$STATE_FILE"
    ok "CLI endpoint: ${LOCAL_URL}  (source ${ENDPOINT_FILE} for this shell)"
    notify "Ollama: LOCAL" "RTX 4060 on this laptop"
}

go_remote() {
    info "Backend -> REMOTE (${DESKTOP_URL})"
    [[ -n "$KB_REPO_DIR" && -d "$KB_REPO_DIR/.git" ]] && \
        git -C "$KB_REPO_DIR" pull --ff-only >/dev/null 2>&1 \
        && ok "Knowledge base synced." || warn "git pull failed in $KB_REPO_DIR."
    reachable "$DESKTOP_URL" && ok "Desktop reachable." || \
        warn "Desktop NOT reachable at ${DESKTOP_URL} — is it on? Tailscale up? Ollama serving?"
    write_endpoint "$DESKTOP_URL"
    # Use IP directly so the Open WebUI container doesn't need to resolve the
    # Tailscale MagicDNS hostname (Docker's internal resolver can't see it).
    local webui_url
    [[ -n "$DESKTOP_IP" ]] \
        && webui_url="http://${DESKTOP_IP}:${DESKTOP_PORT}" \
        || { warn "DESKTOP_IP not set in $CONF — WebUI may not resolve '${DESKTOP_HOST}'"; webui_url="$DESKTOP_URL"; }
    reconfigure_webui "$webui_url"
    echo "remote" > "$STATE_FILE"
    ok "CLI endpoint: ${DESKTOP_URL}  (source ${ENDPOINT_FILE} for this shell)"
    notify "Ollama: REMOTE" "Desktop over Tailscale"
}

show_status() {
    local st; st="$(current_state)"
    local url; [[ "$st" == "local" ]] && url="$LOCAL_URL" || url="$DESKTOP_URL"
    printf "${B}Ollama backend:${X} %s\n" "$st"
    printf "  endpoint : %s\n" "${url:-<none>}"
    [[ -n "${url:-}" ]] && { reachable "$url" \
        && printf "  status   : ${G}reachable${X}\n" \
        || printf "  status   : ${R}unreachable${X}\n"; }
    have docker && docker inspect "$WEBUI_CONTAINER" >/dev/null 2>&1 && \
        printf "  webui    : http://localhost:%s -> %s\n" "$WEBUI_PORT" \
            "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$WEBUI_CONTAINER" 2>/dev/null \
               | grep OLLAMA_BASE_URL | cut -d= -f2-)"
}

case "${1:-status}" in
    local)  go_local ;;
    remote) go_remote ;;
    toggle) [[ "$(current_state)" == "remote" ]] && go_local || go_remote ;;
    status) show_status ;;
    -h|--help) head -n 15 "$0" | grep '^#' | sed 's/^# \{0,1\}//' ;;
    *) echo "Usage: $(basename "$0") {local|remote|toggle|status}"; exit 1 ;;
esac
OLLAMABACKEND
chmod +x /usr/local/bin/ollama-backend

# --- Install ollama-local / ollama-remote (GPU-mode wrappers) ---
cat > /usr/local/bin/ollama-local << 'OLLAMALOCAL'
#!/usr/bin/env bash
# Switch to LOCAL: Hybrid GPU + Ollama on RTX 4060 + WebUI on localhost.
# Requires LOGOUT to complete the GPU mode switch (driver reload).
# For endpoint-only toggle with no logout needed, use: ollama-backend local
set -uo pipefail
CONF="/etc/ollama-backend.conf"
DESKTOP_HOST="desktop"; DESKTOP_IP=""; DESKTOP_PORT="11434"
WEBUI_CONTAINER="open-webui"; WEBUI_PORT="3000"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"
[ -f "$CONF" ] && . "$CONF"
if [[ -t 1 ]]; then G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; X=$'\e[0m'
else G=""; Y=""; B=""; X=""; fi
info() { printf "${B}>>>${X} %s\n" "$*"; }
ok()   { printf "  ${G}[ok]${X} %s\n" "$*"; }
warn() { printf "  ${Y}[warn]${X} %s\n" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
confirm() { [[ "${1:-}" == "--yes" ]] && return 0; local r; read -r -p "  ?  $1 [y/N] " r; [[ "$r" =~ ^[Yy]$ ]]; }

info "Mode: LOCAL (Hybrid GPU + Ollama on RTX 4060)"

# 1. Ollama systemd drop-in: pin to CUDA
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf << 'EOF'
[Service]
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_KEEP_ALIVE=5m"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
EOF
systemctl daemon-reload
sudo systemctl enable --now ollama
sudo systemctl restart ollama
ok "Local Ollama daemon started (CUDA device 0)."

# 2. Clear remote client pointer
rm -f /etc/profile.d/ollama-endpoint.sh 2>/dev/null || true

# 3. Repoint WebUI at localhost
have docker && docker info >/dev/null 2>&1 && {
    compose_file="/opt/rag-stack/docker-compose.yml"
    env_file="/opt/rag-stack/.env"
    if [[ -f "$compose_file" ]]; then
        [[ -f "$env_file" ]] && grep -q "^OLLAMA_BASE_URL=" "$env_file" \
            && sed -i "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=http://host.docker.internal:11434|" "$env_file" \
            || echo "OLLAMA_BASE_URL=http://host.docker.internal:11434" >> "$env_file"
        docker compose -f "$compose_file" up -d --force-recreate open-webui >/dev/null 2>&1
    else
        docker inspect "$WEBUI_CONTAINER" >/dev/null 2>&1 && docker rm -f "$WEBUI_CONTAINER" >/dev/null
        docker run -d -p "${WEBUI_PORT}:8080" \
            --add-host=host.docker.internal:host-gateway \
            -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
            -v open-webui:/app/backend/data \
            --name "$WEBUI_CONTAINER" --restart unless-stopped \
            "$WEBUI_IMAGE" >/dev/null
    fi
    ok "Open WebUI -> localhost:11434  (http://localhost:${WEBUI_PORT})"
}

# 4. GPU switch last (needs logout to take effect)
have supergfxctl && {
    cur="$(supergfxctl -g 2>/dev/null)"
    if [[ "$cur" == "Hybrid" ]]; then
        ok "GPU already in Hybrid mode."
    elif confirm "Switch GPU to Hybrid? (requires logout to take effect)"; then
        supergfxctl -m Hybrid && ok "GPU mode set to Hybrid — log out to apply."
    fi
} || warn "supergfxctl not found — GPU mode unchanged."
OLLAMALOCAL
chmod +x /usr/local/bin/ollama-local

cat > /usr/local/bin/ollama-remote << 'OLLAMAREMOTE'
#!/usr/bin/env bash
# Switch to REMOTE: Integrated GPU (dGPU off, max battery) + desktop Ollama
# over Tailscale. Stops local daemon first (dGPU must be idle before poweroff).
# Requires LOGOUT to complete the GPU mode switch.
# For endpoint-only toggle with no logout needed, use: ollama-backend remote
set -uo pipefail
CONF="/etc/ollama-backend.conf"
DESKTOP_HOST="desktop"; DESKTOP_IP=""; DESKTOP_PORT="11434"
WEBUI_CONTAINER="open-webui"; WEBUI_PORT="3000"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"; KB_REPO_DIR=""
[ -f "$CONF" ] && . "$CONF"
DESKTOP_URL="http://${DESKTOP_HOST}:${DESKTOP_PORT}"
if [[ -t 1 ]]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; X=$'\e[0m'
else G=""; R=""; Y=""; B=""; X=""; fi
info() { printf "${B}>>>${X} %s\n" "$*"; }
ok()   { printf "  ${G}[ok]${X} %s\n" "$*"; }
warn() { printf "  ${Y}[warn]${X} %s\n" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
confirm() { local r; read -r -p "  ?  $1 [y/N] " r; [[ "$r" =~ ^[Yy]$ ]]; }

info "Mode: REMOTE (Integrated GPU + desktop Ollama)"

# 1. Optional: sync knowledge base
[[ -n "$KB_REPO_DIR" && -d "$KB_REPO_DIR/.git" ]] && \
    git -C "$KB_REPO_DIR" pull --ff-only >/dev/null 2>&1 \
    && ok "Knowledge base synced." || true

# 2. Reachability check
have curl && curl -fsS --max-time 5 "${DESKTOP_URL}/api/tags" >/dev/null 2>&1 \
    && ok "Desktop reachable at ${DESKTOP_URL}." \
    || warn "Desktop NOT reachable — Tailscale up? Ollama serving 0.0.0.0?"

# 3. Stop local daemon BEFORE dGPU poweroff (CUDA must be idle first)
sudo systemctl disable --now ollama >/dev/null 2>&1 || true
ok "Local Ollama daemon stopped."

# 4. System-wide remote client pointer (new shells auto-pick up the desktop)
sudo tee /etc/profile.d/ollama-endpoint.sh >/dev/null <<EOF
# Set by ollama-remote — point Ollama CLI clients at the desktop.
export OLLAMA_HOST="${DESKTOP_URL}"
EOF
ok "Shell endpoint -> ${DESKTOP_URL}  (source /etc/profile.d/ollama-endpoint.sh for this shell)"

# 5. Repoint WebUI at desktop
have docker && docker info >/dev/null 2>&1 && {
    # Use IP directly so the Open WebUI container can reach the desktop without
    # needing Tailscale MagicDNS (Docker's resolver doesn't see it).
    [[ -n "$DESKTOP_IP" ]] \
        && webui_target="http://${DESKTOP_IP}:${DESKTOP_PORT}" \
        || { warn "DESKTOP_IP not set in $CONF — WebUI may not resolve '${DESKTOP_HOST}'"; webui_target="$DESKTOP_URL"; }
    compose_file="/opt/rag-stack/docker-compose.yml"
    env_file="/opt/rag-stack/.env"
    if [[ -f "$compose_file" ]]; then
        [[ -f "$env_file" ]] && grep -q "^OLLAMA_BASE_URL=" "$env_file" \
            && sed -i "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=${webui_target}|" "$env_file" \
            || echo "OLLAMA_BASE_URL=${webui_target}" >> "$env_file"
        docker compose -f "$compose_file" up -d --force-recreate open-webui >/dev/null 2>&1
    else
        docker inspect "$WEBUI_CONTAINER" >/dev/null 2>&1 && docker rm -f "$WEBUI_CONTAINER" >/dev/null
        docker run -d -p "${WEBUI_PORT}:8080" \
            -e OLLAMA_BASE_URL="$webui_target" \
            -v open-webui:/app/backend/data \
            --name "$WEBUI_CONTAINER" --restart unless-stopped \
            "$WEBUI_IMAGE" >/dev/null
    fi
    ok "Open WebUI -> ${webui_target}  (http://localhost:${WEBUI_PORT})"
}

# 6. GPU switch last
have supergfxctl && {
    cur="$(supergfxctl -g 2>/dev/null)"
    if [[ "$cur" == "Integrated" ]]; then
        ok "GPU already in Integrated mode."
    elif confirm "Switch GPU to Integrated? (dGPU will power off — requires logout)"; then
        supergfxctl -m Integrated && ok "GPU mode set to Integrated — log out to apply."
    fi
} || warn "supergfxctl not found — GPU mode unchanged."
OLLAMAREMOTE
chmod +x /usr/local/bin/ollama-remote

# --- Site config file (user edits DESKTOP_HOST + DESKTOP_IP here) ---
if [ ! -f /etc/ollama-backend.conf ]; then
    cat > /etc/ollama-backend.conf << 'OLLAMACONF'
# /etc/ollama-backend.conf — shared config for ollama-backend, ollama-local,
# and ollama-remote. Sourced by all three scripts.
# Edit DESKTOP_HOST and DESKTOP_IP to match your desktop's Tailscale details.

# Desktop Tailscale MagicDNS name (from `tailscale status`)
DESKTOP_HOST="desktop"

# Desktop Tailscale IP (from `tailscale ip -4` on the desktop).
# Needed so the Open WebUI Docker container can resolve the desktop hostname
# (Docker's resolver doesn't know Tailscale MagicDNS).
DESKTOP_IP=""

# Ollama port on the desktop (default: 11434)
DESKTOP_PORT="11434"

# Open WebUI container name and host port
WEBUI_CONTAINER="open-webui"
WEBUI_PORT="3000"
WEBUI_IMAGE="ghcr.io/open-webui/open-webui:main"

# Optional: path to a local git repo that holds your RAG knowledge base docs.
# When switching to remote mode, this repo is `git pull`ed so your laptop's
# docs stay in sync with the desktop's indexed content before you query.
KB_REPO_DIR=""

# Example knowledge base (uncomment and set your path):
# KB_REPO_DIR="/home/devuser/knowledge-base"
OLLAMACONF
    echo "  Created /etc/ollama-backend.conf — edit DESKTOP_HOST + DESKTOP_IP."
else
    echo "  /etc/ollama-backend.conf already exists, not overwriting."
fi

# --- Shell aliases for devuser ---
cat >> /home/devuser/.zshrc << 'OLLAMAZSHRC'

# ── Ollama / RAG backend toggle ──────────────────────────────────────────────
# ollama-backend: instant endpoint flip (no logout needed)
#   ollama-backend local   → laptop RTX 4060
#   ollama-backend remote  → desktop over Tailscale
#   ollama-backend toggle  → flip to whichever you're not on
#   ollama-backend status  → show active endpoint + reachability
alias ob='ollama-backend'
alias ob-local='ollama-backend local'
alias ob-remote='ollama-backend remote'
alias ob-toggle='ollama-backend toggle'
alias ob-status='ollama-backend status'

# Source the active Ollama endpoint for THIS shell (needed after a toggle
# until you open a new terminal, since the toggle writes to a sourced file).
alias ob-source='source ~/.config/ollama-endpoint.sh 2>/dev/null && echo "Endpoint: $OLLAMA_HOST"'

# GPU-mode scripts (require logout to complete):
#   ollama-local  → Hybrid GPU + local CUDA daemon
#   ollama-remote → Integrated GPU (dGPU off) + desktop
alias gpu-local='sudo ollama-local'
alias gpu-remote='sudo ollama-remote'

# Quick model shortcuts
alias qwen='ollama run qwen2.5-coder:7b-instruct-q5_K_M'
alias qwen-list='ollama list'
alias qwen-ps='ollama ps'

# Auto-source saved endpoint on new shells
[ -f "$HOME/.config/ollama-endpoint.sh" ] && source "$HOME/.config/ollama-endpoint.sh"
OLLAMAZSHRC

# --- Pull the model now that the daemon is confirmed running ---
# (Already attempted above; this is a second chance if the first was too early.)
echo "  Verifying model is available..."
if ollama list 2>/dev/null | grep -q 'qwen2.5-coder:7b-instruct-q5_K_M'; then
    echo "  qwen2.5-coder:7b-instruct-q5_K_M: already present."
else
    echo "  Model not yet present — will need manual pull after install:"
    echo "    ollama pull qwen2.5-coder:7b-instruct-q5_K_M"
fi

# --- Print post-setup instructions ---
echo "=============================================="
echo " Ollama + RAG stack installed."
echo "=============================================="
echo " Config: edit /etc/ollama-backend.conf"
echo "   Set DESKTOP_HOST to your desktop Tailscale name"
echo "   Set DESKTOP_IP to your desktop Tailscale IP"
echo "   (run 'tailscale ip -4' on the desktop to get it)"
echo ""
echo " Usage:"
echo "   ob status         check active backend + reachability"
echo "   ob local          switch to laptop RTX 4060"
echo "   ob remote         switch to desktop over Tailscale"
echo "   ob toggle         flip between local and remote"
echo "   qwen              open a local Qwen2.5 8B chat"
echo ""
echo "   Open WebUI:       http://localhost:3000"
echo ""
echo " For full GPU switch (Hybrid<->Integrated, needs logout):"
echo "   sudo ollama-local    (Hybrid GPU + local inference)"
echo "   sudo ollama-remote   (Integrated GPU + desktop inference)"
echo "=============================================="


# ------------------------------------------------------------------------------
dnf autoremove -y
dnf clean all

echo "=============================================="
echo " Post-Install Complete! (41 steps)"
echo " Asus ProArt 16 7606WV — Dual Boot Build"
echo "=============================================="
echo " CRITICAL — DO BEFORE REBOOTING INTO WINDOWS:"
echo " 1. Verify GRUB sees both OS entries:"
echo "    grep -i windows /boot/grub2/grub.cfg"
echo "    If missing: grub2-mkconfig -o /boot/grub2/grub.cfg"
echo "=============================================="
echo " NVIDIA DRIVER — VERIFY BEFORE FIRST REBOOT:"
echo " 2. Confirm akmod built successfully:"
echo "    ls /lib/modules/\$(uname -r)/extra/nvidia/"
echo "    Should show nvidia.ko, nvidia-drm.ko etc."
echo "    If empty: akmods --force && dracut --force"
echo " 3. Secure Boot is DISABLED (done pre-install)."
echo "    To re-enable later, enroll the MOK key:"
echo "    mokutil --import /etc/pki/akmods/certs/public_key.der"
echo "    Then reboot — MOK manager will prompt for confirmation"
echo "=============================================="
echo " FIRST BOOT CHECKLIST:"
echo " 4.  Change devuser password: passwd devuser"
echo " 5.  Verify GPU setup:"
echo "     supergfxctl -g   (shows current GPU mode)"
echo "     nvidia-smi        (confirms RTX 4060 visible)"
echo "     prime-run glxinfo | grep 'OpenGL renderer'"
echo " 6.  Verify ZRAM: zramctl && swapon --show"
echo " 7.  SSH key check:"
echo "     grep 'SSH key injection' /var/log/ks-post.log"
echo " 8.  MariaDB init: mysql_secure_installation"
echo " 9.  PostgreSQL init: postgresql-setup --initdb"
echo " 10. Tailscale join: tailscale up"
echo " 11. GitHub CLI auth: gh auth login"
echo " 12. Claude Code auth: claude auth login"
echo " 13. Firmware updates: fwupdmgr update"
echo "=============================================="
echo " ASUS ProArt SPECIFIC:"
echo " 14. Battery charge limit set to 80%"
echo "     For AC-only use: asusctl -c 100"
echo " 15. GPU modes (require logout/reboot to switch):"
echo "     Hybrid (default): supergfxctl -m Hybrid"
echo "     AMD only:         supergfxctl -m Integrated"
echo "     Nvidia direct:    supergfxctl -m NvidiaNoModeset"
echo " 16. Fan/performance profiles:"
echo "     asusctl profile -l          (list profiles)"
echo "     asusctl profile -P Quiet    (silent)"
echo "     asusctl profile -P Balanced (default)"
echo "     asusctl profile -P Performance (full power)"
echo " 17. For Steam games on RTX 4060:"
echo "     Add to Steam launch options: prime-run %command%"
echo "     Or switch to NvidiaNoModeset for all games"
echo "=============================================="
echo " IDE / TOOLING:"
echo " 18. JetBrains Toolbox — launch from app menu"
echo "     Install PHPStorm, DataGrip, PyCharm, RubyMine"
echo " 19. kind cluster auto-creates on first login"
echo "     Verify: kubectl get nodes"
echo " 20. Proton-GE: launch ProtonUp-Qt from app menu"
echo " 21. mkcert certs: /etc/pki/tls/mkcert/dev.crt"
echo " 22. Xdebug on port 9003 — idekey=PHPSTORM"
echo "=============================================="
echo " GAMING:"
echo " 23. Steam + Heroic + Lutris installed"
echo " 24. MangoHud: add MANGOHUD=1 to launch options"
echo " 25. GameMode: add gamemoderun to launch options"
echo "     Or combined: prime-run gamemoderun %command%"
echo " 26. PipeWire tuned: quantum=512 @ 48kHz"
echo "=============================================="
echo " LOCAL DEV:"
echo " 27. *.localhost + *.test → 127.0.0.1 (dnsmasq)"
echo " 28. docker-compose shim at /usr/local/bin"
echo " 29. SELinux+Docker configured (selinux=true)"
echo "     Bind mounts need :Z/:z — see:"
echo "     /etc/docker/SELINUX_VOLUMES.txt"
echo "=============================================="
echo " DUAL BOOT NOTES:"
echo " 30. GRUB timeout: 10 seconds, choose OS at boot"
echo "     Change timeout: edit /etc/default/grub"
echo "     GRUB_TIMEOUT=10, then grub2-mkconfig"
echo " 31. Access Windows NTFS drives from Fedora:"
echo "     dnf install ntfs-3g"
echo "     Mount: mount /dev/nvme0n1p3 /mnt/windows"
echo " 32. Windows time sync fix (Windows shows wrong"
echo "     time after booting from Linux):"
echo "     In Windows (Admin PowerShell):"
echo "     reg add HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation /v RealTimeIsUniversal /t REG_DWORD /d 1"
echo "=============================================="


# ==============================================================================
# [45] Hermes agent
# ==============================================================================
echo "[45] Installing Hermes agent..."
echo "=============================================="
HERMES_SETUP="${SCRIPT_DIR}/../hermes/setup-hermes.sh"
if [[ -x "$HERMES_SETUP" ]]; then
    bash "$HERMES_SETUP" "$TARGET_USER" "$(cd "${SCRIPT_DIR}/.." && pwd)"
else
    echo "  WARNING: $HERMES_SETUP not found — skipping Hermes install."
    echo "  Run hermes/setup-hermes.sh manually after provisioning."
fi

# ==============================================================================
# [46] rag-stack — Open WebUI + Qdrant + RAG CLI
# ==============================================================================
# All tooling lives in https://github.com/dktaylor/rag-stack.
# This step clones it to /opt/rag-stack-src and runs its install.sh, which:
#   - Deploys the compose file + MCP server to /opt/rag-stack
#   - Installs 'rag' CLI to /usr/local/bin
#   - Installs rag-stack.service (disabled; started on demand with 'rag start')
#   - Removes any conflicting standalone open-webui container
# The stack is NOT started here — run 'rag start' after first boot.
# ==============================================================================
echo "[46] Deploying rag-stack..."
echo "=============================================="
RAG_STACK_REPO="https://github.com/dktaylor/rag-stack.git"
RAG_SRC="/opt/rag-stack-src"
export RAG_INSTALL_DIR="/opt/rag-stack"

if [ -d "$RAG_SRC/.git" ]; then
    echo "  Updating existing rag-stack source..."
    git -C "$RAG_SRC" pull --ff-only || true
else
    echo "  Cloning $RAG_STACK_REPO..."
    git clone "$RAG_STACK_REPO" "$RAG_SRC" || {
        echo "  WARNING: rag-stack clone failed — install manually after boot:"
        echo "    git clone $RAG_STACK_REPO $RAG_SRC"
        echo "    RAG_INSTALL_DIR=$RAG_INSTALL_DIR bash $RAG_SRC/scripts/install.sh"
        FAILED_STEPS+=("[46] rag-stack")
    }
fi

if [ -d "$RAG_SRC" ]; then
    bash "$RAG_SRC/scripts/install.sh"
fi

# ==============================================================================
# Run summary
# ==============================================================================
echo ""
echo "=============================================="
if [[ ${#FAILED_STEPS[@]} -eq 0 ]]; then
    echo " ALL STEPS COMPLETED with no caught errors."
else
    echo " COMPLETED with ${#FAILED_STEPS[@]} step(s) that hit errors:"
    printf '   - %s\n' "${FAILED_STEPS[@]}"
    echo ""
    echo " These are usually transient network issues. Re-run this script"
    echo " to retry them — already-completed steps will be skipped."
fi
echo "=============================================="
echo ""
echo "IMPORTANT remaining manual steps:"
echo "  - Steam/Heroic: launch from app menu to finish first-run setup"
echo "  - mise tools:  su - ${TARGET_USER} -c 'mise install'"
echo "  - Reboot once to ensure all services (Docker, supergfxd, asusd) start"
