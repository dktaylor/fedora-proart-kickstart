# Decision: Dev Tools Extraction Strategy

**Date:** 2026-06-24  
**Status:** Proposed  
**Context:** The kickstart `%post` scripts contain ~40 steps covering both OS-level provisioning (GPU drivers, ZRAM, SSH hardening, gaming) and developer tooling (PHP, Node, Docker, Kubernetes, IDEs, mise, etc.). The dev tooling portion is generic enough to be useful outside of this machine-specific kickstart.

---

## Options

### Option A — Extract to a standalone script in this repo

Move all dev-tool steps out of `%post` into `scripts/fedora-dev-setup.sh`. The kickstart `%post` sources or calls it directly. `fedora-postinstall-setup.sh` does the same.

**Benefits**
- Immediate win: dev tools can be re-run without reinstalling the OS
- Single source of truth — kickstart and postinstall no longer duplicate logic
- No new infrastructure required; stays in one repo

**Pros**
- Zero friction to implement — pure refactor, no new tooling
- Script can be tested independently (container or VM) without a full kickstart run
- Idempotent re-runs become easy to verify

**Cons**
- Still Fedora-only — no portability gain
- Sharing with others requires them to clone the whole kickstart repo
- No versioning isolation — a breaking change to the dev script affects the kickstart immediately

---

### Option B — Separate repo + git submodule

Extract `fedora-dev-setup.sh` into its own public repository (e.g. `fedora-dev-bootstrap`). Submodule it into this repo at `vendor/fedora-dev-bootstrap/`. The kickstart and postinstall call the submoduled script.

**Benefits**
- Dev tooling gets its own public identity, issue tracker, and release history
- Other Fedora developers can use it independently without the ProArt-specific kickstart
- Pinned submodule commits mean the kickstart always uses a tested version
- Changes to dev tooling go through a separate PR/review cycle from machine config

**Pros**
- Clean separation of concerns: machine config vs. developer environment
- Open source community can contribute (new tools, bug fixes, version bumps)
- Semantic versioning on the submodule makes intentional upgrades explicit
- CI in the sub-repo (container tests) runs independently of kickstart changes

**Cons**
- Two repos to maintain, two PR workflows
- Submodule UX is notoriously awkward (`git submodule update --init`, forgetting to push submodule before the parent)
- Still Fedora-specific — the audience is limited to Fedora users
- Requires a stable, documented interface between the kickstart caller and the script

---

### Option C — Multi-distro builder

A `builder.sh` that takes `--distro fedora|ubuntu|debian|rocky|arch` and generates a distro-appropriate dev setup script. Package names, package managers, and PHP ini paths differ per distro; the builder handles the translation layer.

**Benefits**
- Maximum reach — one project serves the entire Linux dev community
- The FrankenPHP / PHP_INI_SCAN_DIR pattern is already distro-agnostic
- Positions the project as a reference implementation for PHP dev environment setup

**Pros**
- High community value and discoverability
- Forces the script to be well-structured (no distro-specific assumptions baked in)
- Broader contributor base across distros
- Could evolve into a Homebrew-on-Linux style tool for dev environments

**Cons**
- Significantly more complex — package name mapping tables, conditional logic per distro
- PHP extension package names vary significantly: `php-pecl-apcu` (Fedora) vs `php-apcu` (Debian) vs `php8.3-apcu` (Ubuntu PPA)
- Testing matrix explodes: each distro × each tool combination needs validation
- Risk of becoming a poorly-maintained abstraction that works nowhere well
- High upfront investment before any community benefit is realised

---

## Recommended Implementation Path

**Stage 1 (now): Option A**

Extract dev tooling into `scripts/fedora-dev-setup.sh`. Split `%post` into:
- Machine-specific section (GPU, ZRAM, SSH, Asus hardware, gaming) — stays inline in kickstart
- Developer tooling section — moves to `fedora-dev-setup.sh`, called from both kickstart and `fedora-postinstall-setup.sh`

This is a low-risk refactor with immediate benefit and is the prerequisite for everything else.

**Stage 2 (once stable): Option B**

Once `fedora-dev-setup.sh` has a stable interface and has been tested across a few reinstall cycles, move it to its own public repo. Add:
- A `README.md` with usage and customisation docs
- Container-based CI (Podman + Fedora base image) that runs the script end-to-end
- Submodule it back here at a pinned release tag

At this point other Fedora developers can use it.

**Stage 3 (if there is community interest): Option C**

Only pursue multi-distro if Stage 2 attracts contributors from other distros. Do not design for it upfront — the abstraction cost is high and premature generalisation will make the Fedora path worse before the Ubuntu path exists. Let actual contributors drive the distro additions.

---

## Decision Criteria for Moving Between Stages

| Trigger | Action |
|---------|--------|
| `fedora-dev-setup.sh` survives 2+ full reinstall cycles without changes | Begin Stage 2 |
| 3+ GitHub issues or PRs from non-ProArt-16 Fedora users | Publish as standalone repo (Stage 2) |
| Issues or PRs from Ubuntu/Debian/Rocky users | Evaluate Stage 3 scope |
| Maintaining two repos feels like overhead with no community benefit | Stay at Stage 1 indefinitely |
