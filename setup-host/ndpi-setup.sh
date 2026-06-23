#!/usr/bin/env bash
set -euo pipefail

# Blocks BitTorrent traffic transiting the VPN using nDPI deep packet
# inspection (xt_ndpi netfilter module). Detection is flow-based, so it
# catches encrypted (MSE/PE) torrents, not just plaintext + DHT.
#
# TARGET: Ubuntu 24.04. Everything ships as Docker-Compose-built .deb packages
# (see ../ndpi):
#   - xt-ndpi-dkms      kernel module (DKMS; auto-rebuilt on kernel upgrades)
#   - xt-ndpi-iptables  libxt_ndpi.so, the "-m ndpi" iptables match
#   - xt-ndpi-filter     generic systemd rule engine (/usr/sbin/ndpi-filter)
#
# The rule engine is generic; the actual rule is DEPLOYMENT CONFIG written by
# this script to /etc/default/ndpi-filter. Architecture (DOCKER-USER, etc.) is
# described in ndpi.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/../ndpi"            # Docker Compose packaging dir
ARTIFACTS="$PKG_DIR/artifacts"           # where built .debs land

CONFIG_FILE="/etc/default/ndpi-filter"   # consumed by /usr/sbin/ndpi-filter
RULE_BIN="/usr/sbin/ndpi-filter"         # shipped by xt-ndpi-filter

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: '$1' must run as root (use sudo)" >&2
        exit 1
    fi
}

usage() {
    local base_name
    base_name="$(basename "$0")"
    cat <<EOF
Usage: $base_name <command>

Commands:
  build       Build the .deb packages with Docker Compose (no root needed)
  install     Install the packages, write the rule config, enable blocking
  uninstall   Disable blocking and remove the packages
  status      Show package / module / rule state

Typical flow:
  $base_name build            # produces ../ndpi/artifacts/*.deb
  sudo $base_name install

The BitTorrent rule lives in this script's write_config(); edit it (or
$CONFIG_FILE on the host) to block other nDPI protocols or scope the chain.
EOF
    exit 0
}

do_build() {
    command -v docker >/dev/null 2>&1 \
        || { echo "Error: docker is required to build the packages" >&2; exit 1; }
    mkdir -p "$ARTIFACTS"
    echo "── Building xt-ndpi .deb packages (Docker Compose) ──"
    # Map the build to the invoking user so the .debs are owned by them.
    ( cd "$PKG_DIR" && USER_ID="$(id -u)" GROUP_ID="$(id -g)" \
        docker compose run --rm --build build )
    echo ""
    echo "Built:"
    ls -1 "$ARTIFACTS"/*.deb
}

write_config() {
    echo "── Writing rule config ($CONFIG_FILE) ──"
    # Sourced by /usr/sbin/ndpi-filter. The engine is generic; this is the
    # deployment policy. NDPI_RULES is a bash array of iptables match specs.
    cat > "$CONFIG_FILE" <<'CFG'
# Config for /usr/sbin/ndpi-filter (xt-ndpi-filter). Sourced as bash.
# Chain to apply rules to. DOCKER-USER = VPN client traffic forwarded by the
# host; use FORWARD/OUTPUT for non-Docker setups.
NDPI_CHAIN="DOCKER-USER"
# iptables match specs, applied to NDPI_CHAIN on both iptables and ip6tables.
# Add a source scope (e.g. -s 172.100.0.0/24) or more protocols as needed.
NDPI_RULES=(
  "-m ndpi --proto bittorrent -j DROP"
)
CFG
}

install_packages() {
    shopt -s nullglob
    local debs=( "$ARTIFACTS"/xt-ndpi-*.deb )
    if [[ ${#debs[@]} -lt 3 ]]; then
        echo "Error: expected 3 xt-ndpi packages in $ARTIFACTS (found ${#debs[@]})." >&2
        echo "Run '$(basename "$0") build' first." >&2
        exit 1
    fi

    echo "── Installing packages ──"
    # apt resolves the build deps (dkms, build-essential, kernel headers) and
    # DKMS builds xt_ndpi for the running kernel during this step.
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${debs[@]}"

    echo ""
    echo "── Verifying ──"
    modprobe xt_ndpi
    dkms status xt-ndpi 2>/dev/null | grep -q installed \
        || { echo "ERROR: xt-ndpi DKMS module not installed" >&2; exit 1; }
    lsmod | grep -q '^xt_ndpi' || { echo "ERROR: xt_ndpi not loaded" >&2; exit 1; }
    iptables -m ndpi --help >/dev/null 2>&1 \
        || { echo "ERROR: iptables -m ndpi extension not found" >&2; exit 1; }
    echo "xt_ndpi loaded and iptables '-m ndpi' available."
}

do_install() {
    require_root install
    write_config          # config must exist before the service starts
    install_packages      # installing xt-ndpi-filter enables ndpi-filter.service
    systemctl restart ndpi-filter.service 2>/dev/null || true
    echo ""
    "$RULE_BIN" status 2>/dev/null || true
    echo ""
    echo "Done. BitTorrent traffic through the VPN is now being dropped."
    echo "DKMS will rebuild xt_ndpi automatically on kernel upgrades."
}

do_uninstall() {
    require_root uninstall
    echo "This will stop BitTorrent blocking and remove the xt-ndpi packages."
    read -rp "Continue? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "── Removing packages ──"
    # Purging xt-ndpi-filter stops the service (its ExecStop removes the rules)
    # and disables the unit before the files are deleted.
    DEBIAN_FRONTEND=noninteractive apt-get purge -y \
        xt-ndpi-filter xt-ndpi-iptables xt-ndpi-dkms 2>/dev/null || true
    modprobe -r xt_ndpi 2>/dev/null || true
    rm -f "$CONFIG_FILE"

    echo ""
    echo "Done. xt-ndpi and BitTorrent blocking removed."
}

do_status() {
    echo "── Packages ──"
    dpkg-query -W -f='  ${Package} ${Version} (${db:Status-Status})\n' \
        xt-ndpi-dkms xt-ndpi-iptables xt-ndpi-filter 2>/dev/null || echo "  not installed"
    echo ""
    echo "── DKMS ──"
    dkms status xt-ndpi 2>/dev/null || echo "  (none)"
    echo ""
    echo "── Module ──"
    lsmod | grep '^xt_ndpi' || echo "  xt_ndpi not loaded"
    echo ""
    echo "── iptables extension ──"
    iptables -m ndpi --help >/dev/null 2>&1 && echo "  -m ndpi available" || echo "  -m ndpi NOT available"
    echo ""
    echo "── Config ($CONFIG_FILE) ──"
    [[ -r "$CONFIG_FILE" ]] && grep -vE '^\s*#|^\s*$' "$CONFIG_FILE" | sed 's/^/  /' || echo "  (none)"
    echo ""
    echo "── Service ──"
    systemctl is-active ndpi-filter.service 2>/dev/null || true
    echo ""
    [[ -x "$RULE_BIN" ]] && "$RULE_BIN" status || echo "rule engine not installed"
}

case "${1:-}" in
    build)     do_build ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    *)         usage ;;
esac
