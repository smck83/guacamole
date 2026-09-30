# Turnkey Apache Guacamole: guacd + web app + embedded PostgreSQL in one image.
#
# Nothing upstream is patched. The two official Apache images for the same
# release are used as build stages and merged:
#
#   guacamole/guacd      Alpine, native guacd + protocol libraries  -> base
#   guacamole/guacamole  Java web app, Tomcat, all extensions,
#                        JDBC drivers, SQL schemas, env-var tooling -> copied in
#
# Bumping GUAC_VERSION is all that is needed to follow a new Apache release.

ARG GUAC_VERSION=1.6.0

FROM guacamole/guacamole:${GUAC_VERSION} AS client

FROM guacamole/guacd:${GUAC_VERSION}

ARG GUAC_VERSION
USER root

# The guacd image pins its Alpine release (3.18 as of 1.6.0), so package
# versions here track whatever upstream builds guacd on.
RUN apk add --no-cache \
        bash \
        mariadb-client \
        openjdk17-jre-headless \
        postgresql15 \
        postgresql15-client \
        su-exec \
        tini \
        tzdata \
        xmlstarlet \
    && addgroup -g 1001 -S guacamole \
    && adduser -u 1001 -S -D -G guacamole -h /home/guacamole -s /sbin/nologin guacamole

COPY --from=client /usr/local/tomcat /usr/local/tomcat
COPY --from=client /opt/guacamole/ /opt/guacamole/
COPY rootfs/ /

# Requires the 1.6.0+ upstream image layout (older releases used a different
# entrypoint and did not ship extensions/ or environment/).
RUN test -f /opt/guacamole/bin/entrypoint.sh \
    && test -d /opt/guacamole/environment \
    && test -f /opt/guacamole/extensions/guacamole-auth-jdbc/postgresql/schema/001-create-schema.sql \
    || { echo "GUAC_VERSION ${GUAC_VERSION} is not supported (1.6.0 or later required)" >&2; exit 1; }

# Strip CRLF in case the repo was checked out on Windows without .gitattributes
RUN sed -i 's/\r$//' /opt/turnkey/*.sh \
    && chmod 755 /opt/turnkey/*.sh

ENV GUAC_VERSION=${GUAC_VERSION} \
    JAVA_HOME=/usr/lib/jvm/default-jvm \
    CATALINA_HOME=/usr/local/tomcat \
    PATH=/usr/local/tomcat/bin:/usr/lib/jvm/default-jvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    WEBAPP_CONTEXT=ROOT \
    BAN_ENABLED=true \
    ENABLE_FILE_ENVIRONMENT_PROPERTIES=true \
    TZ=UTC

VOLUME /data
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD /opt/turnkey/healthcheck.sh

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/opt/turnkey/start.sh"]

LABEL org.opencontainers.image.title="guacamole-turnkey" \
      org.opencontainers.image.description="Single-container Apache Guacamole with embedded PostgreSQL" \
      org.opencontainers.image.version="${GUAC_VERSION}" \
      org.opencontainers.image.licenses="Apache-2.0"
