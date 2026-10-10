#!/bin/bash
# Starts a Multica process with its environment. Runs as the `cloudron` user (supervisor's user=),
# never as root: operator settings from /app/data/env.sh can contain anything the validator
# accepts, including NODE_OPTIONS, LD_PRELOAD or PATH, so they must only ever reach processes
# that already run with the app's own privileges.
#
# Order: operator settings first, then the secrets and platform-derived values written by
# start.sh, which take precedence.
set -eu

set +u
set -o allexport
# shellcheck disable=SC1091
source /app/data/env.sh
# shellcheck disable=SC1091
source /run/multica/multica.env
set +o allexport
set -u

# Sign-up is closed unless env.sh opens it: only ALLOWED_EMAILS / ALLOWED_EMAIL_DOMAINS and
# invited addresses can create an account.
export ALLOW_SIGNUP="${ALLOW_SIGNUP:-false}"

exec "$@"
