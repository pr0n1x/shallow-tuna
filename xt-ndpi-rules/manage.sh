#!/bin/bash
set -euo pipefail

# Apply/remove nDPI DROP rules on a netfilter chain, driven by env (compose).
# Runs inside the xt-ndpi-rules container (network_mode: host), so it operates
# on the host's iptables — the same place dockerd creates DOCKER-USER.
#
# Env:
#   NDPI_CHAIN   chain to use (default: DOCKER-USER)
#   NDPI_DROP    comma-separated nDPI protocols to drop (e.g. "bittorrent")
#
# Each protocol becomes "-m ndpi --proto <p> -j DROP" on iptables + ip6tables.
# Requires the host xt_ndpi kernel module (xt-ndpi-dkms) and the bundled
# libxt_ndpi.so extension.

CHAIN="${NDPI_CHAIN:-DOCKER-USER}"
PROTOS="${NDPI_DROP:-}"

if [ -z "$PROTOS" ]; then
    echo "ERROR: NDPI_DROP not set (comma-separated nDPI protocols)" >&2
    exit 1
fi

apply_one() {
    local ipt="$1" proto="$2"
    # The chain may not exist yet (DOCKER-USER appears once dockerd starts).
    "$ipt" -n -L "$CHAIN" >/dev/null 2>&1 || return 0
    "$ipt" -C "$CHAIN" -m ndpi --proto "$proto" -j DROP 2>/dev/null \
        || "$ipt" -I "$CHAIN" 1 -m ndpi --proto "$proto" -j DROP
}

remove_one() {
    local ipt="$1" proto="$2"
    while "$ipt" -C "$CHAIN" -m ndpi --proto "$proto" -j DROP 2>/dev/null; do
        "$ipt" -D "$CHAIN" -m ndpi --proto "$proto" -j DROP
    done
}

for_each() {
    local action="$1" proto
    IFS=','
    for proto in $PROTOS; do
        proto="$(echo "$proto" | tr -d '[:space:]')"
        [ -z "$proto" ] && continue
        "$action" iptables  "$proto"
        "$action" ip6tables "$proto"
    done
    unset IFS
}

case "${1:-}" in
    attach)
        modprobe xt_ndpi 2>/dev/null || true
        for_each apply_one
        echo "ndpi-rules: dropping [$PROTOS] on $CHAIN"
        ;;
    detach)
        for_each remove_one
        echo "ndpi-rules: removed [$PROTOS] from $CHAIN"
        ;;
    status)
        echo "== iptables $CHAIN =="
        iptables -n -L "$CHAIN" --line-numbers 2>/dev/null | grep -i ndpi || echo "  (no ndpi rule)"
        echo "== ip6tables $CHAIN =="
        ip6tables -n -L "$CHAIN" --line-numbers 2>/dev/null | grep -i ndpi || echo "  (no ndpi rule)"
        ;;
    *)
        echo "Usage: $0 <attach|detach|status>" >&2
        exit 1
        ;;
esac