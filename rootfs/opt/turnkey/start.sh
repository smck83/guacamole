#!/bin/bash
#
# Turnkey Guacamole entrypoint.
#
# Runs as root under tini, prepares /data, bootstraps the database (embedded
# PostgreSQL by default, or an external PostgreSQL/MySQL server), then starts
# and supervises three processes:
#
#   postgres  (embedded mode only, user "postgres")
#   guacd     (user "guacd", bound to 127.0.0.1:4822 only)
#   tomcat    (user "guacamole", via the unmodified upstream entrypoint)
#
# If any process exits, the others are stopped and the container exits so the
# Docker restart policy can take over.
#

set -euo pipefail

log()  { echo "[turnkey] $*"; }
warn() { echo "[turnkey] WARNING: $*" >&2; }
die()  { echo "[turnkey] ERROR: $*" >&2; exit 1; }

is_true() { [[ "${1,,}" =~ ^(1|true|yes|on)$ ]]; }

# Returns success if version $1 is strictly greater than version $2
version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# Random hex secret. Uses od rather than a tr|head pipeline so that SIGPIPE
# cannot trip pipefail.
gen_secret() { od -An -tx1 -N24 /dev/urandom | tr -d ' \n'; }

# Reads a value from VAR, or from the file named by VAR_FILE if set.
read_var() {
    local name="$1" file_var="${1}_FILE"
    if [ -n "${!file_var:-}" ]; then
        cat "${!file_var}"
    else
        printf '%s' "${!name:-}"
    fi
}

: "${GUAC_VERSION:?GUAC_VERSION must be set by the image}"
DATA_DIR="${DATA_DIR:-/data}"
SCHEMA_ROOT=/opt/guacamole/extensions/guacamole-auth-jdbc

###############################################################################
# Legacy variable names (mirrors upstream 010-migrate-legacy-variables.sh so
# that database mode detection below sees the same names upstream will use)
###############################################################################

while read -r v; do
    [ -n "$v" ] || continue
    new="POSTGRESQL_${v#POSTGRES_}"
    [ -n "${!new:-}" ] || export "$new=${!v}"
done < <(awk 'BEGIN{for(v in ENVIRON) print v}' | grep '^POSTGRES_' || true)
[ -z "${MYSQL_USER:-}" ] || export MYSQL_USERNAME="${MYSQL_USERNAME:-$MYSQL_USER}"

###############################################################################
# Defaults
###############################################################################

