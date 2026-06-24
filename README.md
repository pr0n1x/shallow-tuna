# WireGuard VPN with Multi-IP Exit Routing

Deploy WireGuard and AmneziaWG VPN servers with per-client exit IP routing.

## Features

- **amnezia-wg-easy** — AmneziaWG (obfuscated WireGuard) with web UI
- **wg-easy** — Standard WireGuard with web UI
- **Multi-IP exit routing** — Route different clients through different external IPs
- **Persistent client assignments** — Survive container restarts
- **Automatic host SNAT** — `host-routing` service manages iptables rules via Docker Compose
- **DPI filtering (nDPI)** — Drop BitTorrent (or other nDPI-classified protocols)
  **per-exit**, via the `xt_ndpi` kernel module + an `xt-ndpi-rules` Compose service

## Prerequisites

- Docker and Docker Compose
- Multiple external IPs on the host (for multi-IP routing)
- SSH access for admin panel tunneling

## Quick Start

### 1. Clone and configure

```bash
git clone <repo>
cp .env.example .env
```

Edit `.env`:

```bash
# Your server's external IP (for client configs)
WG_HOST=1.2.3.4

# Generate password hash for AmneziaWG admin panel
docker run --rm ghcr.io/w0rng/amnezia-wg-easy wgpw 'your-password'
AWG_PASSWORD_HASH=<paste-hash-here>

# Custom AmneziaWG port (optional, default 51820)
# AWG_PORT=3127

# Multi-IP routing: gateway:external_ip pairs
# Tables auto-assigned: 100, 101, 102...
EXIT_ROUTES=172.100.0.1:1.2.3.4,172.101.0.1:2.3.4.5
```

### 2. Configure additional IPs on the host

Add secondary IP to your network interface. Example for netplan (`/etc/netplan/01-netcfg.yaml`):

```yaml
network:
  version: 2
  ethernets:
    eth0:
      addresses:
        - "1.2.3.4/24"
        - "2.3.4.5/24"
      routes:
        - to: default
          via: 1.2.3.1
```

Apply: `sudo netplan apply`

### 3. Start containers

```bash
docker compose up -d
```

The `host-routing` service automatically attaches SNAT rules and detaches them on `docker compose down`.

### 4. Access admin panels

Admin panels are bound to localhost. Use SSH tunnels:

```bash
# AmneziaWG (port 51821)
ssh -L 51821:127.0.0.1:51821 user@server

# wg-easy (port 51831)
ssh -L 51831:127.0.0.1:51831 user@server
```

Then open:
- http://localhost:51821 — AmneziaWG
- http://localhost:51831 — WireGuard

## Multi-IP Exit Routing

### How it works

1. Docker networks `exit1` and `exit2` have subnets `172.100.0.0/24` and `172.101.0.0/24`
2. `wg-easy/routing-init.sh` creates routing tables inside containers (100, 101, ...)
3. `host-routing` service adds SNAT rules on the host to map subnets to external IPs
4. Per-client routing rules send traffic through specific tables

### Assign a client to exit IP

```bash
# Route client 10.8.0.3 through exit2 network
./assign-exit.sh wg-easy add 10.8.0.3 exit2

# Remove assignment
./assign-exit.sh wg-easy remove 10.8.0.3

# List available networks and current assignments
./assign-exit.sh wg-easy list
```

### Check current SNAT rules

```bash
docker compose exec host-routing sh /app/manage.sh status
```

## DPI filtering — block BitTorrent (and other protocols)

Drop traffic that **nDPI** deep-packet-inspection classifies as a given protocol
(BitTorrent by default) on the VPN exits — this catches **encrypted (MSE/PE)**
torrents and DHT/uTP, not just plaintext or well-known ports. Blocking is
**per-exit**: you choose which exits enforce it.

### How it works

1. **`xt-ndpi-dkms`** — the out-of-tree `xt_ndpi` netfilter kernel module,
   installed on the host via DKMS (auto-rebuilt on kernel upgrades). It provides
   the iptables `-m ndpi` match.
2. **`xt-ndpi-rules`** — a Compose service (host netns, mirrors `host-routing`)
   that applies `-m ndpi --proto <p> -j DROP` to Docker's **`DOCKER-USER`** chain,
   scoped to the chosen exit subnets, and re-applies on Docker restart. It bundles
   the userspace `libxt_ndpi.so` match.

