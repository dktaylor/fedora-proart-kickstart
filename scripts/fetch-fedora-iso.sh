#!/usr/bin/env bash
# ==============================================================================
# fetch-fedora-iso.sh — download + verify the Fedora Everything netinstall ISO
# ==============================================================================
# Pulls the Everything netinstall ISO (the one Anaconda uses for kickstart
# installs), verifies its SHA-256 against Fedora's signed CHECKSUM file, and
# drops it in ./iso/. Re-running skips the download if a valid copy exists.
#
# Why Everything netinstall: it's small (~800 MB) and the full Anaconda
# installer processes kickstarts. Packages come from the network at install
# time (so plan for wired ethernet during the actual install — see project notes).
#
# Usage:
#   ./fetch-fedora-iso.sh                 # latest stable, x86_64
#   ./fetch-fedora-iso.sh -v 44           # pin a specific Fedora release
#   ./fetch-fedora-iso.sh -o /path/to/dir # custom output directory
#   ./fetch-fedora-iso.sh --no-verify     # skip checksum (NOT recommended)
#
# Requires: curl, sha256sum (coreutils). gpg optional (for signature check).
# ==============================================================================

set -euo pipefail

# ----- defaults -----
FEDORA_VERSION=""                 # empty = auto-detect latest stable
ARCH="x86_64"
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${_SCRIPT_DIR}/../iso"
VERIFY=1
GPG_CHECK=1

# ----- arg parsing -----
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--version) FEDORA_VERSION="$2"; shift 2 ;;
        -a|--arch)    ARCH="$2"; shift 2 ;;
        -o|--outdir)  OUTDIR="$2"; shift 2 ;;
        --no-verify)  VERIFY=0; GPG_CHECK=0; shift ;;
        --no-gpg)     GPG_CHECK=0; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -n 30
            exit 0 ;;
        *) echo "Unknown option: $1 (use --help)"; exit 1 ;;
    esac
done

# ----- helpers -----
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">>> $*"; }

command -v curl       >/dev/null || die "curl is required"
command -v sha256sum  >/dev/null || die "sha256sum is required"

mkdir -p "$OUTDIR"

# ----- resolve latest stable version if not pinned -----
# We ask Fedora's released mirror index which top-level numbered dirs exist
# and take the highest. (Avoids hardcoding a version that goes stale.)
if [[ -z "$FEDORA_VERSION" ]]; then
    info "Detecting latest stable Fedora release..."
    BASE="https://download.fedoraproject.org/pub/fedora/linux/releases/"
    # Scrape directory listing for two-digit release numbers, take the max.
    FEDORA_VERSION=$(curl -fsSL "$BASE" \
        | grep -oE 'href="[0-9]+/"' \
        | grep -oE '[0-9]+' \
        | sort -n | tail -1) \
        || die "Could not auto-detect latest version; pass -v <n>"
    [[ -n "$FEDORA_VERSION" ]] || die "Version auto-detect returned empty; pass -v <n>"
fi
info "Target: Fedora ${FEDORA_VERSION} (${ARCH}) Everything netinstall"

# ----- build URLs -----
# Use the redirecting mirror for the ISO (fast), but the canonical
# download.fedoraproject.org for the CHECKSUM (stable, signed).
REL_PATH="releases/${FEDORA_VERSION}/Everything/${ARCH}/iso"
MIRROR="https://download.fedoraproject.org/pub/fedora/linux/${REL_PATH}"
DLDIR="https://dl.fedoraproject.org/pub/fedora/linux/${REL_PATH}"

# The exact ISO filename embeds a build number (e.g. -1.7-), which changes
# per release. Discover it from the CHECKSUM file rather than guessing.
CHECKSUM_NAME="Fedora-Everything-${FEDORA_VERSION}-$([[ "$ARCH" == "x86_64" ]] && echo "x86_64" || echo "$ARCH")-CHECKSUM"

info "Fetching checksum manifest..."
CHECKSUM_URL_CANDIDATES=(
    "${DLDIR}/${CHECKSUM_NAME}"
    "${MIRROR}/${CHECKSUM_NAME}"
)
CHECKSUM_FILE="${OUTDIR}/${CHECKSUM_NAME}"
fetched=0
for url in "${CHECKSUM_URL_CANDIDATES[@]}"; do
    if curl -fsSL "$url" -o "$CHECKSUM_FILE" 2>/dev/null; then
        info "Got checksum from: $url"
        fetched=1; break
    fi
