#!/usr/bin/env bash
set -euo pipefail

# Blocks BitTorrent traffic transiting the VPN using nDPI deep packet
# inspection (xt_ndpi netfilter module). Detection is flow-based, so it
# catches encrypted (MSE/PE) torrents, not just plaintext + DHT.
#
# TARGET: Ubuntu 24.04. The xt_ndpi module ships as DKMS packages (see ../ndpi):
#   - `build`   builds the .deb packages with Docker Compose.
#   - `install` installs them. DKMS compiles xt_ndpi against the running kernel
#     and AUTO-REBUILDS it on every kernel upgrade (no manual rebuild step).
#
# Architecture:
#   - xt_ndpi.ko (xt-ndpi-dkms) + libxt_ndpi.so (xt-ndpi-iptables) live on the
#     HOST. The module is global to the host kernel; the iptables extension
#     can't run inside the Alpine/musl VPN containers, so the DROP rule runs on
#     the host.
#   - VPN client traffic is MASQUERADEd inside the container, then forwarded by
#     the host (docker bridge -> uplink), so it passes through the host FORWARD
#     chain. Docker's DOCKER-USER chain is the supported hook for user rules
#     there and is not flushed on container restart.
#   - A systemd unit re-applies the rule whenever docker (re)starts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/../ndpi"            # Docker Compose packaging dir
ARTIFACTS="$PKG_DIR/artifacts"           # where built .debs land

RULE_BIN="/usr/local/sbin/ndpi-filter"
SERVICE="/etc/systemd/system/ndpi-filter.service"
MODULES_CONF="/etc/modules-load.d/xt_ndpi.conf"

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
  install     Install the packages and enable BitTorrent blocking
  uninstall   Disable blocking and remove the packages
  status      Show package / module / rule state

Typical flow:
  $base_name build            # produces ../ndpi/artifacts/*.deb
  sudo $base_name install
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

install_packages() {
    shopt -s nullglob
    local dkms=( "$ARTIFACTS"/xt-ndpi-dkms_*.deb )
    local ipt=( "$ARTIFACTS"/xt-ndpi-iptables_*.deb )
    if [[ ${#dkms[@]} -eq 0 || ${#ipt[@]} -eq 0 ]]; then
        echo "Error: packages not found in $ARTIFACTS" >&2
        echo "Run '$(basename "$0") build' first." >&2
        exit 1
    fi

    echo "── Installing packages ──"
    # apt resolves the build deps (dkms, build-essential, kernel headers) and
    # DKMS builds xt_ndpi for the running kernel during this step.
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${dkms[@]}" "${ipt[@]}"

    echo ""
    echo "── Loading module ──"
    modprobe xt_ndpi
    grep -qxF "xt_ndpi" "$MODULES_CONF" 2>/dev/null || echo "xt_ndpi" > "$MODULES_CONF"

    echo ""
    echo "── Verifying ──"
    dkms status xt-ndpi 2>/dev/null | grep -q installed \
        || { echo "ERROR: xt-ndpi DKMS module not installed" >&2; exit 1; }
    lsmod | grep -q '^xt_ndpi' || { echo "ERROR: xt_ndpi not loaded" >&2; exit 1; }
    iptables -m ndpi --help >/dev/null 2>&1 \
        || { echo "ERROR: iptables -m ndpi extension not found (libxt_ndpi.so missing?)" >&2; exit 1; }
    echo "xt_ndpi loaded and iptables '-m ndpi' available."
}

install_rule_manager() {
    echo ""
    echo "── Installing rule manager ($RULE_BIN) ──"
    # Drops any flow nDPI classifies as BitTorrent on the host FORWARD path
    # (DOCKER-USER). All forwarded traffic on a VPN exit is client traffic, so
    # no source-subnet scoping is needed; add '-s <exit-subnet>' here if you
    # want to limit it to specific exit networks.
    cat > "$RULE_BIN" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
# Manage the BitTorrent DROP rule in Docker's DOCKER-USER chain.
CHAIN="DOCKER-USER"
MATCH=(-m ndpi --proto bittorrent -j DROP)

apply_one() {
    local ipt="$1"
    # DOCKER-USER only exists once dockerd has started.
    "$ipt" -n -L "$CHAIN" >/dev/null 2>&1 || return 0
    "$ipt" -C "$CHAIN" "${MATCH[@]}" 2>/dev/null \
        || "$ipt" -I "$CHAIN" 1 "${MATCH[@]}"
}
remove_one() {
    local ipt="$1"
    while "$ipt" -C "$CHAIN" "${MATCH[@]}" 2>/dev/null; do
        "$ipt" -D "$CHAIN" "${MATCH[@]}"
    done
}

case "${1:-}" in
    start)
        modprobe xt_ndpi 2>/dev/null || true
        apply_one iptables
        apply_one ip6tables
        echo "ndpi-filter: BitTorrent DROP rule applied"
        ;;
    stop)
        remove_one iptables
        remove_one ip6tables
        echo "ndpi-filter: BitTorrent DROP rule removed"
        ;;
    status)
        echo "== iptables $CHAIN =="
        iptables -n -L "$CHAIN" --line-numbers 2>/dev/null | grep -i ndpi || echo "  (no ndpi rule)"
        echo "== ip6tables $CHAIN =="
        ip6tables -n -L "$CHAIN" --line-numbers 2>/dev/null | grep -i ndpi || echo "  (no ndpi rule)"
        ;;
    *)
        echo "Usage: $0 <start|stop|status>" >&2
        exit 1
        ;;
esac
SCRIPT
    chmod 0755 "$RULE_BIN"

    echo "── Installing systemd unit ($SERVICE) ──"
    # PartOf=docker.service => the rule is re-applied every time docker
    # (re)starts, since dockerd recreates the DOCKER-USER chain then.
    cat > "$SERVICE" <<SERVICE_EOF
[Unit]
Description=Block BitTorrent on VPN exit (nDPI / DOCKER-USER)
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe xt_ndpi
ExecStart=$RULE_BIN start
ExecStop=$RULE_BIN stop

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    systemctl daemon-reload
    systemctl enable --now ndpi-filter.service
    "$RULE_BIN" status
}

do_install() {
    require_root install
    install_packages
    install_rule_manager
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
    echo "── Disabling rule + service ──"
    systemctl disable --now ndpi-filter.service 2>/dev/null || true
    [[ -x "$RULE_BIN" ]] && "$RULE_BIN" stop 2>/dev/null || true
    rm -f "$SERVICE" "$RULE_BIN"
    systemctl daemon-reload 2>/dev/null || true

    echo ""
    echo "── Removing packages ──"
    modprobe -r xt_ndpi 2>/dev/null || true
    rm -f "$MODULES_CONF"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y xt-ndpi-iptables xt-ndpi-dkms 2>/dev/null || true

    echo ""
    echo "Done. xt-ndpi and BitTorrent blocking removed."
}

do_status() {
    echo "── Packages ──"
    dpkg-query -W -f='  ${Package} ${Version} (${db:Status-Status})\n' \
        xt-ndpi-dkms xt-ndpi-iptables 2>/dev/null || echo "  not installed"
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
    echo "── Service ──"
    systemctl is-active ndpi-filter.service 2>/dev/null || true
    echo ""
    [[ -x "$RULE_BIN" ]] && "$RULE_BIN" status || echo "rule manager not installed"
}

case "${1:-}" in
    build)     do_build ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    *)         usage ;;
esac
