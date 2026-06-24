#!/bin/bash
set -euo pipefail

# Apply/remove nDPI DROP rules on a netfilter chain, driven by env (compose).
# Runs inside the xt-ndpi-rules container (network_mode: host), so it operates
# on the host's iptables — the same place dockerd creates DOCKER-USER.
#
# Env:
#   NDPI_CHAIN    chain to use (default: DOCKER-USER)
#   NDPI_DROP     comma-separated nDPI protocols to drop (e.g. "bittorrent")
#   NDPI_SOURCE   optional comma-separated source scopes (CIDRs). Empty = all
#                 forwarded traffic. Set to one exit subnet to restrict to it,
#                 e.g. "172.100.0.0/24" (exit1). v4 scopes apply to iptables,
#                 v6 scopes to ip6tables.
#
# Each (source × protocol) becomes "[-s <src>] -m ndpi --proto <p> -j DROP".
# Requires the host xt_ndpi kernel module (xt-ndpi-dkms) and the bundled
# libxt_ndpi.so extension.

CHAIN="${NDPI_CHAIN:-DOCKER-USER}"
PROTOS="${NDPI_DROP:-}"
SOURCES="${NDPI_SOURCE:-}"

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

is_v6() { case "$1" in *:*) return 0 ;; *) return 1 ;; esac; }
csv()   { local s="${1// /}"; local IFS=','; printf '%s\n' $s; }   # one token/line

# Build the iptables match args for a (source, protocol) into the named array.
build_spec() {  # <array-name> <src> <proto>
    local -n _out="$1"; local src="$2" proto="$3"
    _out=()
    if [ -n "$src" ]; then _out=(-s "$src"); fi
    _out+=(-m ndpi --proto "$proto" -j DROP)
}

apply_one() {   # <ipt> <src> <proto>
    local ipt="$1"; local -a spec; build_spec spec "$2" "$3"
    "$ipt" -n -L "$CHAIN" >/dev/null 2>&1 || return 0
    "$ipt" -C "$CHAIN" "${spec[@]}" 2>/dev/null \
        || "$ipt" -I "$CHAIN" 1 "${spec[@]}"
}

remove_one() {  # <ipt> <src> <proto>
    local ipt="$1"; local -a spec; build_spec spec "$2" "$3"
    "$ipt" -n -L "$CHAIN" >/dev/null 2>&1 || return 0
    while "$ipt" -C "$CHAIN" "${spec[@]}" 2>/dev/null; do
        "$ipt" -D "$CHAIN" "${spec[@]}"
    done
}

for_each() {    # <action>
    local action="$1" proto src
    for proto in $(csv "$PROTOS"); do
        if [ -z "$SOURCES" ]; then
            "$action" "$IPT"  "" "$proto"
            "$action" "$IP6T" "" "$proto"
        else
            for src in $(csv "$SOURCES"); do
                if is_v6 "$src"; then "$action" "$IP6T" "$src" "$proto"
                else                  "$action" "$IPT"  "$src" "$proto"; fi
            done
        fi
    done
}

scope_desc() { [ -n "$SOURCES" ] && echo "from [$SOURCES]" || echo "(all sources)"; }

case "$ACTION" in
    attach)
        modprobe xt_ndpi 2>/dev/null || true
        for_each apply_one
        echo "ndpi-rules: dropping [$PROTOS] $(scope_desc) on $CHAIN"
        ;;
    detach)
        for_each remove_one
        echo "ndpi-rules: removed [$PROTOS] $(scope_desc) from $CHAIN"
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