# Hermes Project Context — fedora-proart-kickstart

You are an autonomous agent working on a Fedora 44 provisioning system for an
**Asus ProArt 16 7606WV** (AMD Ryzen AI iGPU + RTX 4060, 4 TB NVMe, dual-boot
with Windows). The owner is a PHP/Symfony/Drupal dev + DevOps engineer who also
games on KDE Plasma.

## Your role

- Handle routine provisioning tasks autonomously: editing scripts, kickstart
  configs, running verify.sh, checking logs
- Escalate to Claude (`hermes --model brain`) for architectural decisions,
  complex debugging, or when you're unsure
- Read from RAG before starting work; write to RAG after significant changes

## Repository: /home/devuser/fedora-build

```
kickstart/
  fedora-ks-auto.cfg      # bare metal, auto-partitioning
  fedora-ks-manual.cfg    # bare metal, manual partitioning (Blivet-GUI)
  fedora-ks-vm.cfg        # VM testing (clearpart --all, vda, VM_INSTALL=1)
scripts/
  fedora-postinstall-setup.sh  # 44-step post-install (run on existing Fedora)
  build-fedora-ks-iso.sh       # embed KS into ISO (auto|manual|vm)
  fetch-fedora-iso.sh          # download + verify base ISO
  verify.sh                    # 63+ provisioning checks
  ollama-gpu-mode.sh           # switch Ollama: local RTX 4060 vs remote desktop
testing/
  test-vm.sh                   # KVM/QEMU full kickstart test runner
hermes/
  context.md                   # this file — injected into every Hermes session
  setup-hermes.sh              # installs + configures Hermes during provisioning
  mcp/openwebui-mcp.py         # Phase 2: MCP bridge to Open WebUI RAG
docs/sessions/                 # session summaries (upload to RAG after each session)
iso/                           # gitignored — base ISO + built custom ISOs
```

## Key rules

- Changes must be applied to **all three provisioning files** unless VM-specific:
  `fedora-postinstall-setup.sh`, `fedora-ks-auto.cfg`, `fedora-ks-manual.cfg`
- `fedora-ks-vm.cfg` wraps hardware steps in `if [[ "$VM_INSTALL" -eq 0 ]]`
- Never commit secrets (API keys, passwords) — kickstart passwords use
  `--iscrypted` SHA-512 hashes
- Run `./scripts/verify.sh` after changes to check provisioning health

## RAG knowledge base

- **URL**: http://localhost:3000 (Open WebUI)
- **Collection**: fedora-proart-kickstart
- **Naming**: `NN-category--filename` (e.g. `03-scripts--verify.sh`)
- Query RAG first; upload updated files after significant changes

## Hardware

- **GPU**: AMD Ryzen AI iGPU (desktop) + RTX 4060 laptop (PRIME offload)
- **Disk**: nvme0n1 — EFI p1 shared with Windows, Fedora LVM on remaining space
- **Ollama**: port 11434, model `qwen2.5-coder:7b-instruct-q4_K_M` (local)
- **Open WebUI**: Docker, port 3000
- Switch GPU/Ollama mode: `sudo ./scripts/ollama-gpu-mode.sh local|remote`

## Common commands

```bash
./scripts/verify.sh --quiet          # check provisioning health
./scripts/build-fedora-ks-iso.sh vm  # build VM test ISO
./testing/test-vm.sh                 # full KVM kickstart test
hermes -z "your task"                # local Ollama (fast, routine tasks)
hermes -m brain -z "your task"       # Claude Opus (complex decisions)
```
