# Multica for Cloudron

A [Cloudron](https://www.cloudron.io) community package for [Multica](https://multica.ai), the
platform that turns coding agents (Claude Code, Codex, Copilot, OpenCode and more) into teammates
on an issue board.

| | |
|---|---|
| Package | `io.github.ravolar.multica` |
| Upstream | [multica-ai/multica](https://github.com/multica-ai/multica) (Multica License) |
| Install URL | `https://raw.githubusercontent.com/ravolar/cloudron-multica/main/CloudronVersions.json` |
| Image | `ghcr.io/ravolar/cloudron-multica` |

## What you get

* The Multica server: issue board, agents and runtimes, chat, inbox, usage dashboards, REST API,
  real-time updates over WebSockets.
* PostgreSQL, outgoing email and file storage provided by Cloudron and configured automatically.
* Cloudron backups, restore, clone and updates. New Multica releases are packaged automatically
  after a smoke test (PostgreSQL 16 and 18) and an upgrade test with real data.

**Agents do not run on the Cloudron server.** Each user who wants agents runs the `multica` CLI
daemon (or the desktop app) on their own machine, where Claude Code, Codex and so on are
installed; the daemon connects to this server and executes the tasks assigned to its agents. The
server stores and dispatches work; it never executes agent code.

## Requirements

* Cloudron 10.0 or later (PostgreSQL 16 on Cloudron 10.0, 18 on 10.1; both are tested).
* About 250–400 MB of RAM in use (the package's limit is 1.5 GB).

## Installation

1. In the Cloudron dashboard open **App Store → Add custom app → Community app** and enter:

   ```
   https://raw.githubusercontent.com/ravolar/cloudron-multica/main/CloudronVersions.json
   ```

   (CLI: `cloudron install --versions-url <url> --location multica.example.com`)
2. Open the app's **File Manager**, set `ALLOWED_EMAILS` (or `ALLOWED_EMAIL_DOMAINS`) in
   `/app/data/env.sh` and **restart** the app. Until then nobody can sign up.
3. Sign in with the code sent to your email.

If your domain's DNS is not managed by Cloudron (provider "manual" or "no-op"), create the DNS
record for the app's hostname yourself **before** installing.

## Signing in

Multica signs users in with a one-time code sent by email (or with Google, if configured). There
is **no generic OpenID Connect**, so neither Cloudron user management nor another identity
provider can be used; the app does not use Cloudron's user directory.

Sign-up is closed by default (`ALLOW_SIGNUP="false"`): only addresses in `ALLOWED_EMAILS`, domains
in `ALLOWED_EMAIL_DOMAINS` and people invited to a workspace can create an account. Existing users
can always sign in.

Google sign-in: create an OAuth client with the redirect URI `https://<app domain>/auth/callback`
and set `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` in `env.sh`.

## Connecting agents

On a machine with a coding agent CLI installed (`claude`, `codex`, ...):

```bash
brew install multica-ai/tap/multica
multica setup self-host --server-url https://<app domain>
multica daemon start
```

The daemon authenticates with a personal access token and keeps a WebSocket open to
`/api/daemon/ws`. See upstream's [CLI_INSTALL.md](https://github.com/multica-ai/multica/blob/main/CLI_INSTALL.md).

**Trust.** Anyone who can assign an issue to an agent can make that agent run code on the machine
where its daemon runs. Only add people you trust to workspaces with agents.

## Configuration

Operator settings live in `/app/data/env.sh` (File Manager); **restart** the app after editing.
The file is created on first start with the supported options. Only plain assignments are
accepted, one per line (`NAME="value"`; single quotes if the value contains `$`, `` ` `` or `\`).
A file with anything else (commands, `export`, CRLF line endings, control characters) is rejected
and the app does not start; the log names the offending lines.

Set by the package on every start (values in `env.sh` are ignored): `DATABASE_URL`, the public URLs
and allowed origins (`FRONTEND_ORIGIN`, `CORS_ALLOWED_ORIGINS`, `MULTICA_APP_URL`,
`MULTICA_PUBLIC_URL`, `MULTICA_DAEMON_SERVER_URL`, `GOOGLE_REDIRECT_URI`), the `SMTP_*` settings,
`LOCAL_UPLOAD_DIR`, `MULTICA_TRUSTED_PROXIES`, `COOKIE_DOMAIN` (empty), `DO_NOT_TRACK` and
`ANALYTICS_DISABLED` (telemetry off), `MULTICA_CLOUD_URL` (empty: no managed-cloud features).

Everything else from upstream's [`.env.example`](https://github.com/multica-ai/multica/blob/main/.env.example)
can be set in `env.sh`: sign-up controls, Google sign-in, the GitHub App, Slack / Telegram / Lark /
DingTalk / WeCom bots (each enabled by its `MULTICA_*_SECRET_KEY`, a base64-encoded 32-byte key:
`openssl rand -base64 32`), the server-side LLM helpers.

### Secrets

`JWT_SECRET` (sessions) and `MULTICA_VCS_SECRET_KEY` (encrypts Forgejo / Gitea / GitLab access
tokens) are generated on first start into `/app/data/.secrets/secrets.env` (root-only) and never
regenerated. They are part of the app's backup.

### Email

Sign-in codes and invitations go through Cloudron's mail server on its internal STARTTLS port.
Multica refuses to send SMTP credentials over an unencrypted connection, and the certificate of
that port is issued for the Cloudron dashboard domain rather than the internal host name, so
certificate verification is disabled for this internal connection (it stays encrypted). If
outbound email is disabled for the app, sign-in codes cannot be delivered.

### Files

Attachments are stored in `/app/data/uploads` and included in the backup. S3-compatible storage
can be configured with upstream's `S3_*` variables instead.

## Security model

* **Privilege separation.** `start.sh` runs as root, never sources a file and never acts on a path
  the app user can rename or replace: `/app/data` and `env.sh` are root-owned (the app can only
  read `env.sh` and write `uploads/`), `.secrets` is root-only, `/run/multica` is recreated on
  every start, and symlinks in place of these files make the app refuse to start. Operator
  settings are loaded by `app-env.sh` as the app user, right before each process starts.
* **Clean environments.** Supervisor starts with an empty environment, so Cloudron's addon
  credentials and the package's secrets reach only the app processes (through `app-env.sh`).
* **Ports.** nginx owns the public port 8000; the web app listens on `127.0.0.1:3000`. The Go
  backend listens on port 8080 on all interfaces (upstream offers no bind address), which other
  containers on the Cloudron network can reach; it is the same API that is public anyway, and it
  trusts forwarded client addresses only from `127.0.0.1` (the local nginx). nginx takes the
  client address from Cloudron's reverse proxy only (`CLOUDRON_PROXY_IP`).
* Readiness and metrics endpoints (`/readyz`, `/healthz`, `/metrics`) are not served publicly.
* **Telemetry off**: `DO_NOT_TRACK=1`, `ANALYTICS_DISABLED=true`.
* **Sensitive data.** Agents' custom environment (for example `ANTHROPIC_API_KEY`) is stored by
  Multica in the database in plain text, as are pending sign-in codes (valid for 10 minutes).
  Treat the app's backups as secret.

## Operations

### Logs

Dashboard → app → Logs. A healthy start shows the package steps (`==> …`), `Running database
migrations...` with a list of `skip … (already applied)` / `up …` lines, then `Starting server...`
and the Next.js `Ready` line.

### Updates

New Multica releases are packaged automatically (see [Development and releasing](#development-and-releasing))
and offered in the app's **Updates** view; Cloudron backs up the app first. Multica migrates the
database forward on start and does not support downgrades: to go back, restore the pre-update
backup from **Backups**.

### Backups and restore

Cloudron backs up `/app/data` (`env.sh`, `.secrets/`, `uploads/`) and a dump of the PostgreSQL
database; restore, clone and import work as for any app.

## Troubleshooting

| Symptom | Check |
|---|---|
| App does not start, log says `env.sh ... Offending lines` | fix those lines in `/app/data/env.sh`, restart |
| "Sign-up is not allowed" | add the address to `ALLOWED_EMAILS` (or its domain to `ALLOWED_EMAIL_DOMAINS`), restart |
| Sign-in code does not arrive / "failed to send" | app → Email: outbound mail must be enabled; Cloudron's mail logs |
| Real-time updates stop, agents show offline | the daemon must use the app's exact URL (`https://<app domain>`); check `/api/daemon/ws` in the logs |
| "Failed to fetch dynamically imported module" after an update | the browser cached Cloudron's "app is down" page during the update; clear the site's data |

## Migrating an existing Multica installation

1. Install this package at a temporary location; open the web terminal.
2. Stop the old installation and dump its database (`pg_dump --no-owner --no-acl`).
3. In the app: stop the backend (`supervisorctl stop backend`), replace the empty database
   (`DROP SCHEMA public CASCADE; CREATE SCHEMA public;` with `psql "$CLOUDRON_POSTGRESQL_URL"`) and
   load the dump.
4. Copy the old uploads into `/app/data/uploads` and put the old `JWT_SECRET` and
   `MULTICA_VCS_SECRET_KEY` (and any `MULTICA_*_SECRET_KEY` you used) into
   `/app/data/.secrets/secrets.env` / `env.sh`; otherwise users sign in again and stored
   integration tokens must be re-entered.
5. Restart: Multica migrates the schema to its version. Move the app to its final domain and point
   the daemons at the new URL.

The old installation must not be newer than the package's Multica version.

## How it works

* The `Dockerfile` copies `/app` from `ghcr.io/multica-ai/multica-backend:<version>@<digest>`
  (static Go binaries: `server`, `migrate`, CLI, maintenance tools, and the SQL migrations) and
  from `ghcr.io/multica-ai/multica-web:<version>@<digest>` (Next.js standalone) onto
  `cloudron/node-base:24`. The web image only carries the Alpine build of `sharp`; the glibc build
  of the same version is added and checked by encoding an image at build time.
* `start.sh` (root) secures `/app/data`, generates secrets on first start, validates `env.sh`,
  derives the platform settings and starts supervisor.
* Supervisor runs `backend.sh` (`migrate up`, then the API server on 8080), the web app
  (`node apps/web/server.js` on `127.0.0.1:3000`) and nginx (port 8000), all as the `cloudron`
  user via `app-env.sh`. nginx implements upstream's same-origin layout: `/ws`, `/api/daemon/ws`,
  `/api/`, `/v1/`, `/uploads/`, `/health` and `/auth/*` (except the web app's OAuth callback pages)
  go to the backend, everything else to the web app.

## Development and releasing

Build and run a working copy on a test Cloudron (on-server build, no registry needed):

```bash
cloudron install --location multica.example.com
```

* `test/smoke.sh <image>` runs an image the way Cloudron does (read-only root filesystem, data,
  runtime and `.next` volumes) next to PostgreSQL (`PG_IMAGE`, default 16) and checks start-up,
  migrations, routing (web, API, WebSocket), a real email-code sign-in, a personal access token and
  the daemon WebSocket upgrade, sign-up restrictions, file ownership, process users, the absence of
  credentials in supervisor's environment and a restart.
* `test/upgrade.sh <old image> <new image>` does what a Cloudron update does: it creates an
  account, a workspace, an issue, an uploaded file and a token on the old image, replaces the
  container with the new one on the same data and database, and checks that all of it survived.

| Workflow | When | What |
|---|---|---|
| `ci.yml` | every PR and push to main | lint, build with the build-time checks, smoke test on PostgreSQL 16 and 18, upgrade test from the last published version |
| `update.yml` (**Update Multica**) | every 3 hours, and by hand | automatic releases, below |

**Releasing is automatic.** `update.yml` looks up Multica's latest GitHub release, pins the
digests of both images for that tag, bumps the patch version, sets `upstreamVersion`, writes the
CHANGELOG entry, builds, runs both smoke tests and the upgrade test, and only then pushes
`ghcr.io/ravolar/cloudron-multica:X.Y.Z`, adds it to `CloudronVersions.json` as published, commits
and tags `vX.Y.Z`. To release package changes without a new Multica version, run it by hand with
*release package changes* ticked and a CHANGELOG line in *notes*. If any step fails, nothing is
published and the run opens a GitHub issue.

Repository settings needed once: Actions → General → Workflow permissions **Read and write**; the
GHCR package must be public.

## License

Multica is © Index Labs (Hong Kong) Limited and contributors, licensed under the
[Multica License](https://github.com/multica-ai/multica/blob/main/LICENSE) (Apache License 2.0
with additional conditions). In short: use within your own organisation is permitted; providing
Multica as a hosted service to third parties, or embedding it in a commercial offering, requires a
commercial license from the producer; the Multica name, logo and attribution in the interface must
not be removed or changed. The image ships Multica unmodified (except adding the glibc build of
`sharp`) together with upstream's `LICENSE` and `NOTICE` (in `/app/code/backend` and
`/app/code/web`).

The packaging files in this repository (Dockerfile, scripts, configuration, tests, workflows) are
MIT licensed; see `LICENSE`.
