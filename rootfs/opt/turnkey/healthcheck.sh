#!/bin/sh
# Healthy when guacd accepts connections and the web app answers. Mirrors the
# WEBAPP_CONTEXT normalisation in start.sh ("/access/remote/" -> access/remote).
ctx="$(echo "${WEBAPP_CONTEXT:-ROOT}" | sed 's|^/||; s|/$||; s|#|/|g')"
case "$ctx" in ""|ROOT) path="/" ;; *) path="/$ctx/" ;; esac
nc -z 127.0.0.1 4822 && wget -q -O /dev/null "http://127.0.0.1:8080${path}"
