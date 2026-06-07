#!/usr/bin/env bash
set -euo pipefail

# Blocks BitTorrent traffic transiting the VPN using nDPI deep packet
# inspection (xt_ndpi netfilter module). Detection is flow-based, so it
# catches encrypted (MSE/PE) torrents, not just plaintext + DHT.
#
# TARGET: Ubuntu 24.04 (kernel 6.8.x) only. The xt_ndpi kernel module is
# built from source against the running kernel; see ndpi.md for the
# (documented) maintenance step required after a kernel upgrade.
#
# Architecture:
#   - xt_ndpi.ko + libxt_ndpi.so are built/installed on the HOST. The module
#     is global to the host kernel; the iptables extension can't live inside
#     the Alpine/musl VPN containers, so the DROP rule runs on the host.
#   - VPN client traffic is MASQUERADEd inside the container, then forwarded
#     by the host (docker bridge -> uplink), so it passes through the host
#     FORWARD chain. Docker's DOCKER-USER chain is the supported hook for
#     user rules there and is not flushed on container restart.
#   - A systemd unit re-applies the rule whenever docker (re)starts.

if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root (sudo $0 install|uninstall)" >&2
    exit 1
fi

# nDPI source. Default to the netfilter-maintained fork's master branch
# (carries the kernel 6.8 fixes). Pin NDPI_REF=<tag|commit> for reproducible
# builds once you've validated a specific revision on your kernel.
NDPI_REPO="${NDPI_REPO:-https://github.com/vel21ripn/nDPI.git}"
NDPI_REF="${NDPI_REF:-master}"
SRC_DIR="/usr/src/ndpi-netfilter"

RULE_BIN="/usr/local/sbin/ndpi-filter"
SERVICE="/etc/systemd/system/ndpi-filter.service"
MODULES_CONF="/etc/modules-load.d/xt_ndpi.conf"

usage() {
    local base_name
    base_name="$(basename "$0")"
    cat <<EOF
Usage: $base_name <command>

Commands:
  install     Build & install xt_ndpi, then enable BitTorrent blocking
  uninstall   Disable blocking and remove xt_ndpi
  rebuild     Rebuild the module against the current kernel (run after a
              kernel upgrade), then reload it
  status      Show module + rule state

Environment:
  NDPI_REPO   nDPI git repo   (default: $NDPI_REPO)
  NDPI_REF    git tag/commit  (default: $NDPI_REF)

Examples:
  sudo $base_name install
  sudo NDPI_REF=4.12 $base_name install
  sudo $base_name rebuild
EOF
    exit 0
}

build_module() {
    echo "── Installing build prerequisites ──"
    apt-get update
    apt-get install -y \
        build-essential git autoconf automake libtool pkg-config \
        gettext flex bison \
        libpcap-dev libjson-c-dev libnuma-dev libpcre2-dev \
        libmaxminddb-dev librrd-dev libgcrypt20-dev \
        iptables-dev "linux-headers-$(uname -r)"

    echo ""
    echo "── Fetching nDPI ($NDPI_REF) ──"
    if [[ -d "$SRC_DIR/.git" ]]; then
        git -C "$SRC_DIR" fetch --all --tags --prune
    else
        rm -rf "$SRC_DIR"
        git clone "$NDPI_REPO" "$SRC_DIR"
    fi
    git -C "$SRC_DIR" checkout "$NDPI_REF"
    git -C "$SRC_DIR" pull --ff-only 2>/dev/null || true

    echo ""
    echo "── Building libndpi ──"
    cd "$SRC_DIR"
    ./autogen.sh
    make -j"$(nproc)"

    echo ""
    echo "── Building xt_ndpi kernel module + iptables extension ──"
    cd "$SRC_DIR/ndpi-netfilter"
    make -j"$(nproc)"

    echo ""
    echo "── Installing module + libxt_ndpi.so ──"
    make install
    depmod -a

    echo ""
    echo "── Loading module ──"
    modprobe xt_ndpi
    grep -qxF "xt_ndpi" "$MODULES_CONF" 2>/dev/null || echo "xt_ndpi" > "$MODULES_CONF"

    echo ""
    echo "── Verifying ──"
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
MATCH=(-m ndpi --bittorrent -j DROP)

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
    build_module
    install_rule_manager
    echo ""
    echo "Done. BitTorrent traffic through the VPN is now being dropped."
    echo "Note: after a kernel upgrade run 'sudo $(basename "$0") rebuild'."
}

do_rebuild() {
    build_module
    systemctl restart ndpi-filter.service 2>/dev/null || true
    echo ""
    echo "Done. xt_ndpi rebuilt for kernel $(uname -r) and rule re-applied."
}

do_uninstall() {
    echo "This will stop BitTorrent blocking and remove the xt_ndpi module."
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
    echo "── Unloading + removing module ──"
    modprobe -r xt_ndpi 2>/dev/null || true
    rm -f "$MODULES_CONF"
    if [[ -d "$SRC_DIR/ndpi-netfilter" ]]; then
        make -C "$SRC_DIR/ndpi-netfilter" uninstall 2>/dev/null || true
    fi
    depmod -a 2>/dev/null || true
    rm -rf "$SRC_DIR"

    echo ""
    echo "Done. xt_ndpi and BitTorrent blocking removed."
}

do_status() {
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
    install)   do_install ;;
    rebuild)   do_rebuild ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    *)         usage ;;
esac