done
# If checksum fetch failed but --no-verify was passed, use a fallback ISO name
if [[ "$fetched" -eq 0 ]]; then
    if [[ "$VERIFY" -eq 0 ]]; then
        warn "Could not fetch CHECKSUM file (network issue?). Using fallback ISO name..."
        # Known ISO filenames for recent Fedora releases
        case "$FEDORA_VERSION" in
            44) ISO_NAME="Fedora-Everything-netinst-x86_64-44-1.7.iso" ;;
            45) ISO_NAME="Fedora-Everything-netinst-x86_64-45-1.2.iso" ;;
            *)  die "Could not fetch CHECKSUM file and no fallback for Fedora ${FEDORA_VERSION}" ;;
        esac
        info "Using fallback ISO name: $ISO_NAME"
    else
        die "Could not fetch CHECKSUM file for Fedora ${FEDORA_VERSION}"
    fi
else
    # Extract the netinstall ISO filename from the checksum manifest.
    ISO_NAME=$(grep -oE 'Fedora-Everything-netinst-[^ )]*\.iso' "$CHECKSUM_FILE" \
                | sort -u | head -1) \
        || die "No netinstall ISO entry found in checksum file"
fi
[[ -n "$ISO_NAME" ]] || die "Could not determine ISO filename from checksum manifest"
info "ISO filename: ${ISO_NAME}"

ISO_PATH="${OUTDIR}/${ISO_NAME}"

# ----- optional GPG verification of the CHECKSUM file itself -----
if [[ "$GPG_CHECK" -eq 1 ]] && command -v gpg >/dev/null 2>&1; then
    info "Attempting GPG verification of checksum manifest..."
    # Fedora signing keys — imported best-effort. If this fails we warn but
    # still rely on the SHA-256 match below.
    KEY_URL="https://fedoraproject.org/fedora.gpg"
    if curl -fsSL "$KEY_URL" -o "${OUTDIR}/fedora.gpg" 2>/dev/null; then
        gpg --quiet --import "${OUTDIR}/fedora.gpg" 2>/dev/null || true
        if gpg --verify "$CHECKSUM_FILE" 2>/dev/null; then
            info "GPG signature on checksum file: VALID"
        else
            echo "WARNING: could not verify GPG signature on checksum file."
            echo "         Proceeding with SHA-256 match only."
        fi
    else
        echo "WARNING: could not fetch Fedora GPG keys; skipping signature check."
    fi
fi

# ----- skip download if a valid ISO already exists -----
if [[ -f "$ISO_PATH" ]]; then
    info "ISO already present, checking integrity before re-downloading..."
    if (cd "$OUTDIR" && sha256sum -c --ignore-missing "$CHECKSUM_NAME" 2>/dev/null | grep -q "${ISO_NAME}: OK"); then
        info "Existing ISO is valid: ${ISO_PATH}"
        echo ""
        echo "Done. Use this ISO with mkksiso, e.g.:"
        echo "  sudo mkksiso --ks <your.ks.cfg> \"${ISO_PATH}\" <output-custom.iso>"
        exit 0
    else
        echo "Existing ISO failed checksum — re-downloading."
        rm -f "$ISO_PATH"
    fi
fi

# ----- download the ISO (resumable) -----
info "Downloading ${ISO_NAME} (~800 MB)..."
curl -fL --retry 3 --retry-delay 2 -C - \
    "${MIRROR}/${ISO_NAME}" -o "$ISO_PATH" \
    || die "ISO download failed"

# ----- verify SHA-256 -----
if [[ "$VERIFY" -eq 1 ]]; then
    info "Verifying SHA-256..."
    if (cd "$OUTDIR" && sha256sum -c --ignore-missing "$CHECKSUM_NAME" 2>/dev/null | grep -q "${ISO_NAME}: OK"); then
        info "Checksum VALID — ISO is good."
    else
        die "CHECKSUM MISMATCH. The download is corrupt; delete ${ISO_PATH} and retry."
    fi
else
    echo "WARNING: checksum verification skipped (--no-verify)."
fi

echo ""
echo "=============================================="
echo " Fedora ${FEDORA_VERSION} Everything netinstall ready"
echo " Path: ${ISO_PATH}"
echo "=============================================="
echo "Next: bake your kickstart into it with mkksiso:"
echo "  sudo mkksiso --ks <your.ks.cfg> \"${ISO_PATH}\" \"${OUTDIR}/fedora-custom.iso\""
echo ""
echo "Reminder: for the real install, prefer WIRED ethernet so %post has network."
