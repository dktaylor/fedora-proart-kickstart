# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A set of bash scripts and Anaconda kickstart configs that build a custom Fedora 44 Everything netinstall ISO. Target machine: **Asus ProArt 16 7606WV** (AMD Ryzen AI iGPU + Nvidia RTX 4060 hybrid, 4 TB NVMe, dual-boot alongside Windows).

Profile installed: PHP/Symfony/Drupal dev + DevOps + gaming on KDE Plasma.

**Current status: Fedora 44 KDE is already installed and running on bare metal.** The ISO build pipeline here is for re-provisioning / future machines.

## Files

All project files live in `~/fedora-build/`:

| File | Purpose |
|------|---------|
| `fetch-fedora-iso.sh` | Download & SHA-256-verify the base Fedora 44 Everything netinstall ISO into `./iso/` |
| `build-fedora-ks-iso.sh` | Embed a kickstart into the ISO to produce a bootable unattended-install image |
| `fedora-ks.cfg` | Kickstart — **auto-partitioning** (LVM created by Anaconda) |
| `fedora-ks-manualpart.cfg` | Kickstart — **manual partitioning** (Blivet-GUI; use when disk has leftover LVM metadata) |
| `fedora-project-context.sh` | Project state summary; `source` it to load shell functions and aliases |
| `fedora-postinstall-setup.sh` | Standalone 44-step setup script (run after a fresh install, outside kickstart) |
| `verify.sh` | Comprehensive provisioning status checker (63+ assertions) |
| `ollama-gpu-mode.sh` | Switch between local GPU inference and remote desktop inference |

## ISO build workflow

```bash
# Step 1 — fetch base ISO (idempotent; skips re-download if checksum passes)
./fetch-fedora-iso.sh -v 44

# Step 2a — auto-partitioning kickstart
./build-fedora-ks-iso.sh auto    # writes fedora-everything-ks.iso

# Step 2b — manual-partitioning kickstart
./build-fedora-ks-iso.sh manual  # writes fedora-everything-ks-manual.iso

# Flash to USB (replace /dev/sdX)
sudo dd if=fedora-everything-ks.iso of=/dev/sdX bs=4M status=progress
```

Requires: `xorriso` and `mkisofs` (`dnf install xorriso`). The build script mounts the base ISO read-only, rsyncs to a temp dir, injects `ks.cfg` at root, patches `boot/grub2/grub.cfg` and `EFI/BOOT/grub.cfg` to append `inst.ks=cdrom:/ks.cfg`, then repacks with `mkisofs`.

## Verification

```bash
./verify.sh             # full report (63+ checks)
./verify.sh --quiet     # FAIL lines + summary only
./verify.sh --no-hw     # skip GPU/Asus hardware checks (VM mode)
```

Hardware checks (Nvidia, AMD, Asus) auto-SKIP when the hardware isn't detected, so this works cleanly in a VM. Must run as `devuser`, not root — many tools live in per-user dirs (`~/.nvm`, `~/.local`, etc.).

## Ollama / RAG stack

- **Model**: `qwen2.5-coder:7b-instruct-q5_K_M` (local), `qwen2.5-coder:7b-instruct-q8_0` (desktop)
- **Ollama daemon**: port 11434, systemd service with CUDA drop-in (`/etc/systemd/system/ollama.service.d/override.conf`)
- **Open WebUI**: Docker container, port 3000
- **Config**: `/etc/ollama-backend.conf` — set `DESKTOP_IP` here (run `tailscale ip -4` on desktop)

Switch inference backends:
```bash
sudo ./ollama-gpu-mode.sh local    # Hybrid GPU + local RTX 4060 CUDA
sudo ./ollama-gpu-mode.sh remote   # Integrated GPU + remote desktop over Tailscale
```

`local` mode: sets supergfxctl to Hybrid, starts Ollama daemon on dGPU, Open WebUI → localhost:11434.  
`remote` mode: sets supergfxctl to Integrated (dGPU off, max battery), stops local Ollama, Open WebUI → desktop:11434.  
GPU mode changes take effect at next logout.

## Kickstart architecture

Both `.cfg` files share the same structure:

