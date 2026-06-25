#!/usr/bin/env bash
set -euo pipefail

# Host-side setup for nDPI BitTorrent blocking.
#
# The DROP rule itself is applied by the xt-ndpi-rules docker-compose service
# (it bundles libxt_ndpi.so and runs on the host network). A kernel module
# can't be containerized, so this script only manages the xt_ndpi MODULE on the
# host via the DKMS package — which DKMS rebuilds automatically on kernel
# upgrades and auto-loads at boot.
#
#   build      build the .deb packages with Docker Compose (no root needed)
#   install    apt-install xt-ndpi-dkms (DKMS builds + loads xt_ndpi)
#   uninstall  purge xt-ndpi-dkms
#   status     show package / module state
#
# After install, bring up the rule service (configure it in docker-compose.yml):
#   docker compose up -d --build xt-ndpi-rules

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/../ndpi"            # Docker Compose packaging dir
ARTIFACTS="$PKG_DIR/artifacts"           # where built .debs land

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
  install     Install xt-ndpi-dkms (the host kernel module)
  verify      Check the module is DKMS-installed and load it
  uninstall   Remove the kernel module package
  status      Show package / module state

Typical flow:
  $base_name build                       # -> ../ndpi/artifacts/*.deb
  sudo $base_name install                # host kernel module
  docker compose up -d --build xt-ndpi-rules   # applies the DROP rule

The rule (which nDPI protocols, which chain) is configured on the
xt-ndpi-rules service in docker-compose.yml (NDPI_DROP / NDPI_CHAIN).
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

# Confirm the DKMS module built+installed, then best-effort load it. Returns
# non-zero only if DKMS didn't install it (a not-loaded-right-now state is a
# NOTE, since it loads at boot / when the service starts). Needs root (modprobe).
verify_module() {
    echo "── Verifying ──"
    dkms status xt-ndpi 2>/dev/null | grep -q installed \
        || { echo "ERROR: xt-ndpi DKMS module not built/installed" >&2; return 1; }

    # A reload can be deferred if the OLD module is still in use (e.g. a running
    # xt-ndpi-rules holding the -m ndpi rule); the module is a livepatch, so a
    # reinstall unloads it until boot/start.
    local loadout
    loadout="$(modprobe xt_ndpi 2>&1)" || true
    # Read /proc/modules directly: `lsmod | grep -q` would SIGPIPE lsmod under
    # `set -o pipefail` (grep -q exits on first match) and falsely report
    # "not loaded" when the module IS loaded.
    if grep -q '^xt_ndpi ' /proc/modules; then
        echo "xt_ndpi installed and loaded."
    else
        echo "NOTE: xt-ndpi-dkms is installed, but xt_ndpi is not loaded right now."
        [ -n "$loadout" ] && echo "      modprobe: $loadout"
        echo "      It loads at boot and when xt-ndpi-rules starts. If that"
        echo "      service is already running, restart it after this reinstall:"
        echo "        docker compose up -d xt-ndpi-rules"
    fi
}

do_verify() {
    require_root verify
    verify_module
}

do_install() {
    require_root install
    shopt -s nullglob
    local dkms=( "$ARTIFACTS"/xt-ndpi-dkms_*.deb )
    if [[ ${#dkms[@]} -eq 0 ]]; then
        echo "Error: xt-ndpi-dkms package not found in $ARTIFACTS" >&2
        echo "Run '$(basename "$0") build' first." >&2
        exit 1
    fi

    echo "── Installing the kernel module package ──"
    # apt resolves the build deps (dkms, build-essential, kernel headers) and
    # DKMS builds xt_ndpi for the running kernel during this step. The package
    # also ships a modules-load.d entry, so xt_ndpi auto-loads at boot.
    # APT::Sandbox::User=root: the .deb lives under $HOME (mode 0750), which the
    # sandboxed '_apt' user can't read — keep the install as root to avoid the
    # "Download is performed unsandboxed" permission notice.
    apt-get update
    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y -o APT::Sandbox::User=root "${dkms[@]}"

    echo ""
    verify_module || exit 1
    echo ""
    echo "Next: docker compose up -d --build xt-ndpi-rules"
}

do_uninstall() {
    require_root uninstall
    echo "This removes the xt_ndpi kernel module package."
    echo "(Stop the rule first: docker compose stop xt-ndpi-rules)"
    read -rp "Continue? [y/N] " confirm
    if [[ "$confirm" != [yY] ]]; then
        echo "Aborted."
        exit 0
    fi

    echo ""
    echo "── Removing ──"
    modprobe -r xt_ndpi 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y xt-ndpi-dkms 2>/dev/null || true

    echo ""
    echo "Done. xt_ndpi removed."
}

do_status() {
    echo "── Package ──"
    dpkg-query -W -f='  ${Package} ${Version} (${db:Status-Status})\n' \
        xt-ndpi-dkms 2>/dev/null || echo "  not installed"
    echo ""
    echo "── DKMS ──"
    dkms status xt-ndpi 2>/dev/null || echo "  (none)"
    echo ""
    echo "── Module ──"
    lsmod | grep '^xt_ndpi' || echo "  xt_ndpi not loaded"
    echo ""
    echo "── Rule service (docker) ──"
    docker ps --filter name=xt-ndpi-rules --format '  {{.Names}}: {{.Status}}' 2>/dev/null || echo "  (docker not available)"
}

case "${1:-}" in
    build)     do_build ;;
    install)   do_install ;;
    verify)    do_verify ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    *)         usage ;;
esac