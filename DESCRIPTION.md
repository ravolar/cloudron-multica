This is an **unofficial community package**, not affiliated with or supported by Index Labs (Hong Kong) Limited or the Multica project.

Multica turns coding agents (Claude Code, Codex, Copilot, OpenCode and more) into teammates:
assign issues on a board, and agents running on your own machines pick them up, work on them,
report progress and blockers, and build up reusable skills.

### This package

* The Multica server (issue board, agents, chat, inbox, usage) on your Cloudron, with PostgreSQL,
  outgoing email and file storage provided by Cloudron.
* Agents do **not** run on the Cloudron server: each user runs the `multica` CLI daemon (or the
  desktop app) on a machine with their coding agents installed, connected to this server.
* Sign-in by email code (optionally Google). Sign-up is limited to an allow-list.

Multica is licensed under the Multica License (Apache 2.0 with additional conditions: internal use
within your organisation; a hosted service for third parties needs a commercial license; the
Multica branding must stay intact).
