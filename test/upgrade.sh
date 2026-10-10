#!/bin/bash
# Upgrade test: what a Cloudron update does to a running installation. Start the old image, create
# real data through the API (account, workspace, issue, uploaded file, personal access token), then
# replace the container with the new image on the same /app/data, /run and database (the .next
# runtime dir is recreated from the new image, as Cloudron does), and check that the update kept
# everything: migrations, data, the file, sessions, the token (agent daemons), secrets, settings.
#
#   test/upgrade.sh <old image> <new image>
#
# PG_IMAGE selects the PostgreSQL version (default postgres:16-alpine). Needs docker, curl and jq.
# Leaves nothing behind.
set -euo pipefail

OLD_IMAGE=${1:?usage: test/upgrade.sh <old image> <new image>}
NEW_IMAGE=${2:?usage: test/upgrade.sh <old image> <new image>}
PG_IMAGE=${PG_IMAGE:-postgres:16-alpine}
ID="multicaupgrade$$"
PORT=${UPGRADE_PORT:-18510}
ORIGIN="http://localhost:${PORT}"
EMAIL="admin@example.com"
WORK=$(mktemp -d)
FAILED=0

cleanup() {
    docker rm -f "${ID}-app" "${ID}-pg" >/dev/null 2>&1 || true
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
app_exec() { docker exec "${ID}-app" "$@"; }
status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

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
        "$1" >/dev/null
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

# API call with the session token and the workspace header.
api() {
    local method=$1 path=$2; shift 2
    curl -s -X "${method}" -H "Authorization: Bearer ${token}" -H "X-Workspace-ID: ${workspace_id:-}" "$@" "${ORIGIN}${path}"
}

# A daemon connects with a personal access token over /api/daemon/ws; 101 = upgraded.
daemon_ws_status() {
    curl -s --http1.1 -m 3 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" \
        -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "${ORIGIN}/api/daemon/ws" || true
}

secrets_sum() { app_exec sha256sum /app/data/.secrets/secrets.env /app/data/env.sh; }

echo "==> Old version: ${OLD_IMAGE}"
docker network create "${ID}" >/dev/null
docker run -d --name "${ID}-pg" --network "${ID}" \
    -e POSTGRES_USER=multicauser -e POSTGRES_PASSWORD='p+w/d=1' -e POSTGRES_DB=multicadb \
    "${PG_IMAGE}" >/dev/null
for _ in $(seq 1 60); do
    docker exec "${ID}-pg" pg_isready -q -U multicauser -d multicadb >/dev/null 2>&1 && break
    sleep 1
done
sleep 2
mkdir -p "${WORK}/data"
printf 'ALLOWED_EMAILS="%s"\n' "${EMAIL}" > "${WORK}/data/env.sh"
docker pull -q "${OLD_IMAGE}" >/dev/null 2>&1 || true
start_app "${OLD_IMAGE}"
if wait_ready; then pass "old version started"; else fail "old version started"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi

echo "==> Creating data on the old version"
curl -s -X POST -H 'Content-Type: application/json' -d "{\"email\":\"${EMAIL}\"}" "${ORIGIN}/auth/send-code" >/dev/null
code=$(docker logs "${ID}-app" 2>&1 | sed -n "s/.*Verification code for ${EMAIL}: \([0-9A-Za-z]*\).*/\1/p" | tail -n 1)
token=$(curl -s -X POST -H 'Content-Type: application/json' -d "{\"email\":\"${EMAIL}\",\"code\":\"${code}\"}" \
    "${ORIGIN}/auth/verify-code" | jq -r '.token // empty')
check "signed in" test -n "${token}"
workspace_id=$(api POST /api/workspaces -H 'Content-Type: application/json' \
    -d '{"name":"Upgrade test","slug":"upgrade-test"}' | jq -r '.id // empty')
check "workspace created" test -n "${workspace_id}"
issue_id=$(api POST /api/issues -H 'Content-Type: application/json' \
    -d '{"title":"Survives the update","description":"Created before the update"}' | jq -r '.id // empty')
check "issue created" test -n "${issue_id}"
printf 'uploaded before the update\n' > "${WORK}/upload.txt"
upload=$(api POST /api/upload-file -F "file=@${WORK}/upload.txt")
file_url=$(jq -r '.download_url // .url // empty' <<<"${upload}")
check "file uploaded" test -n "${file_url}"
pat=$(api POST /api/tokens -H 'Content-Type: application/json' -d '{"name":"upgrade-test","expires_in_days":1}' |
    jq -r '.token // empty')
check "personal access token created" test -n "${pat}"
check "daemon WebSocket accepts the token (old version)" test "$(daemon_ws_status "${pat}")" = 101
before_secrets=$(secrets_sum)
if [[ ${FAILED} -ne 0 ]]; then
    echo "==> UPGRADE TEST FAILED (could not create data on the old version)"
    docker logs "${ID}-app" 2>&1 | tail -40
    exit 1
fi

echo "==> Updating to: ${NEW_IMAGE}"
# Like a Cloudron update: the container is replaced; /app/data, /run, /tmp and the database stay,
# runtime dirs come fresh from the new image.
docker rm -f "${ID}-app" >/dev/null
docker volume rm "${ID}-next" >/dev/null
start_app "${NEW_IMAGE}"
if wait_ready; then pass "new version started on the old data"; else fail "new version started on the old data"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi

check "migrations ran without errors" bash -c "! docker logs ${ID}-app 2>&1 | grep -qiE 'migration.*(failed|error)'"
check "secrets and settings unchanged" test "$(secrets_sum)" = "${before_secrets}"
check "session from before the update still valid" bash -c "curl -fs -H 'Authorization: Bearer ${token}' '${ORIGIN}/api/me' | jq -e --arg e '${EMAIL}' '.email == \$e'"
check "workspace kept" bash -c "curl -fs -H 'Authorization: Bearer ${token}' '${ORIGIN}/api/workspaces' | jq -e --arg id '${workspace_id}' '[.. | objects | select(.id? == \$id)] | length > 0'"
check "issue kept" test "$(api GET "/api/issues/${issue_id}" | jq -r '.title // empty')" = "Survives the update"
check "uploaded file kept" bash -c "curl -fs -H 'Authorization: Bearer ${token}' -H 'X-Workspace-ID: ${workspace_id}' '${ORIGIN}${file_url}' | grep -q 'uploaded before the update'"
check "daemon WebSocket accepts the old token" test "$(daemon_ws_status "${pat}")" = 101
check "new data can be written" test -n "$(api POST /api/issues -H 'Content-Type: application/json' -d '{"title":"Created after the update"}' | jq -r '.id // empty')"

echo "==> Restart after the update"
docker restart "${ID}-app" >/dev/null
if wait_ready; then pass "restarts cleanly after the update"; else fail "restarts cleanly after the update"; fi

if [[ ${FAILED} -ne 0 ]]; then
    echo "==> UPGRADE TEST FAILED"
    docker logs "${ID}-app" 2>&1 | tail -60
    exit 1
fi
echo "==> Upgrade test passed"
