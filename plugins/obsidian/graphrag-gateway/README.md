# graphrag-gateway — Obsidian plugin

Indexes the active vault into a local **graphrag-rs** server (default
`http://127.0.0.1:17180`). Watches `vault.on("modify"/"create"/…)`
events instead of inotify so opening a note never triggers ingest;
only real edits do. Computes a per-block diff so a 1-line edit only
re-embeds the affected chunks.

Also exposes a small HTTP gateway on `127.0.0.1:27180` so MCP/LLM
clients can `recall` / `remember` / `forget` *through Obsidian* — a
`remember` becomes a real vault note (`_Generated/<title>.md` by
default) which then naturally cascades into the same ingest path.

## Install (NixOS / home-manager)

The dotfiles activation script symlinks `manifest.json` + `main.js`
from this repo into `~/Notes/.obsidian/plugins/graphrag-gateway/`.
The plugin must be built first:

```sh
cd ~/Projects/graphrag-rs-nix/plugins/obsidian/graphrag-gateway
npm install
npm run build
```

This produces `main.js`. After the next `home-manager switch` the
symlinks land in the vault and the plugin shows up in
**Settings → Community plugins**.

## Settings

| key | default | notes |
|---|---|---|
| `graphragBaseUrl` | `http://127.0.0.1:17180` | REST endpoint of the local graphrag-rs server |
| `gatewayPort` | `27180` | 127.0.0.1 port for the HTTP gateway (restart Obsidian to apply changes) |
| `debounceMs` | `10000` | idle time after the last edit before ingesting |
| `excludeGlobs` | `.obsidian/*`, `.trash/*`, `_attachments/*` | one per line; star matches within a path segment |
| `excludeFrontmatterKey` | `knowledge` | notes with this set to `false` (or `{ exclude: true }`) are skipped |
| `debug` | `false` | console logs |

## Commands (palette)

- **Knowledge: Recall…** — modal with a textarea; calls `/api/query`
- **Knowledge: Reindex this note** — clears the cached file hash and re-ingests
- **Knowledge: Forget this note** — `DELETE /api/documents/<source-uri>`
- **Knowledge: Reindex entire vault** — clears all hashes and queues every `.md` file

## Status bar

| glyph | meaning |
|---|---|
| `know ●` | server reachable, idle |
| `know ⋯ (N)` | N ingest(s) pending in the debounce window |
| `know ○` | server unreachable |

## How block-aware ingest works

1. On `vault.on("modify")` (or `create`), the plugin reads the file
   via `app.vault.cachedRead`, computes a SHA-256 file hash. If the
   file hash matches the last-seen one, no-op.
2. Else it splits the markdown into *blocks* (ATX-header sections,
   paragraph boundaries inside, `^block-id` markers respected) and
   computes per-block SHA-256 hashes.
3. Diff against the persisted block-hash map (lives in the plugin's
   `data.json`, inside `<vault>/.obsidian/plugins/graphrag-gateway/`):
   - `changedBlocks[]` = blocks whose hash differs from last-known
   - `removedBlockIds[]` = ids that were present last time, gone now
4. POST to `<graphragBaseUrl>/api/documents` with:
   - `source` = `obsidian://vault/<vault-name>/<vault-path>` (URI-encoded)
   - `id` = same as `source` (used as `user_id` server-side for upserts)
   - `content` = full file body (server feeds this into the graphrag
     entity-extraction pipeline so cross-section coreferences stay
     visible — block-level extraction would lose them)
   - `blocks` = changed blocks with `id, content, hash, lineStart,
     lineEnd, headingPath`
   - `removedBlockIds` = list of vanished ids
5. Server marks each `(user_id, block_id)` superseded for both
   removed and changed ids, then embeds the changed blocks (with a
   contextual prefix `[title > h1 > h2]` prepended at embed time
   only — stored text stays clean) and inserts one Qdrant point per
   block carrying `source`, `block_id`, `block_hash`, `headingPath`,
   `lineStart`, `lineEnd`.
6. Plugin updates its persisted block-hash map only after a successful
   POST so failed ingests retry on the next edit.
