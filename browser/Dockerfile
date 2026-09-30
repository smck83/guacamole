# Browser host for Guacamole "URL connections".
#
# An xrdp server whose sessions run only a kiosk Chromium. Guacamole reaches it
# with an ordinary RDP connection whose "Initial program" is:
#
#     open-url https://192.168.89.1
#
# Every connection gets its own X session and a throwaway browser profile,
# which is deleted when the tab/connection closes.

FROM debian:bookworm-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        chromium \
        dbus-x11 \
        fonts-dejavu-core \
        fonts-liberation \
        fonts-noto-color-emoji \
        jq \
        ssl-cert \
        tini \
        xorgxrdp \
        xrdp \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/sh browser \
    && adduser xrdp ssl-cert >/dev/null

COPY rootfs/ /
RUN sed -i 's/\r$//' /usr/local/bin/* \
    && chmod 755 /usr/local/bin/*

EXPOSE 3389

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/usr/local/bin/browser-entrypoint"]
