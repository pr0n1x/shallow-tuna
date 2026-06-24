#!/usr/bin/env bash
set -uo pipefail

# End-to-end verification of the xt-ndpi-rules service. Exercises the actual
# committed code (manage.sh + the built image + the host xt_ndpi module) and
# reports PASS/FAIL for three claims:
#
#   1. Backend auto-detection: the service picks the iptables backend that
#      actually owns DOCKER-USER and applies the rule there.
#   2. Loud failure: a non-existent chain makes the service exit non-zero with
#      an error (no silent no-op).
#   3. Blocking proof: a real BitTorrent peer-wire handshake is delivered with
#      no rule, and DROPPED once the service attaches its rule.
#
# Requirements (Ubuntu 24.04 TEST host — it adds/removes transient iptables
# rules):
#   - docker + python3
#   - xt_ndpi loaded:   sudo ./setup-host/ndpi-setup.sh install
#   - packages built:   ./setup-host/ndpi-setup.sh build
#
# Usage:
#   ./xt-ndpi-rules/verify.sh                 # run all checks
#   ./xt-ndpi-rules/verify.sh 2>&1 | tee verify.log
#
# Exit status: 0 if every check passes, 1 otherwise.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_DIR="$(cd "$HERE/.." && pwd)"          # wg-easy/
CONTAINER="xt-ndpi-rules-verify"
TEST_PORT=6881

PASS=0 FAIL=0
ok()  { echo "  [PASS] $*"; PASS=$((PASS+1)); }
no()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
hdr() { echo; echo "=== $* ==="; }

# sudo only if not already root.
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# Scratch dir: a dedicated subfolder under ~/tmp (never loose files in /tmp).
TMPBASE="${TMPDIR:-$HOME/tmp}"; mkdir -p "$TMPBASE"
WORK="$(mktemp -d "$TMPBASE/xt-ndpi-verify.XXXXXX")"

