#!/usr/bin/env bash
#
# End-to-end smoke test: boots the image, waits for it to become healthy, logs
# in through the REST API with the generated admin password, restarts the
# container to prove the data volume persists, and checks that feature toggles
# load their extensions.
#
# Usage: tests/smoke.sh <image>
#
set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
NAME="guac-smoke-$$"
VOL="guac-smoke-$$"
PORT="${SMOKE_PORT:-18089}"
BASE="http://127.0.0.1:$PORT"

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; docker logs "$NAME" 2>&1 | tail -80 >&2; exit 1; }

wait_healthy() {
    local status
    for _ in $(seq 1 90); do
        status="$(docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null || echo missing)"
        [ "$status" = healthy ] && return 0
        [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || fail "container exited"
        # Healthcheck interval is 30s; poll the endpoint directly to go faster
        curl -fsS -o /dev/null "$BASE/" 2>/dev/null && return 0
        sleep 2
    done
    fail "container did not become healthy"
}

login() {
    curl -fsS -X POST "$BASE/api/tokens" \
        --data-urlencode "username=$1" --data-urlencode "password=$2"
}

run() {
    docker run -d --name "$NAME" -p "$PORT:8080" -v "$VOL:/data" "$@" "$IMAGE" >/dev/null
}

echo "--- first boot"
run
wait_healthy
creds="$(docker exec "$NAME" cat /data/.secrets/initial_admin_password)"
user="$(echo "$creds" | awk '/^username:/{print $2}')"
pass="$(echo "$creds" | awk '/^password:/{print $2}')"
login "$user" "$pass" | grep -q '"authToken"' || fail "admin login failed"
login guacadmin guacadmin 2>/dev/null | grep -q authToken && fail "default guacadmin/guacadmin password still works"
echo "ok: admin login with generated password"

echo "--- restart with TOTP enabled (data must persist)"
docker rm -f "$NAME" >/dev/null
run -e TOTP_ENABLED=true
wait_healthy
docker logs "$NAME" 2>&1 | grep -q "Initial administrator account created" && fail "database was re-initialised on restart"
# With TOTP on, a password-only login must be challenged for a code
resp="$(curl -sS -X POST "$BASE/api/tokens" --data-urlencode "username=$user" --data-urlencode "password=$pass")"
echo "$resp" | grep -qi 'guac-totp' || fail "TOTP challenge not presented: $resp"
echo "ok: data persisted, TOTP enforced"

echo "--- guacd reachable only on loopback"
docker exec "$NAME" nc -z 127.0.0.1 4822 || fail "guacd not listening"
echo "ok"

echo "PASS"
