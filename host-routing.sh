#!/bin/bash
set -euo pipefail

# Host-side SNAT rules for multi-IP exit routing.
# Reads EXIT_ROUTES from .env and maps Docker network subnets to external IPs.
#
# EXIT_ROUTES format: "gateway:external_ip,gateway:external_ip,..."
# Example: EXIT_ROUTES=172.100.0.1:1.2.3.4,172.101.0.1:2.3.4.5
#
# Must be run on the Docker host (not inside a container).
# Re-run after docker compose up (Docker's rules take priority otherwise).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

usage() {
    echo "Usage: $0 <attach|detach|status>"
    echo
    echo "Reads EXIT_ROUTES from .env file"
    echo "Format: gateway:external_ip,gateway:external_ip,..."
    exit 1
}

# Load EXIT_ROUTES from .env
if [ -f "$ENV_FILE" ]; then
    EXIT_ROUTES=$(grep -E '^EXIT_ROUTES=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
fi

if [ -z "${EXIT_ROUTES:-}" ]; then
    echo "ERROR: EXIT_ROUTES not set in $ENV_FILE" >&2
    exit 1
fi

# Detect the default outbound interface
IFACE=$(ip route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
if [ -z "$IFACE" ]; then
    echo "ERROR: cannot detect default outbound interface" >&2
    exit 1
fi

# Get subnet for a gateway IP by finding matching Docker network
get_subnet() {
    local gateway="$1"
    docker network ls -q | while read -r net_id; do
        subnet=$(docker network inspect "$net_id" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
        [ -z "$subnet" ] && continue
        # Check if gateway is in this subnet (simple /24 check)
        net_prefix="${subnet%.*}"
        gw_prefix="${gateway%.*}"
        if [ "$net_prefix" = "$gw_prefix" ]; then
            echo "$subnet"
            return
        fi
    done
}

add_rule() {
    local subnet="$1" ip="$2"
    if iptables -t nat -C POSTROUTING -s "$subnet" -o "$IFACE" -j SNAT --to-source "$ip" 2>/dev/null; then
        echo "  already exists: $subnet → $ip"
    else
        iptables -t nat -I POSTROUTING -s "$subnet" -o "$IFACE" -j SNAT --to-source "$ip"
        echo "  added: $subnet → $ip (via $IFACE)"
    fi
}

remove_rule() {
    local subnet="$1" ip="$2"
    iptables -t nat -D POSTROUTING -s "$subnet" -o "$IFACE" -j SNAT --to-source "$ip" 2>/dev/null \
        && echo "  removed: $subnet → $ip" \
        || echo "  not found: $subnet → $ip"
}

process_routes() {
    local action="$1"
    IFS=','
    for route in $EXIT_ROUTES; do
        gateway="${route%%:*}"
        external_ip="${route##*:}"

        subnet=$(get_subnet "$gateway")
        if [ -z "$subnet" ]; then
            echo "  WARNING: no Docker network found for gateway $gateway, skipping" >&2
            continue
        fi

        "$action" "$subnet" "$external_ip"
    done
    unset IFS
}

case "${1:-}" in
    attach)
        echo "Attaching SNAT rules (interface: $IFACE):"
        process_routes add_rule
        ;;
    detach)
        echo "Detaching SNAT rules:"
        process_routes remove_rule
        ;;
    status)
        echo "Current NAT POSTROUTING rules:"
        iptables -t nat -L POSTROUTING -n --line-numbers | grep -E 'SNAT|Chain' || echo "  (none)"
        ;;
    *)
        usage
        ;;
esac