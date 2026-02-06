#!/usr/bin/env bash
set -euo pipefail

SSH_HOST="${SSH_HOST:-vpnina001}"

AWG_LOCAL_PORT=51821
AWG_REMOTE_PORT=51821
WG_LOCAL_PORT=51831
WG_REMOTE_PORT=51831

usage() {
    local base_name
    base_name="$(basename "$0")"
    cat <<EOF
Usage: $base_name <start|stop|status> <awg|wg|all> [ssh-host]

Manage SSH tunnels to WireGuard admin panels.
Default ssh-host: $SSH_HOST

Services:
  awg    AmneziaWG panel (http://localhost:${AWG_LOCAL_PORT})
  wg     WireGuard panel (http://localhost:${WG_LOCAL_PORT})
  all    Both panels

Commands:
  start    Open the tunnel(s)
  stop     Close the tunnel(s)
  status   Check if the tunnel(s) are running

Examples:
  $base_name start all
  $base_name start awg
  $base_name stop wg
  $base_name status all
  $base_name start all vpnina002
EOF
    exit 0
}

get_pid() {
    local local_port="$1" remote_port="$2"
    pgrep -f "ssh.*-L.*${local_port}:127.0.0.1:${remote_port}.*${SSH_HOST}" 2>/dev/null || true
}

do_start_one() {
    local name="$1" local_port="$2" remote_port="$3"
    local pid
    pid=$(get_pid "$local_port" "$remote_port")
    if [[ -n "$pid" ]]; then
        echo "$name: already running (pid $pid)"
        echo "  Panel: http://localhost:${local_port}"
        return
    fi

    ssh -f -N -L "${local_port}:127.0.0.1:${remote_port}" "$SSH_HOST" \
        -o ExitOnForwardFailure=yes

    echo "$name: tunnel opened"
    echo "  Panel: http://localhost:${local_port}"
}

do_stop_one() {
    local name="$1" local_port="$2" remote_port="$3"
    local pid
    pid=$(get_pid "$local_port" "$remote_port")
    if [[ -z "$pid" ]]; then
        echo "$name: not running"
        return
    fi

    kill "$pid"
    echo "$name: tunnel closed"
}

do_status_one() {
    local name="$1" local_port="$2" remote_port="$3"
    local pid
    pid=$(get_pid "$local_port" "$remote_port")
    if [[ -n "$pid" ]]; then
        echo "$name: running (pid $pid)"
        echo "  Panel: http://localhost:${local_port}"
    else
        echo "$name: not running"
    fi
}

run_for() {
    local action="$1" service="$2"
    case "$service" in
        awg) "${action}_one" "AmneziaWG" "$AWG_LOCAL_PORT" "$AWG_REMOTE_PORT" ;;
        wg)  "${action}_one" "WireGuard" "$WG_LOCAL_PORT" "$WG_REMOTE_PORT" ;;
        all)
            "${action}_one" "AmneziaWG" "$AWG_LOCAL_PORT" "$AWG_REMOTE_PORT"
            "${action}_one" "WireGuard" "$WG_LOCAL_PORT" "$WG_REMOTE_PORT"
            ;;
        *)   usage ;;
    esac
}

CMD="${1:-}"
SERVICE="${2:-}"
if [[ -n "${3:-}" ]]; then
    SSH_HOST="$3"
fi

case "$CMD" in
    start)  run_for do_start "$SERVICE" ;;
    stop)   run_for do_stop "$SERVICE" ;;
    status) run_for do_status "$SERVICE" ;;
    *)      usage ;;
esac