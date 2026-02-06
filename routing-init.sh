#!/bin/sh
set -e

# Container entrypoint wrapper for multi-IP exit routing.
# Sets up routing tables and MASQUERADE for exit Docker networks.
#
# EXIT_ROUTES env var format: "gateway:external_ip,gateway:external_ip,..."
# Example: EXIT_ROUTES=172.100.0.1:1.2.3.4,172.101.0.1:2.3.4.5
#
# Each entry creates:
#   - A routing table (auto-assigned: 100, 101, 102...)
#   - A MASQUERADE rule for VPN traffic on that interface
#
# Per-client routing is managed via assign-exit.sh or:
#   docker exec <container> ip rule add from <client-ip> lookup <table_id>

ROUTES_FILE="/etc/wireguard/exit-routes"

if [ -n "${EXIT_ROUTES:-}" ]; then
    table_id=100
    IFS=','
    for route in $EXIT_ROUTES; do
        gateway="${route%%:*}"

        # Find the interface that reaches this gateway
        iface=$(ip route get "$gateway" 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2}')
        if [ -z "$iface" ]; then
            echo "routing-init: WARNING: no route to gateway $gateway, skipping table $table_id" >&2
            table_id=$((table_id + 1))
            continue
        fi

        ip route add default via "$gateway" dev "$iface" table "$table_id" 2>/dev/null || true

        # Add MASQUERADE for VPN traffic exiting via this interface
        iptables -t nat -C POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE

        echo "routing-init: table $table_id → default via $gateway dev $iface"
        table_id=$((table_id + 1))
    done
    unset IFS
fi

# Apply persistent per-client exit routes
if [ -f "$ROUTES_FILE" ]; then
    while IFS=' ' read -r client_ip table_id; do
        [ -z "$client_ip" ] && continue
        [ "${client_ip#\#}" != "$client_ip" ] && continue
        ip rule add from "$client_ip" lookup "$table_id" 2>/dev/null || true
        echo "routing-init: rule $client_ip → table $table_id"
    done < "$ROUTES_FILE"
fi

exec "$@"