Because VPN traffic is MASQUERADEd to its exit subnet *inside* the container, the
source seen on `DOCKER-USER` is the exit network — so a source-scoped rule acts as
a **per-exit on/off switch**. (`DOCKER-USER` is in `FORWARD`, before host SNAT, so
this composes cleanly with `host-routing`.)

### Setup

```bash
# 1. Build the .deb packages (Docker; no root)
./setup-host/ndpi-setup.sh build

# 2. Install the host kernel module (DKMS builds xt_ndpi for the running kernel)
sudo ./setup-host/ndpi-setup.sh install

# 3. Bring up the rule service (or `docker compose up -d` the whole stack)
docker compose up -d --build xt-ndpi-rules
```

> The `xt-ndpi-rules` image bundles `libxt_ndpi.so` from the `.deb`s, so run
> step 1 (`ndpi-setup.sh build`) before any `docker compose up -d` — otherwise
> that service's image build fails on the missing package.

### Configure

On the `xt-ndpi-rules` service in `docker-compose.yml` (or via `.env`):

```yaml
environment:
  - NDPI_DROP=bittorrent                       # protocols (comma list)
  - NDPI_CHAIN=DOCKER-USER                      # chain to apply rules to
  - NDPI_SOURCE=172.100.0.0/24,172.101.0.0/24   # which exits to enforce on
```

Choose which exits enforce blocking (exit1 = `172.100.0.0/24`, exit2 = `172.101.0.0/24`):

- both exits → `NDPI_SOURCE=172.100.0.0/24,172.101.0.0/24`
- only exit1 → `NDPI_SOURCE=172.100.0.0/24` (exit2 left open)
- all forwarded traffic → `NDPI_SOURCE=` (empty)

Re-apply with `docker compose up -d xt-ndpi-rules`.

### Verify

```bash
./xt-ndpi-rules/verify.sh        # end-to-end checks (no sudo, all via docker compose)
docker logs xt-ndpi-rules        # "dropping [bittorrent] from [...] on DOCKER-USER"
docker exec xt-ndpi-rules iptables-legacy -nvL DOCKER-USER | grep ndpi   # live counters
```

See [`setup-host/ndpi.md`](setup-host/ndpi.md) for the full details.

## File Structure

```
.env                          # Configuration (not committed)
.env.example                  # Example configuration
docker-compose.yml            # Container definitions
wg-easy/routing-init.sh       # Container entrypoint for routing tables
host-routing/                 # Host SNAT rule management (Compose service)
  Dockerfile
  daemon.sh                   # Lifecycle: attach on start, detach on stop
  manage.sh                   # attach/detach/status commands
xt-ndpi-rules/                # nDPI DROP rules on DOCKER-USER (Compose service)
  Dockerfile                  # bundles libxt_ndpi.so
  daemon.sh                   # Lifecycle: attach on start, detach on stop
  manage.sh                   # config-driven, per-exit, backend auto-detect
  verify.sh                   # end-to-end verification (via docker compose)
ndpi/                         # nDPI .deb packaging (xt-ndpi-dkms + iptables ext)
  debian/                     # built with Docker Compose into ndpi/artifacts
assign-exit.sh                # Per-client exit IP assignment
setup-host/                   # Host setup scripts
  docker-setup.sh
  wireguard-setup.sh
  amneziawg-setup.sh
  ndpi-setup.sh               # build/install the xt_ndpi DKMS kernel module
  ndpi.md                     # DPI filtering docs
```

## Ports

| Service              | Port           | Protocol | Description          |
|----------------------|----------------|----------|----------------------|
| awg-easy (AmneziaWG) | AWG_PORT/udp  | WG       | VPN tunnel           |
| awg-easy (AmneziaWG) | 51821/tcp     | HTTP     | Admin panel (local)  |
| wg-easy  (WireGuard) | WG_PORT/udp   | WG       | VPN tunnel           |
| wg-easy  (WireGuard) | 51831/tcp     | HTTP     | Admin panel (local)  |

## Troubleshooting

### VPN connected but no internet

1. Check container logs: `docker compose logs awg-easy`
2. Verify routing tables: `docker exec awg-easy ip route show table 100`
3. Check SNAT rules: `docker compose exec host-routing sh /app/manage.sh status`

### Client not using expected exit IP

1. Verify assignment: `./assign-exit.sh awg-easy list`
2. Check rule inside container: `docker exec awg-easy ip rule show`
3. Toggle VPN on client to force new connection