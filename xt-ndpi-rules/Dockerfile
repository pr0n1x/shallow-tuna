# nDPI rule engine container. Applies "-m ndpi --proto <p> -j DROP" rules to the
# host's DOCKER-USER chain (network_mode: host). Ubuntu 24.04 so the bundled
# libxt_ndpi.so (built on noble in the xt-ndpi-iptables package) loads cleanly.
#
# Build context is the compose project dir (wg-easy/), so we can pull the
# prebuilt .deb from ndpi/artifacts. Run `ndpi-setup.sh build` first.
#
# manage.sh / daemon.sh are bind-mounted at runtime (see docker-compose.yml).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        iptables kmod \
    && update-alternatives --set iptables  /usr/sbin/iptables-legacy \
    && update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy \
    && rm -rf /var/lib/apt/lists/*

# Bundle libxt_ndpi.so (the "-m ndpi" match) by extracting the prebuilt package
# into the image — no dependency resolution, no kernel module here.
COPY ndpi/artifacts/xt-ndpi-iptables_*.deb /tmp/
RUN dpkg-deb -x /tmp/xt-ndpi-iptables_*.deb / && rm -f /tmp/*.deb \
    && test -e /usr/lib/*/xtables/libxt_ndpi.so

ENTRYPOINT ["sh", "/app/daemon.sh"]