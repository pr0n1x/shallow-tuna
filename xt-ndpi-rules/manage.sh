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

# Pick the iptables backend that actually owns $CHAIN. DOCKER-USER lives only in
# the backend dockerd chose (legacy vs nft); a built-in chain exists in both
# (either is evaluated by the kernel). This avoids silently writing the rule
# into a backend dockerd isn't using.
detect_backend() {
    local has_legacy=0 has_nft=0
    iptables-legacy -n -L "$CHAIN" >/dev/null 2>&1 && has_legacy=1 || true
    iptables-nft    -n -L "$CHAIN" >/dev/null 2>&1 && has_nft=1    || true
    if   [ "$has_legacy" = 1 ] && [ "$has_nft" = 0 ]; then echo legacy
    elif [ "$has_nft" = 1 ] && [ "$has_legacy" = 0 ]; then echo nft
    elif [ "$has_legacy" = 1 ] && [ "$has_nft" = 1 ]; then echo default
    else echo none
    fi
}

ACTION="${1:-}"
BACKEND="$(detect_backend)"

if [ "$BACKEND" = none ]; then
    case "$ACTION" in
        detach|status)
            echo "ndpi-rules: chain '$CHAIN' not present in any backend (nothing to do)"
            exit 0 ;;
        *)
            echo "ERROR: chain '$CHAIN' not found in iptables-legacy or iptables-nft." >&2
            echo "       Is dockerd up, and is NDPI_CHAIN ('$CHAIN') correct?" >&2
            exit 1 ;;
    esac
fi

case "$BACKEND" in
    legacy)  IPT=iptables-legacy;  IP6T=ip6tables-legacy ;;
    nft)     IPT=iptables-nft;     IP6T=ip6tables-nft ;;
    default) IPT=iptables;         IP6T=ip6tables ;;
esac
echo "ndpi-rules: chain $CHAIN -> $BACKEND backend" >&2

apply_one() {
    local ipt="$1" proto="$2"
    # The chain may be absent for one family (e.g. no IPv6 DOCKER-USER).
    "$ipt" -n -L "$CHAIN" >/dev/null 2>&1 || return 0
    "$ipt" -C "$CHAIN" -m ndpi --proto "$proto" -j DROP 2>/dev/null \
        || "$ipt" -I "$CHAIN" 1 -m ndpi --proto "$proto" -j DROP
}

remove_one() {
    local ipt="$1" proto="$2"
    "$ipt" -n -L "$CHAIN" >/dev/null 2>&1 || return 0
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
        "$action" "$IPT"  "$proto"
        "$action" "$IP6T" "$proto"
    done
    unset IFS
}

case "$ACTION" in
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
        echo "== $IPT $CHAIN =="
        "$IPT" -n -L "$CHAIN" --line-numbers 2>/dev/null | grep -i ndpi || echo "  (no ndpi rule)"
        echo "== $IP6T $CHAIN =="
        "$IP6T" -n -L "$CHAIN" --line-numbers 2>/dev/null | grep -i ndpi || echo "  (no ndpi rule)"
        ;;
    *)
        echo "Usage: $0 <attach|detach|status>" >&2
        exit 1
        ;;
esac