# Serve at http://host:8080/ rather than /guacamole/. Accepts "remote",
# "/remote/", "access/remote" etc.; Tomcat spells nested paths with '#'.
ctx="${WEBAPP_CONTEXT:-ROOT}"
ctx="${ctx#/}"; ctx="${ctx%/}"; ctx="${ctx//\//#}"
[ -n "$ctx" ] || ctx=ROOT
[[ "$ctx" =~ ^[A-Za-z0-9._~#-]+$ ]] || die "WEBAPP_CONTEXT '$WEBAPP_CONTEXT' contains unsupported characters"
export WEBAPP_CONTEXT="$ctx"

# GUACAMOLE_HOME is used by upstream as a *template* that gets overlaid onto a
# generated home, so users can drop extensions/, lib/, guacamole.properties,
# logback.xml, branding etc. into /data/guacamole.
export GUACAMOLE_HOME="$DATA_DIR/guacamole"

# guacd runs in this container and listens on loopback only
export GUACD_HOSTNAME=127.0.0.1
export GUACD_PORT=4822

# Session recordings live on the data volume and are viewable in the UI via the
# history-recording-storage extension (disable with RECORDING_ENABLED=false).
export RECORDING_SEARCH_PATH="${RECORDING_SEARCH_PATH:-$DATA_DIR/recordings}"

###############################################################################
# Data directory layout
###############################################################################

mkdir -p "$DATA_DIR" "$DATA_DIR/.secrets" "$GUACAMOLE_HOME"/{extensions,lib} \
         "$RECORDING_SEARCH_PATH" "$DATA_DIR/drive"

chmod 700 "$DATA_DIR/.secrets"

# guacamole.properties etc. may contain secrets: readable by tomcat only
chown root:guacamole "$GUACAMOLE_HOME" "$GUACAMOLE_HOME"/{extensions,lib}
chmod 750 "$GUACAMOLE_HOME" "$GUACAMOLE_HOME"/{extensions,lib}

# guacd writes recordings; setgid so that files inherit the guacamole group and
# tomcat can play them back
chown guacd:guacamole "$RECORDING_SEARCH_PATH"
chmod 2750 "$RECORDING_SEARCH_PATH"

# RDP drive redirection / SFTP scratch space for guacd
chown guacd:guacd "$DATA_DIR/drive"
chmod 750 "$DATA_DIR/drive"

###############################################################################
# Database mode
###############################################################################

DB_MODE="${DB_MODE:-auto}"
if [ "$DB_MODE" = "auto" ]; then
    if [ -n "${POSTGRESQL_HOSTNAME:-}" ]; then
        DB_MODE=postgresql
    elif [ -n "${MYSQL_HOSTNAME:-}" ]; then
        DB_MODE=mysql
    elif [ -n "${SQLSERVER_HOSTNAME:-}" ]; then
        DB_MODE=sqlserver
    else
        DB_MODE=embedded
    fi
fi
log "Guacamole $GUAC_VERSION, database mode: $DB_MODE"

# Stop anything we started if the container is asked to stop during startup
PG_PID=""
GUACD_PID=""
TOMCAT_PID=""

stop_all() {
    trap - TERM INT
    log "Shutting down..."
    [ -z "$TOMCAT_PID" ] || kill -TERM "$TOMCAT_PID" 2>/dev/null || true
    [ -z "$GUACD_PID" ]  || kill -TERM "$GUACD_PID"  2>/dev/null || true
    [ -z "$TOMCAT_PID" ] || wait "$TOMCAT_PID" 2>/dev/null || true
    [ -z "$GUACD_PID" ]  || wait "$GUACD_PID"  2>/dev/null || true
    # SIGINT = PostgreSQL "fast" shutdown: disconnect clients, checkpoint, exit
    [ -z "$PG_PID" ] || kill -INT "$PG_PID" 2>/dev/null || true
    [ -z "$PG_PID" ] || wait "$PG_PID" 2>/dev/null || true
    log "Stopped."
}
trap 'stop_all; exit 0' TERM INT

# db_exec: run SQL from stdin against the configured database. Extra args are
# passed through (psql -v name=value for PostgreSQL). Implemented per backend.
# db_query: run a single query and print the scalar result.

start_embedded_postgres() {
    local pgdata="$DATA_DIR/postgres"
    local image_major
    image_major="$(postgres --version | sed -E 's/.* ([0-9]+)(\.[0-9]+)*.*/\1/')"

    mkdir -p "$pgdata" /run/postgresql
    chown postgres:postgres "$pgdata" /run/postgresql
    chmod 700 "$pgdata"

    if [ ! -s "$pgdata/PG_VERSION" ]; then
        log "Initialising embedded PostgreSQL $image_major cluster in $pgdata"
        su-exec postgres initdb -D "$pgdata" -U postgres -E UTF8 --locale=C \
            --auth-local=trust --auth-host=scram-sha-256 >/dev/null
    fi

    local data_major
    data_major="$(cat "$pgdata/PG_VERSION")"
    if [ "$data_major" != "$image_major" ]; then
        die "Embedded database was created by PostgreSQL $data_major but this image ships PostgreSQL $image_major. Back up with the previous image (see README: 'Backup & restore'), then restore into this one."
    fi

    # Small footprint tuning: this is a dozen-admins deployment, not a cluster
    su-exec postgres postgres -D "$pgdata" \
        -c listen_addresses=127.0.0.1 \
        -c unix_socket_directories=/run/postgresql \
        -c max_connections=50 \
        -c shared_buffers=32MB \
        -c log_min_messages=warning \
        -c log_line_prefix='[postgres] ' &
    PG_PID=$!

    for _ in $(seq 1 60); do
        pg_isready -q -h /run/postgresql -U postgres && break
        kill -0 "$PG_PID" 2>/dev/null || die "PostgreSQL failed to start"
        sleep 1
    done
    pg_isready -q -h /run/postgresql -U postgres || die "PostgreSQL did not become ready"

    # Credentials used by Guacamole to reach the embedded database
    local pw_file="$DATA_DIR/.secrets/db_password"
    [ -s "$pw_file" ] || { gen_secret > "$pw_file"; chmod 600 "$pw_file"; }
    local db_pw
    db_pw="$(cat "$pw_file")"

    su-exec postgres psql -q -h /run/postgresql -U postgres -d postgres \
        -v ON_ERROR_STOP=1 -v pw="$db_pw" <<'SQL'
SELECT 'CREATE ROLE guacamole LOGIN'
    WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'guacamole') \gexec
ALTER ROLE guacamole WITH LOGIN PASSWORD :'pw';
SELECT 'CREATE DATABASE guacamole_db OWNER guacamole'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'guacamole_db') \gexec
SQL

    export POSTGRESQL_HOSTNAME=127.0.0.1
    export POSTGRESQL_PORT=5432
    export POSTGRESQL_DATABASE=guacamole_db
    export POSTGRESQL_USERNAME=guacamole
    export POSTGRESQL_PASSWORD="$db_pw"
    unset POSTGRESQL_PASSWORD_FILE
}

setup_postgresql_client() {
    export PGHOST="$POSTGRESQL_HOSTNAME"
    export PGPORT="${POSTGRESQL_PORT:-5432}"
    export PGDATABASE="$(read_var POSTGRESQL_DATABASE)"
    export PGUSER="$(read_var POSTGRESQL_USERNAME)"
    export PGPASSWORD="$(read_var POSTGRESQL_PASSWORD)"
    export PGCONNECT_TIMEOUT=5
    export PGOPTIONS="-c client_min_messages=warning"
    SCHEMA_DIR="$SCHEMA_ROOT/postgresql/schema"

    db_exec()  { psql -q -X -v ON_ERROR_STOP=1 "$@"; }
    db_file()  { psql -q -X -v ON_ERROR_STOP=1 -1 -f "$1"; }
    db_query() { psql -X -tA -v ON_ERROR_STOP=1 -c "$1"; }
    db_ready() { pg_isready -q; }
    db_table_exists() { [ "$(db_query "SELECT to_regclass('public.$1') IS NOT NULL")" = "t" ]; }

    db_set_admin() {
        db_exec -v user="$1" -v pw="$2" <<'SQL'
UPDATE guacamole_user
   SET password_hash = sha256(convert_to(:'pw' || upper(encode(password_salt, 'hex')), 'UTF8')),
       password_date = CURRENT_TIMESTAMP
 WHERE entity_id = (SELECT entity_id FROM guacamole_entity WHERE name = 'guacadmin' AND type = 'USER');
UPDATE guacamole_entity SET name = :'user' WHERE name = 'guacadmin' AND type = 'USER';
SQL
    }
    db_meta_get() { db_query "SELECT value FROM turnkey_meta WHERE key = '$1'" 2>/dev/null || true; }
    db_meta_set() {
        db_exec -v k="$1" -v v="$2" <<'SQL'
CREATE TABLE IF NOT EXISTS turnkey_meta (key varchar(64) PRIMARY KEY, value varchar(255) NOT NULL);
INSERT INTO turnkey_meta (key, value) VALUES (:'k', :'v')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
SQL
    }
}

setup_mysql_client() {
    # Password goes via MYSQL_PWD: option-file quoting mangles some characters
    export MYSQL_PWD="$(read_var MYSQL_PASSWORD)"
    MYSQL_ARGS=(--host="$MYSQL_HOSTNAME" --port="${MYSQL_PORT:-3306}"
                --user="$(read_var MYSQL_USERNAME)" --database="$(read_var MYSQL_DATABASE)"
                --connect-timeout=5)
    SCHEMA_DIR="$SCHEMA_ROOT/mysql/schema"

    # SQL string literal escaping for values we interpolate
    sql_str() { local s="${1//\\/\\\\}"; printf "'%s'" "${s//\'/\'\'}"; }

    db_exec()  { mysql "${MYSQL_ARGS[@]}"; }
    db_file()  { mysql "${MYSQL_ARGS[@]}" < "$1"; }
    db_query() { mysql "${MYSQL_ARGS[@]}" -N -B -e "$1"; }
    db_ready() { db_query "SELECT 1" >/dev/null 2>&1; }
    db_table_exists() { [ "$(db_query "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = '$1'")" = "1" ]; }

    db_set_admin() {
        db_exec <<SQL
UPDATE guacamole_user
   SET password_hash = UNHEX(SHA2(CONCAT($(sql_str "$2"), HEX(password_salt)), 256)),
       password_date = CURRENT_TIMESTAMP
 WHERE entity_id = (SELECT entity_id FROM guacamole_entity WHERE name = 'guacadmin' AND type = 'USER');
UPDATE guacamole_entity SET name = $(sql_str "$1") WHERE name = 'guacadmin' AND type = 'USER';
SQL
    }
    db_meta_get() { db_query "SELECT value FROM turnkey_meta WHERE \`key\` = '$1'" 2>/dev/null || true; }
    db_meta_set() {
        db_exec <<SQL
CREATE TABLE IF NOT EXISTS turnkey_meta (\`key\` VARCHAR(64) PRIMARY KEY, value VARCHAR(255) NOT NULL);
REPLACE INTO turnkey_meta (\`key\`, value) VALUES ($(sql_str "$1"), $(sql_str "$2"));
SQL
    }
}

# Creates the schema on an empty database, or applies upstream upgrade scripts
# when the image version is newer than the schema version recorded in
# turnkey_meta.
init_or_upgrade_schema() {
    log "Waiting for database..."
    local i
    for i in $(seq 1 "${DB_WAIT_SECONDS:-60}"); do
        db_ready && break
        sleep 1
    done
    db_ready || die "Database is not reachable"

    if ! db_table_exists guacamole_user; then
        log "Empty database: creating Guacamole $GUAC_VERSION schema"
        db_file "$SCHEMA_DIR/001-create-schema.sql"
        db_file "$SCHEMA_DIR/002-create-admin-user.sql"

        local admin_user admin_pw pw_note=""
        admin_user="$(read_var GUACADMIN_USERNAME)"
        admin_user="${admin_user:-guacadmin}"
        admin_pw="$(read_var GUACADMIN_PASSWORD)"
        if [ -z "$admin_pw" ]; then
            admin_pw="$(gen_secret | cut -c1-20)"
            printf 'username: %s\npassword: %s\n' "$admin_user" "$admin_pw" \
                > "$DATA_DIR/.secrets/initial_admin_password"
            chmod 600 "$DATA_DIR/.secrets/initial_admin_password"
            pw_note="  (also saved to $DATA_DIR/.secrets/initial_admin_password)"
        fi
        db_set_admin "$admin_user" "$admin_pw"
        db_meta_set schema_version "$GUAC_VERSION"

        log "================================================================"
        log " Initial administrator account created"
        log "   username: $admin_user"
        if [ -n "$pw_note" ]; then
            log "   password: $admin_pw"
            log "$pw_note"
        else
            log "   password: (as set in GUACADMIN_PASSWORD)"
        fi
        log " Change it after first login. It is only shown once."
        log "================================================================"
        return
    fi

    local current
    current="$(db_meta_get schema_version)"
    if [ -z "$current" ]; then
        if [ -n "${DB_SCHEMA_VERSION:-}" ]; then
            current="$DB_SCHEMA_VERSION"
            log "Existing database adopted; schema version given as $current"
        else
            warn "Existing Guacamole database was not created by this image; assuming its schema matches $GUAC_VERSION. If it is older, set DB_SCHEMA_VERSION=<old version> once so upgrades are applied."
            db_meta_set schema_version "$GUAC_VERSION"
            return
        fi
    fi

    if version_gt "$current" "$GUAC_VERSION"; then
        die "Database schema is version $current but this image is Guacamole $GUAC_VERSION. Downgrades are not supported."
    fi

    local f v applied=0
    while read -r f; do
        v="$(basename "$f" .sql)"; v="${v#upgrade-pre-}"
        # upgrade-pre-X.sql upgrades a schema older than X to X
        if version_gt "$v" "$current" && ! version_gt "$v" "$GUAC_VERSION"; then
            log "Applying schema upgrade $(basename "$f")"
            db_file "$f"
            applied=1
        fi
    done < <(ls "$SCHEMA_DIR"/upgrade/upgrade-pre-*.sql 2>/dev/null \
             | sed -E 's/.*upgrade-pre-(.*)\.sql$/\1 &/' | sort -V | cut -d' ' -f2)

    if [ "$current" != "$GUAC_VERSION" ]; then
        db_meta_set schema_version "$GUAC_VERSION"
        [ "$applied" = 1 ] && log "Schema upgraded $current -> $GUAC_VERSION" \
                           || log "Schema $current is compatible with $GUAC_VERSION"
    fi
}

case "$DB_MODE" in
    embedded)
        start_embedded_postgres
        setup_postgresql_client
        init_or_upgrade_schema
        ;;
    postgresql)
        setup_postgresql_client
        if is_true "${DB_AUTO_INIT:-true}"; then init_or_upgrade_schema; fi
        ;;
    mysql)
        setup_mysql_client
        if is_true "${DB_AUTO_INIT:-true}"; then init_or_upgrade_schema; fi
        ;;
    sqlserver)
        log "SQL Server: schema must be created manually (see README)"
        ;;
    none)
        log "No database: using only non-database authentication extensions"
        ;;
    *)
        die "Unknown DB_MODE '$DB_MODE' (expected auto, embedded, postgresql, mysql, sqlserver or none)"
        ;;
esac

# Don't leak client-only variables into tomcat's environment
unset PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGCONNECT_TIMEOUT PGOPTIONS MYSQL_PWD

###############################################################################
# guacd
###############################################################################

su-exec guacd /opt/guacamole/sbin/guacd -f -b 127.0.0.1 -l 4822 \
    -L "${GUACD_LOG_LEVEL:-info}" &
GUACD_PID=$!

###############################################################################
# Guacamole web application (unmodified upstream entrypoint)
###############################################################################

cd /tmp
HOME=/home/guacamole su-exec guacamole:guacamole \
    env -u LD_LIBRARY_PATH /opt/guacamole/bin/entrypoint.sh &
TOMCAT_PID=$!

log "Started: guacd pid $GUACD_PID, tomcat pid $TOMCAT_PID${PG_PID:+, postgres pid $PG_PID}"
log "Web UI on port 8080, context path: $([ "$WEBAPP_CONTEXT" = ROOT ] && echo / || echo "/${WEBAPP_CONTEXT//#//}/")"

# Exit (and let the restart policy act) as soon as any child dies
set +e
wait -n
rc=$?
warn "A service exited unexpectedly (status $rc); stopping container"
stop_all
exit "$(( rc == 0 ? 1 : rc ))"