1. **Install method** — graphical, network mirror
2. **Localization** — `en_US.UTF-8`, `America/Chicago`
3. **Accounts** — root locked; `devuser` in `wheel,docker`; SSH key injection (Anaconda `sshkey` directive + `%post` fallback)
4. **Bootloader / disk** — `clearpart --none` preserves Windows; reuses `nvme0n1p1` EFI without reformatting. *Auto* uses `part`/`volgroup`/`logvol`; *manual* pauses at Blivet-GUI.
5. **`%packages`** — ~150 packages: KDE Plasma, PHP + extension build deps, MariaDB, PostgreSQL, Redis, Node.js, Python 3, Ansible, Docker prereqs, gaming libs, Asus hardware tools
6. **`%post`** — 44 numbered steps in chroot + Ollama steps 42–44:

| Steps | What happens |
|-------|-------------|
| 1 | RPM Fusion (free + nonfree) |
| 2 | GPU drivers: open `amdgpu` + `akmod-nvidia`; waits for akmod build |
| 3–4 | `asusctl` + `supergfxctl` (asus-linux COPR); PRIME offload + MUX defaults |
| 5–8 | Steam, Heroic (Flatpak), ProtonUp-Qt, GameMode + MangoHud |
| 9–10 | Docker CE (official repo), kubectl/helm/k9s/kind/kubectx |
| 11–16 | Symfony CLI, Composer tools, Node globals, JetBrains Toolbox, Chef Workstation, GitHub CLI, Claude Code |
| 17 | Full shell env: zsh, oh-my-zsh, Powerlevel10k, aliases, `~/.zshrc` |
| 18–19 | SSH key injection, SSH hardening (password auth disabled) |
| 20–22 | ZRAM config, fail2ban, dnf-automatic security updates |
| 23–24 | nvm, mise (PHP/Ruby/etc. version manager) |
| 25–27 | Xdebug (PHPStorm), mkcert + local SSL certs, kind + local k8s cluster |
| 28–30 | docker-compose shim, ctop, dive |
| 31–36 | PipeWire gaming tuning, GameMode daemon, GPU env flags, Lutris, fwupd, thermald |
| 37–41 | XDG dirs, starship prompt, Tailscale, dnsmasq local dev DNS, Bun + Deno |
| 42–44 | Ollama + Open WebUI container, backend-toggle scripts |

## Key design decisions

- **No swap partition** — ZRAM handles swap entirely (step 20).
- **Fedora 44 CA bundle** — `%post` exports `SSL_CERT_FILE`/`CURL_CA_BUNDLE` to `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` at the top of `%post`; Fedora 44 dropped the legacy `/etc/pki/tls/cert.pem` paths that many Go binaries and installer scripts hardcode.
- **Secure Boot disabled pre-install** — required for `akmod-nvidia` to build without MOK enrollment. Re-enable with: `mokutil --import /etc/pki/akmods/certs/public_key.der`.
- **MUX switch default: Hybrid** — AMD iGPU drives desktop; RTX 4060 via `prime-run <cmd>` or Steam `%command%`. Switch with `supergfxctl -m Integrated|Hybrid|NvidiaNoModeset`.
- **Manual variant** — use `fedora-ks-manualpart.cfg` when the target disk has leftover Fedora LVM metadata from prior attempts; `part`/`volgroup` directives collide with stale metadata, so Blivet-GUI lets you delete it manually first.
- **Password placeholder** — `user --password=yourpassword` in both kickstarts must be replaced with an `--iscrypted` SHA-512 hash before use. Generate: `python3 -c "import crypt; print(crypt.crypt('pass', crypt.mksalt(crypt.METHOD_SHA512)))"`.

## Actual disk layout (this machine)

```
nvme0n1p1   260 MiB  EFI (shared Windows + Fedora, NOT reformatted)
nvme0n1p2    16 MiB  Windows MSR
nvme0n1p3   1.87 TiB NTFS (Windows C:)
nvme0n1p4     2 GiB  Asus restore (do not delete)
nvme0n1p5   260 MiB  Windows recovery
nvme0n1p6    (MYASUS)
Fedora LVM VG: fedora-os
  /boot       2 GiB ext4
  /           150 GiB ext4
  /home       ~1.7 TiB ext4
```

## Pending manual actions (post bare-metal install)

- Set `DESKTOP_IP` in `/etc/ollama-backend.conf` (`tailscale ip -4` on desktop)
- Change `devuser` password (currently placeholder)
- `mokutil --import /etc/pki/akmods/certs/public_key.der` (if re-enabling Secure Boot)
- `tailscale up`
- `gh auth login`
- `fwupdmgr update`
