# WireGuard VPN with Multi-IP Exit Routing

Deploy WireGuard and AmneziaWG VPN servers with per-client exit IP routing.

## Features

- **wg-easy** — Standard WireGuard with web UI
- **amnezia-wg-easy** — AmneziaWG (obfuscated WireGuard) with web UI
- **Multi-IP exit routing** — Route different clients through different external IPs
- **Persistent client assignments** — Survive container restarts

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
AWG_HOST=1.2.3.4

# Generate password hash for AmneziaWG admin panel
docker run --rm ghcr.io/w0rng/amnezia-wg-easy wgpw 'your-password'
AWG_PASSWORD_HASH=<paste-hash-here>

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

### 4. Attach host SNAT rules

```bash
sudo ./host-routing.sh attach
```

> Run this after every `docker compose up` — Docker's NAT rules take priority otherwise.

### 5. Access admin panels

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
2. `routing-init.sh` creates routing tables inside containers (100, 101, ...)
3. `host-routing.sh` adds SNAT rules on the host to map subnets to external IPs
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
sudo ./host-routing.sh status
```

## File Structure

```
.env                 # Configuration (not committed)
.env.example         # Example configuration
docker-compose.yml   # Container definitions
routing-init.sh      # Container entrypoint for routing tables
host-routing.sh      # Host SNAT rule management
assign-exit.sh       # Per-client exit IP assignment
```

## Ports

| Service              | Port      | Protocol | Description          |
|----------------------|-----------|----------|----------------------|
| awg-easy (AmneziaWG) | 51820/udp | WG       | VPN tunnel           |
| awg-easy (AmneziaWG) | 51821/tcp | HTTP     | Admin panel (local)  |
| wg-easy  (WireGuard) | 51830/udp | WG       | VPN tunnel           |
| wg-easy  (WireGuard) | 51831/tcp | HTTP     | Admin panel (local)  |

## Troubleshooting

### VPN connected but no internet

1. Check container logs: `docker logs wg-easy`
2. Verify routing tables: `docker exec wg-easy ip route show table 100`
3. Check SNAT rules: `sudo ./host-routing.sh status`
4. Re-attach after compose restart: `sudo ./host-routing.sh attach`

### Client not using expected exit IP

1. Verify assignment: `./assign-exit.sh wg-easy list`
2. Check rule inside container: `docker exec wg-easy ip rule show`
3. Toggle VPN on client to force new connection
