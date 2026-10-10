#!/bin/bash
# Web process (run by supervisor through app-env.sh, as the `cloudron` user): the Next.js app with
# only the settings it reads (apps/web: REMOTE_API_URL, DOCS_URL, PORT, NODE_ENV), so a bug in
# server-side rendering cannot leak the backend's secrets, which this process never receives.
set -eu

cd /app/code/web
exec env -i \
    PATH="${PATH}" HOME="${HOME}" TMPDIR="${TMPDIR}" LANG=C.UTF-8 \
    NODE_ENV=production HOSTNAME=127.0.0.1 PORT=3000 \
    REMOTE_API_URL="${REMOTE_API_URL}" \
    ${DOCS_URL:+DOCS_URL="${DOCS_URL}"} \
    ${NODE_OPTIONS:+NODE_OPTIONS="${NODE_OPTIONS}"} \
    node apps/web/server.js
