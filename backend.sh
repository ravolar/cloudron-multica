#!/bin/bash
# Backend process (run by supervisor through app-env.sh, as the `cloudron` user): apply pending
# database migrations, then start the API server. Mirrors upstream's docker/entrypoint.sh.
set -eu

cd /app/code/backend
# Fixed here, after env.sh, so operator settings cannot move the backend off its port.
export PORT=8080
# Both binaries share one startup budget for waiting on the database (upstream contract).
MULTICA_INTERNAL_DATABASE_STARTUP_STARTED_AT_UNIX="$(date +%s)"
export MULTICA_INTERNAL_DATABASE_STARTUP_STARTED_AT_UNIX

echo "Running database migrations..."
./migrate up
echo "Starting server..."
exec ./server
