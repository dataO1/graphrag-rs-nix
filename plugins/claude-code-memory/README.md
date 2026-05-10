# claude-code-memory

Internal Claude Code plugin: long-term memory tools, session
logging, and reflection skills.

Bundles:

- **MCP server** (`memory`): `recall`, `remember`, `forget`,
  `status`. Stdio transport; backed by the local graphrag-server.
- **Skills** (under `skills/`):
  - `consolidate-memory` — distil findings + catch up missed log
    rows. Auto-invoked on `PreCompact`.
  - `recall-and-think` — multi-hop deep recall. User-invoked.
  - `document-decision` — capture a decision with alternatives,
    rationale, rollout/rollback. User-invoked.
  - `log-session-action` — append a row to today's session log
    after a meaningful unit of work. Auto-invoked.
- **Hooks** (under `hooks/hooks.json`):
  - `UserPromptSubmit` — staleness check; surfaces lease
    invalidations as additional context.
- **CLAUDE.md** — compressed always-on guidance (~15 lines). Symlinked into
  `~/.claude/CLAUDE.md` by the home-manager module (Claude Code's plugin
  format does not support shipping CLAUDE.md to the agent's context layer
  directly; this is the workaround).

## Loading

Claude Code does not support declarative local-plugin loading via
settings.json. The home-manager module (`modules/home-manager.nix`
in graphrag-rs-nix) wraps the `claude` binary with
`--plugin-dir <store-path>` so this plugin loads on every
session.

## Building

The plugin is built per-host because `.mcp.json`,
`hooks/hooks.json`, and `bin/staleness-check` bake host-specific
values (graphrag-server URL, session id) at build time. See
`pkgs/claude-code-memory-plugin.nix` for the derivation.

## Internal-only

Not for distribution. The package is internal so MCP, hooks,
skills, and prompt guidance update in lockstep on every
`nixos-rebuild switch`.
