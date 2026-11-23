#!/bin/bash
# Collab process (run by supervisor through app-env.sh, as the `cloudron` user): upstream's live
# co-editing service for Docs and issue descriptions (Hocuspocus). Editors never reach it
# directly: the backend proxies its /collab WebSocket here, and the service calls the backend's
# internal endpoints back with the shared COLLAB_SECRET. Like web.sh it gets only the settings it
# reads (apps/collab/src/config.ts), not the backend's secrets.
# Every open doc lives in this process's memory, so there is exactly one.
set -eu

cd /app/code/collab/apps/collab
exec env -i \
    PATH="${PATH}" HOME="${HOME}" TMPDIR="${TMPDIR}" LANG=C.UTF-8 \
    NODE_ENV=production COLLAB_PORT=8095 \
    COLLAB_SECRET="${COLLAB_SECRET}" \
    MULTICA_API_URL="http://127.0.0.1:8080" \
    MULTICA_CDN_DOMAIN="" \
    ${COLLAB_STORE_DEBOUNCE_MS:+COLLAB_STORE_DEBOUNCE_MS="${COLLAB_STORE_DEBOUNCE_MS}"} \
    ${COLLAB_STORE_MAX_DEBOUNCE_MS:+COLLAB_STORE_MAX_DEBOUNCE_MS="${COLLAB_STORE_MAX_DEBOUNCE_MS}"} \
    ${NODE_OPTIONS:+NODE_OPTIONS="${NODE_OPTIONS}"} \
    node --import tsx src/index.ts
