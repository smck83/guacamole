# Guacamole Turnkey

Apache Guacamole in **one container**, with no SQL scripts to run and no
separate database to set up. It is meant for a homelab or a small business with
a dozen or so admins.

```bash
docker run -d --name guacamole -p 8080:8080 -v guacamole-data:/data \
  --restart unless-stopped ghcr.io/smck83/guacamole:latest
docker logs guacamole | grep -A2 "administrator account"
```

Open `http://<host>:8080/` and sign in with the printed credentials.

## What's inside

| Component | Source | Notes |
|---|---|---|
| guacd | official `guacamole/guacd` image | listens on `127.0.0.1:4822` only |
| Web app + Tomcat + all extensions | official `guacamole/guacamole` image | started by the unmodified upstream entrypoint |
| PostgreSQL 15 | Alpine package | embedded; skipped when you point at an external DB |

The Dockerfile uses Apache's own release images as build stages and merges
them. None of the upstream code is patched. A new Apache release only needs a
different `GUAC_VERSION`, and CI does that for you (see below).

On first boot the container:

1. creates a PostgreSQL cluster in `/data/postgres` with a random DB password
2. loads the Guacamole schema
3. replaces the well-known `guacadmin/guacadmin` login with a random password
   (or with `GUACADMIN_USERNAME` / `GUACADMIN_PASSWORD` if you set them)

On later boots it applies Apache's schema upgrade scripts when the image is
newer than the database.

## Data volume (`/data`)