cleanup() {
    $SUDO docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

svc_run() {   # <chain>  -> start the service container against a chain
    $SUDO docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    $SUDO docker run -d --name "$CONTAINER" --network host \
        --cap-add NET_ADMIN --cap-add SYS_MODULE \
        -v /lib/modules:/lib/modules:ro \
        -v "$HERE/manage.sh:/app/manage.sh:ro" \
        -v "$HERE/daemon.sh:/app/daemon.sh:ro" \
        -e NDPI_CHAIN="$1" -e NDPI_DROP=bittorrent \
        --restart=no "$IMAGE" >/dev/null
}
svc_log() { $SUDO docker logs "$CONTAINER" 2>&1; }

owner_backend() {   # <chain> -> legacy | nft | none  (independent of manage.sh)
    $SUDO iptables-legacy -n -L "$1" >/dev/null 2>&1 && { echo legacy; return; }
    $SUDO iptables-nft    -n -L "$1" >/dev/null 2>&1 && { echo nft;    return; }
    echo none
}

# Deterministic BitTorrent peer-wire handshake over loopback. Prints
# DELIVERED (server received the bytes) or BLOCKED (drop / timeout).
handshake_probe() {
    python3 - "$TEST_PORT" <<'PY'
import socket, threading, time, sys
PORT = int(sys.argv[1])
HS = b"\x13BitTorrent protocol" + b"\x00"*48
def server(out):
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", PORT)); s.listen(1); s.settimeout(8)
    try:
        c, _ = s.accept(); c.settimeout(5); out.append(c.recv(100))
    except Exception as e:
        out.append(e)
    finally:
        s.close()
out = []; t = threading.Thread(target=server, args=(out,)); t.start(); time.sleep(0.5)
c = socket.socket(); c.settimeout(5)
try:
    c.connect(("127.0.0.1", PORT)); c.sendall(HS)
except Exception:
    pass
t.join()
v = out[0] if out else None
print("DELIVERED" if isinstance(v, (bytes, bytearray)) and v else "BLOCKED")
PY
}

# ---------------------------------------------------------------------------
echo "xt-ndpi-rules verification — $(date)"
echo "compose dir: $COMPOSE_DIR"

hdr "Preconditions"
command -v docker  >/dev/null || { echo "missing: docker";  exit 2; }
command -v python3 >/dev/null || { echo "missing: python3"; exit 2; }
if lsmod | grep -q '^xt_ndpi'; then ok "xt_ndpi kernel module loaded"
else no "xt_ndpi not loaded (sudo ./setup-host/ndpi-setup.sh install)"; exit 2; fi

if ! ls "$COMPOSE_DIR"/ndpi/artifacts/xt-ndpi-iptables_*.deb >/dev/null 2>&1; then
    echo "  iptables .deb missing — run: ./setup-host/ndpi-setup.sh build"; exit 2
fi
echo "  building service image..."
( cd "$COMPOSE_DIR" && $SUDO docker compose build xt-ndpi-rules ) >/tmp/.xtr-build 2>&1 \
    && ok "service image built" || { no "image build failed"; cat /tmp/.xtr-build; exit 2; }
IMAGE="$( cd "$COMPOSE_DIR" && $SUDO docker compose config --images xt-ndpi-rules 2>/dev/null | head -1 )"
IMAGE="${IMAGE:-$(basename "$COMPOSE_DIR")-xt-ndpi-rules}"
echo "  image: $IMAGE"

# --- 1. backend auto-detection on DOCKER-USER ------------------------------
hdr "1. Backend auto-detection (DOCKER-USER)"
BE="$(owner_backend DOCKER-USER)"
if [ "$BE" = none ]; then
    echo "  DOCKER-USER absent (is dockerd running?) — skipping this check"
else
    echo "  DOCKER-USER is owned by: $BE backend"
    svc_run DOCKER-USER; sleep 3
    LOG="$(svc_log)"
    echo "$LOG" | sed 's/^/    log| /'
    echo "$LOG" | grep -q "chain DOCKER-USER -> $BE backend" \
        && ok "service detected the $BE backend" \
        || no "service did not report the $BE backend"
    $SUDO "iptables-$BE" -n -L DOCKER-USER 2>/dev/null | grep -qi 'ndpi.*bittorrent' \
        && ok "rule present in $BE DOCKER-USER" \
        || no "rule NOT found in $BE DOCKER-USER"
    $SUDO docker stop "$CONTAINER" >/dev/null 2>&1; sleep 2
    $SUDO "iptables-$BE" -n -L DOCKER-USER 2>/dev/null | grep -qi 'ndpi.*bittorrent' \
        && no "rule still present after stop (detach failed)" \
        || ok "rule detached on container stop"
fi

# --- 2. loud failure on a non-existent chain -------------------------------
hdr "2. Loud failure on a non-existent chain"
svc_run NOPE-CHAIN-XYZ; sleep 3
STATUS="$($SUDO docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)"
CODE="$($SUDO docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null)"
LOG="$(svc_log)"
echo "$LOG" | sed 's/^/    log| /'
echo "  container: status=$STATUS exit=$CODE"
{ [ "$STATUS" = exited ] && [ "$CODE" != 0 ]; } \
    && ok "container exited non-zero (failed loudly)" \
    || no "container did not fail loudly"
echo "$LOG" | grep -qi "ERROR: chain 'NOPE-CHAIN-XYZ' not found" \
    && ok "clear error message emitted" \
    || no "no clear error message"

# --- 3. blocking proof on OUTPUT (control vs blocked) ----------------------
hdr "3. Blocking proof (BitTorrent handshake on OUTPUT)"
cleanup; sleep 1
# ensure no leftover rule on OUTPUT for the control run
$SUDO iptables -D OUTPUT -m ndpi --proto bittorrent -j DROP 2>/dev/null || true
CTRL="$(handshake_probe)"
echo "  control (no rule):  $CTRL"
[ "$CTRL" = DELIVERED ] && ok "handshake delivered without a rule" \
                        || no "handshake not delivered in control (test setup issue?)"
svc_run OUTPUT; sleep 3
$SUDO iptables -Z OUTPUT 2>/dev/null || true
BLK="$(handshake_probe)"
echo "  with rule:          $BLK"
[ "$BLK" = BLOCKED ] && ok "handshake blocked with the rule" \
                     || no "handshake NOT blocked"
CNT="$($SUDO iptables -nvL OUTPUT 2>/dev/null | awk '/ndpi.*bittorrent/{print $1}' | head -1)"
echo "  DROP counter (pkts): ${CNT:-0}"
[ "${CNT:-0}" -gt 0 ] 2>/dev/null && ok "DROP counter incremented (xt_ndpi matched)" \
                                  || no "DROP counter did not increment"
$SUDO docker stop "$CONTAINER" >/dev/null 2>&1 || true

# --- summary ---------------------------------------------------------------
hdr "Summary"
echo "  PASS: $PASS    FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && { echo "  RESULT: OK"; exit 0; } || { echo "  RESULT: FAILED"; exit 1; }