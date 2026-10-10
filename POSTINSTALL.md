Before signing in, open the **File Manager** and set `ALLOWED_EMAILS` (or `ALLOWED_EMAIL_DOMAINS`)
in `/app/data/env.sh`, then **restart** the app. Sign-up is closed to everyone else.

Sign in with the code sent to your email. To connect agents, install the `multica` CLI on a
machine with Claude Code or Codex and point it at `https://$CLOUDRON-APP-DOMAIN`.

Only invite people you trust: whoever can assign work to an agent can run code on the machine
where that agent's daemon runs.
