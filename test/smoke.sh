#!/bin/bash
# Smoke test: run the package image the way Cloudron does (read-only root filesystem, /app/data,
# /run, /tmp and the .next runtime dir as writable volumes) next to PostgreSQL, and check that
# Multica comes up healthy, that sign-in works end to end and that the package's safety measures
# are in place. Then restart and check again.
#
#   test/smoke.sh <image>
#
# PG_IMAGE selects the PostgreSQL version (default postgres:16-alpine, like Cloudron 10.0; Cloudron
# 10.1 runs PostgreSQL 18). Needs docker, curl and jq. Leaves nothing behind.
set -euo pipefail

IMAGE=${1:?usage: test/smoke.sh <image>}
PG_IMAGE=${PG_IMAGE:-postgres:16-alpine}
ID="multicasmoke$$"
PORT=${SMOKE_PORT:-18500}
ORIGIN="http://localhost:${PORT}"
EMAIL="admin@example.com"
WORK=$(mktemp -d)
FAILED=0

cleanup() {
    docker rm -f "${ID}-app" "${ID}-pg" "${ID}-redis" >/dev/null 2>&1 || true
    docker volume rm "${ID}-run" "${ID}-tmp" "${ID}-next" >/dev/null 2>&1 || true
    docker network rm "${ID}" >/dev/null 2>&1 || true
    # the data dir is root-owned after start.sh ran; remove it from a container
    docker run --rm -v "${WORK}:/w" --entrypoint sh "${PG_IMAGE}" -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1 || true
    rmdir "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass "${name}"; else fail "${name}"; fi; }
no_match() { ! grep -qE "$1" <<<"$2"; }
app_exec() { docker exec "${ID}-app" "$@"; }
# Reads the Next.js process environment as its own user (root may not read other users' environ).
web_env_clean() {
    local env
    env=$(docker exec -u cloudron "${ID}-app" bash -c 'tr "\0" "\n" < "/proc/$(pgrep -f "^next-server" | head -1)/environ"')
    grep -q '^REMOTE_API_URL=' <<<"${env}" && ! grep -qE '^(JWT_SECRET|DATABASE_URL|SMTP_PASSWORD|MULTICA_[A-Z_]*SECRET_KEY|REDIS_URL)=' <<<"${env}"
}
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "==> Starting PostgreSQL (${PG_IMAGE})"
docker network create "${ID}" >/dev/null
docker run -d --name "${ID}-pg" --network "${ID}" \
    -e POSTGRES_USER=multicauser -e POSTGRES_PASSWORD='p+w/d=1' -e POSTGRES_DB=multicadb \
    "${PG_IMAGE}" >/dev/null
# Redis like Cloudron's addon (per-app instance with a password).
docker run -d --name "${ID}-redis" --network "${ID}" redis:7-alpine redis-server --requirepass redispw >/dev/null
for _ in $(seq 1 60); do
    docker exec "${ID}-pg" pg_isready -q -U multicauser -d multicadb >/dev/null 2>&1 && break
    sleep 1
done
sleep 2

mkdir -p "${WORK}/data"
# The operator's first edit (POSTINSTALL): allow one address. Written before the first start, so
# start.sh keeps it instead of writing the template.
# ALLOW_SIGNUP="no" must not open sign-up (upstream only closes on exactly "false").
cat > "${WORK}/data/env.sh" <<EOF
ALLOWED_EMAILS="${EMAIL}"
ALLOW_SIGNUP="no"
EOF

start_app() {
    docker run -d --name "${ID}-app" --network "${ID}" --read-only \
        -p "127.0.0.1:${PORT}:8000" \
        -v "${WORK}/data:/app/data" -v "${ID}-run:/run" -v "${ID}-tmp:/tmp" \
        -v "${ID}-next:/app/code/web/apps/web/.next" \
        -e CLOUDRON_APP_ORIGIN="${ORIGIN}" \
        -e CLOUDRON_POSTGRESQL_URL="postgres://multicauser:p%2Bw%2Fd%3D1@${ID}-pg:5432/multicadb" \
        -e CLOUDRON_POSTGRESQL_HOST="${ID}-pg" -e CLOUDRON_POSTGRESQL_PORT=5432 \
        -e CLOUDRON_POSTGRESQL_USERNAME=multicauser -e CLOUDRON_POSTGRESQL_PASSWORD='p+w/d=1' \
        -e CLOUDRON_POSTGRESQL_DATABASE=multicadb \
        -e CLOUDRON_REDIS_URL="redis://default:redispw@${ID}-redis:6379" \
        "${IMAGE}" >/dev/null
}

wait_ready() {
    for _ in $(seq 1 120); do
        if [[ "$(status "${ORIGIN}/health")" == 200 && "$(status "${ORIGIN}/login")" == 200 ]]; then
            return 0
        fi
        if docker logs "${ID}-app" 2>&1 | grep -qE "Refusing to start|==> ERROR"; then
            return 1
        fi
        sleep 2
    done
    return 1
}

run_checks() {
    local logs
    logs=$(docker logs "${ID}-app" 2>&1)
    check "backend healthy through nginx (/health)" test "$(status "${ORIGIN}/health")" = 200
    check "web app renders (/login)" test "$(status "${ORIGIN}/login")" = 200
    check "server config answers (/api/config)" bash -c "curl -fs '${ORIGIN}/api/config' | jq -e 'type == \"object\"'"
    check "migrations applied" bash -c "docker exec ${ID}-pg psql -U multicauser -d multicadb -tAc 'select count(*) from information_schema.tables where table_schema = current_schema()' | awk '\$1 > 20 {ok=1} END {exit !ok}'"
    check "WebSocket path reaches the backend (/ws)" bash -c "c=\$(curl -s -o /dev/null -w '%{http_code}' -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' '${ORIGIN}/ws'); [ \"\$c\" != 404 ] && [ \"\$c\" != 502 ]"
    check "readiness/metrics endpoints not public" test "$(status "${ORIGIN}/readyz")" = 404
    check "web app on loopback only" app_exec bash -c 'grep -q "0100007F:0BB8 00000000:0000 0A" /proc/net/tcp'
    check "telemetry disabled" grep -q "DO_NOT_TRACK" <<<"${logs}"
    check "/app/data is root-owned" test "$(app_exec stat -c %U:%a /app/data)" = "root:755"
    check "env.sh readable by the app only via group" test "$(app_exec stat -c %U:%G:%a /app/data/env.sh)" = "root:cloudron:640"
    check "secrets are root-only" test "$(app_exec stat -c %U:%a /app/data/.secrets/secrets.env)" = "root:600"
    check "app user cannot read the secrets" bash -c "! docker exec -u cloudron ${ID}-app cat /app/data/.secrets/secrets.env"
    check "app user cannot write env.sh" bash -c "! docker exec -u cloudron ${ID}-app sh -c 'echo x >> /app/data/env.sh'"
    check "uploads owned by the app user" test "$(app_exec stat -c %U /app/data/uploads)" = "cloudron"
    check "supervisor does not carry addon credentials" bash -c "! docker exec ${ID}-app cat /proc/1/environ | tr '\\\\0' '\\\\n' | grep -qE '^(CLOUDRON_POSTGRESQL_PASSWORD|JWT_SECRET|DATABASE_URL)='"
    check "web process does not get the backend's secrets" web_env_clean
    check "sign-in rate limiting active (Redis)" bash -c "! grep -q 'auth rate limiting disabled' <<<\"\$1\"" _ "${logs}"
    check "Multica processes run as the app user (uid 1000)" test "$(app_exec bash -c 'for p in /proc/[0-9]*; do case "$(cat "$p/comm" 2>/dev/null)" in server|node|next-server*|nginx) awk "/^Uid:/{print \$2}" "$p/status";; esac; done | sort -u | tr -d "\n"')" = "1000"
}

login() {
    curl -s -X POST -H 'Content-Type: application/json' -d "{\"email\":\"$1\"}" "${ORIGIN}/auth/send-code" >/dev/null
    local code
    code=$(docker logs "${ID}-app" 2>&1 | sed -n "s/.*Verification code for $1: \([0-9A-Za-z]*\).*/\1/p" | tail -n 1)
    [[ -n "${code}" ]] || return 0
    curl -s -X POST -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"code\":\"${code}\"}" \
        "${ORIGIN}/auth/verify-code" | jq -r '.token // empty'
}

echo "==> First start"
start_app
if wait_ready; then pass "app started"; else fail "app started"; docker logs "${ID}-app" 2>&1 | tail -60; exit 1; fi
run_checks

echo "==> Sign-in"
token=$(login "${EMAIL}")
check "allowed address can sign in (email code)" test -n "${token}"
check "signed-in API call works (/api/me)" bash -c "curl -fs -H 'Authorization: Bearer ${token}' '${ORIGIN}/api/me' | jq -e --arg e '${EMAIL}' '.email == \$e'"
pat=$(curl -s -X POST -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' \
    -d '{"name":"smoke","expires_in_days":1}' "${ORIGIN}/api/tokens" | jq -r '.token // empty')
check "personal access token for the CLI/daemon" test -n "${pat}"
check "agent daemon WebSocket upgrades with the token (/api/daemon/ws)" test "$(curl -s --http1.1 -m 3 -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${pat}" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "${ORIGIN}/api/daemon/ws" || true)" = 101
curl -s -X POST -H 'Content-Type: application/json' -d '{"email":"stranger@example.org"}' "${ORIGIN}/auth/send-code" >/dev/null
check "other addresses cannot sign up (ALLOW_SIGNUP=\"no\" stays closed)" no_match "Verification code for stranger@example.org" "$(docker logs "${ID}-app" 2>&1)"
codes=$(for _ in $(seq 1 8); do status -X POST -H 'Content-Type: application/json' -d "{\"email\":\"${EMAIL}\"}" "${ORIGIN}/auth/send-code"; echo; done)
check "code requests are rate-limited per client" grep -q 429 <<<"${codes}"

echo "==> Restart"
docker restart "${ID}-app" >/dev/null
if wait_ready; then pass "app restarted"; else fail "app restarted"; docker logs "${ID}-app" 2>&1 | tail -60; exit 1; fi
check "session survives a restart (stable JWT secret)" bash -c "curl -fs -H 'Authorization: Bearer ${token}' '${ORIGIN}/api/me' | jq -e --arg e '${EMAIL}' '.email == \$e'"
check "secrets kept across restart" test "$(app_exec stat -c %U:%a /app/data/.secrets/secrets.env)" = "root:600"

if [[ ${FAILED} -ne 0 ]]; then
    echo "==> SMOKE TEST FAILED"
    docker logs "${ID}-app" 2>&1 | tail -80
    exit 1
fi
echo "==> Smoke test passed"
