# xt-ndpi-dkms — Debian/DKMS packaging for the nDPI `xt_ndpi` kernel module

Builds a `.deb` that ships the `xt_ndpi` netfilter module as **DKMS source**.
DKMS compiles the module against the running kernel on install and
**automatically rebuilds it on every kernel upgrade** (via the standard
`/etc/kernel/postinst.d/dkms` hook), so the module survives reboots without
the manual `rebuild` step the `setup-host/ndpi-setup.sh` script needs.

This packages **only the kernel module**. The iptables userspace extension
(`libxt_ndpi.so`, the `-m ndpi` match) is not included here.

## Build (Docker Compose — nothing installed on the host)

```bash
docker compose run --rm --build build
# -> ./artifacts/xt-ndpi-dkms_<version>_all.deb
```

The `.deb` is built inside a clean Ubuntu 24.04 image (see `Dockerfile`) and
copied to `./artifacts/`. The module is **not** compiled at package-build time —
only source is staged — so the build needs no kernel headers. `--build`
rebuilds the image (and thus the `.deb`); it's required whenever `NDPI_REF`,
`debian/`, or the Dockerfile changes.

Override the source revision without editing files:

```bash
NDPI_REF=4.12 docker compose run --rm --build build   # tag or commit
```

The default revision is pinned in `./NDPI_REF`.

## Install (on each target host)

```bash
sudo apt install ./xt-ndpi-dkms_<version>_all.deb
```

DKMS builds `xt_ndpi` for the current kernel during install. Pulls in `dkms`,
`build-essential`, and kernel headers as dependencies. To load it:

```bash
sudo modprobe xt_ndpi
```

## Verify

```bash
dkms status xt-ndpi          # should show: installed, for your kernel
modinfo xt_ndpi              # filename under /lib/modules/<kver>/updates/dkms
lsmod | grep xt_ndpi
```

After a kernel upgrade, confirm it rebuilt automatically:

```bash
dkms status xt-ndpi          # should list the new kernel too
```

## How it's built

- `debian/xt-ndpi-dkms.dkms` — the `dkms.conf`. Runs
  `./configure --with-only-libndpi` (generates `ndpi_config.h`, no
  libpcap/flex/bison; uses the bundled gcrypt-light), then
  `make -C ndpi-netfilter/src modules KERNEL_DIR=$kernel_source_dir`.
- `debian/rules` — stages the pinned nDPI tree into
  `/usr/src/xt-ndpi-<version>/` and registers it with `dh_dkms`. No
  compilation happens at package-build time.
- `Dockerfile` — clones nDPI at `NDPI_REF`, runs `autogen.sh`, overlays
  `debian/`, and runs `dpkg-buildpackage` in a clean Ubuntu 24.04 image.
- `compose.yaml` — `docker compose run --rm --build build` builds the image
  and copies the `.deb` to `./artifacts/`.
- `NDPI_REF` — the pinned upstream revision (change it to bump nDPI; then
  bump `debian/changelog`).

## Pinning a new nDPI revision

1. Update `NDPI_REF`.
2. Add a `debian/changelog` entry (keep the version native, e.g.
   `4.13.0+gitYYYYMMDD`).
3. `docker compose run --rm --build build`.