| Path | Contents |
|---|---|
| `postgres/` | embedded database |
| `guacamole/` | optional `GUACAMOLE_HOME` overlay: `guacamole.properties`, `extensions/`, `lib/`, `logback.xml`, branding jars |
| `recordings/` | session recordings (set a connection's *Recording path* to `${HISTORY_PATH}/${HISTORY_UUID}`); playable from the History page |
| `drive/` | RDP drive redirection / file transfer (e.g. drive path `/data/drive/${GUAC_USERNAME}`) |
| `.secrets/` | generated DB password and initial admin password |

## Feature toggles

These are the standard upstream Guacamole variables. Any `PREFIX_*` variable
turns an extension on. `PREFIX_ENABLED=true|false` turns it on or off
explicitly. Every extension property maps to an environment variable, e.g.
`totp-issuer` → `TOTP_ISSUER`. Any variable also accepts a `_FILE` suffix to
read the value from a secret file.

| Feature | Enable with | Default |
|---|---|---|
| TOTP two-factor | `TOTP_ENABLED=true` | off |
| Brute-force ban | `BAN_ENABLED=true` | **on** |
| Recording playback in history | `RECORDING_ENABLED=true` | **on** |
| Duo | `DUO_API_HOSTNAME`, `DUO_CLIENT_ID`, … | off |
| LDAP / Active Directory | `LDAP_HOSTNAME`, `LDAP_USER_BASE_DN`, … | off |
| OpenID Connect (Entra ID, Authentik, Keycloak …) | `OPENID_AUTHORIZATION_ENDPOINT`, … | off |
| SAML | `SAML_IDP_METADATA_URL`, … | off |
| CAS | `CAS_AUTHORIZATION_ENDPOINT`, … | off |
| Header auth (behind an auth proxy) | `HTTP_AUTH_HEADER=REMOTE_USER` | off |
| Quick Connect | `QUICKCONNECT_ENABLED=true` | off |
| Login restrictions (time / IP) | `RESTRICT_ENABLED=true` | off |
| Display statistics | `DISPLAY_STATISTICS_ENABLED=true` | off |
| Keeper Secrets Manager vault | `KSM_CONFIG=…` | off |
| Trust `X-Forwarded-For` from a reverse proxy | `REMOTE_IP_VALVE_ENABLED=true` | off |

See the [Guacamole manual](https://guacamole.apache.org/doc/gug/) for each
extension's properties.

## Other settings

| Variable | Default | |
|---|---|---|
| `GUACADMIN_USERNAME` / `GUACADMIN_PASSWORD` | `guacadmin` / random | first boot only |
| `WEBAPP_CONTEXT` | `ROOT` (served at `/`) | URL path, e.g. `remote` → `/remote/`, `access/remote` → `/access/remote/`, `guacamole` for the upstream default |
| `GUACD_LOG_LEVEL` | `info` | |
| `TZ` | `UTC` | |
| `DB_MODE` | `auto` | `embedded`, `postgresql`, `mysql`, `sqlserver`, `none` |
| `DB_AUTO_INIT` | `true` | create/upgrade schema on an external DB |
| `DB_SCHEMA_VERSION` | – | adopt an existing DB of this older version and upgrade it |
| `DB_WAIT_SECONDS` | `60` | how long to wait for the database at startup |

## External database

If you set `POSTGRESQL_HOSTNAME` (or `MYSQL_HOSTNAME`), the embedded database
is not started. The database and user must already exist. The container
creates the schema if it is empty and upgrades it on later versions:

```yaml
environment:
  POSTGRESQL_HOSTNAME: db
  POSTGRESQL_DATABASE: guacamole_db
  POSTGRESQL_USERNAME: guacamole
  POSTGRESQL_PASSWORD_FILE: /run/secrets/db_password
```

SQL Server works too (`SQLSERVER_*`), but you must load its schema manually
with `/opt/guacamole/bin/initdb.sh --sqlserver`.

**Moving an existing multi-container install:** point the container at your
current database. If the database is older than the image, set
`DB_SCHEMA_VERSION=<old version>` once so the upgrade scripts run.

## URL connections (internal web UIs)

Guacamole streams remote screens; it can't show a web page by itself. The
optional `guacamole-browser` container is a small RDP server whose sessions run
nothing but a kiosk Chromium. That lets a Guacamole connection open a web UI
such as `https://192.168.89.1` (router, NAS, iLO/iDRAC, printer) from anywhere,
without exposing that UI.

```bash
BROWSER_PASSWORD=$(openssl rand -hex 16) docker compose --profile browser up -d
```

In Guacamole, add an **RDP** connection:

| Field | Value |
|---|---|
| Hostname / Port | `browser` / `3389` |
| Username / Password | `browser` / your `BROWSER_PASSWORD` |
| Security mode | Any, with **Ignore server certificate** ticked |
| Resize method | Display update |
| **Initial program** | `open-url https://192.168.89.1` |

Quote URLs that contain `&`, `;` or spaces: `open-url 'https://nas/?a=1&b=2'`.

How it behaves:

- **One session per connection.** Each connection gets its own X session and
  a fresh, throwaway Chromium profile. Cookies and logins are gone when the
  connection closes. If you just go back to Guacamole's home screen, the
  session is kept open in the background. When you close it, it is killed
  after about 60 seconds and its profile is deleted.
- **Hardened by default.** Password saving, autofill, sign-in, sync,
  downloads and developer tools are all off.
- **Sandboxed.** Chromium's own per-tab sandbox is on when the container has
  `security_opt: [seccomp=unconfined]` (the compose file sets this). Without
  it, the browser falls back to `--no-sandbox` and logs a warning.
- **Private.** The browser container publishes no ports. Only Guacamole
  reaches it, over the compose network.

| Variable | Default | |
|---|---|---|
| `BROWSER_PASSWORD` / `_FILE` | – (required) | RDP login used by Guacamole connections |
| `BROWSER_MODE` | `kiosk` | `kiosk` (no address bar), `app` (minimal window), `full` (normal browser) |
| `BROWSER_IGNORE_CERT_ERRORS` | `false` | skip the warning for self-signed router/NAS certificates |
| `BROWSER_ALLOWED_URLS` | – | comma-separated allowlist, e.g. `192.168.89.1,nas.home.arpa,home.arpa` (hosts or domains, [Chromium URL-filter format](https://support.google.com/chrome/a/answer/9942583) — no CIDR ranges); everything else blocked |
| `BROWSER_SANDBOX` | `auto` | `on` / `off` to force |

Security note: anyone allowed to *edit* connections controls the initial
program, which runs as the unprivileged `browser` user inside this container.
In practice that is only Guacamole admins.

## Backup & restore

```bash
# backup (online, consistent)
docker exec guacamole pg_dump -h /run/postgresql -U postgres -Fc guacamole_db > guacamole.dump

# restore into a fresh container
docker exec -i guacamole pg_restore -h /run/postgresql -U postgres -d guacamole_db --clean < guacamole.dump
```

Upstream pins the Alpine release that guacd is built on, and the embedded
PostgreSQL major version comes with it. If a future image ships a newer
PostgreSQL major version, the container refuses to start on the old data
directory and tells you so. To move across, back up with the old image and
restore into the new one.

## Updates / CI

`.github/workflows/build.yml`:

- **Daily**: finds the latest stable tag of `apache/guacamole-server`. When
  Apache's official images for that tag are on Docker Hub and we haven't built
  it yet, it builds, smoke-tests and publishes `:<version>`, `:<major.minor>`
  and `:latest` for amd64 and arm64.
- **Weekly**: rebuilds to pick up Alpine security fixes.
- **Pull requests**: build and smoke test only.
- **Manual**: `workflow_dispatch` with an optional version.

`tests/smoke.sh <image>` boots the image, signs in through the REST API with
the generated password, and checks that the default password is rejected.
It then restarts the container with TOTP on and checks two things: the data
survived, and a two-factor challenge is presented.

## Why PostgreSQL rather than SQLite?

Guacamole's database layer is a set of MyBatis SQL mappers, one per dialect
(PostgreSQL, MySQL, SQL Server). SQLite support would mean keeping a fork of
that Java extension up to date with every release, which defeats the point of
tracking upstream automatically. An embedded PostgreSQL uses about 15 MB of RAM
at this scale. It runs the dialect upstream tests, and you never touch it.

Supports Guacamole **1.6.0 and later**.
