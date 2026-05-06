# todo.md — graphrag-rs-nix deferred work

Tracks work that's planned but explicitly deferred from the current implementation cycle.

## Phase C — Obsidian gateway polish (deferred)

In-app graph UX inside the gateway plugin. Phase A ships the data layer; Phase C is the human surface.

- [ ] Sidebar pane: recall history with click-through to the source note (split-pane open)
- [ ] "Related entities" backlinks-style panel for the active note (queries `/api/graph/entities?note=…`)
- [ ] Inline graph viewer (mini D3/cytoscape) showing entities + relations within reach of the active note
- [ ] Recall-result preview cards with line-number jump (uses `lineRange` from response → split-pane + scrollIntoView)
- [ ] Frontmatter convention `knowledge.priority: high` to weight a note higher in recall
- [ ] Right-click on any selection → "Add as fact to knowledge graph" (writes to `_Generated/` with backlink to source)

## Multi-vault (deferred — needs server-side scope plumbing)

Current state: `user_id` is a flat namespace. To support multiple vaults cleanly:

- [ ] Add `scope: Option<String>` to `DocumentMetadata` (qdrant payload). Default = `"default"`.
- [ ] `/api/query` accepts `scope` filter. Default = include `"default"` (back-compat) and any scopes the caller is authorized for.
- [ ] `/api/documents` accepts `scope` (defaults to `"default"`); persists into payload.
- [ ] knowledge-mcp passes a `scope` from `KNOWLEDGE_SCOPE` env (set per-client).
- [ ] Plugin includes `scope = vault.getName()` on every gateway request.
- [ ] Catalog listing partitions by scope.
- [ ] Vault-rename handling: bulk-rewrite `scope` field for the affected partition.

Estimated cost: ~1 day end-to-end (server payload + endpoint + MCP + plugin).

## Late chunking (deferred — pilot first)

Qwen3-Embedding-0.6B has 32K native context. Late chunking (embed full doc once, mean-pool a separate vector per chunk) gives better cross-chunk awareness than the contextual-prefix approach Phase B ships.

- [ ] Bench late-chunked recall vs prefix-chunked recall on a held-out vault subset
- [ ] If quality lift is meaningful, add an opt-in pipeline mode `chunkingStrategy: "late"`
- [ ] Else close out as "not worth the embedding compute"

## Phase B follow-ups (after the simple version lands)

- [ ] Per-chunk content hashing on **path-based** ingest as well (currently only the plugin sends per-block hashes; path-based ingest still re-embeds the full doc on any change)
- [ ] Server-side splitter: when blocks[] is omitted, server still chunks at section/paragraph boundaries (instead of one-doc-one-point)
- [ ] Diff-and-rebuild on the server (server-owned diff for non-plugin clients) — currently the plugin owns the diff state
- [ ] Token-counter calibration: current 512-token target uses tiktoken cl100k; verify Qwen3-Embedding's actual tokenizer doesn't drift far enough to matter

## Concurrency follow-ups (after option-5 lands)

We landed LightRAG-parity option 5 — touched-only embed + embed outside the lock.
That cuts an append cycle from ~256 s to ~2-5 s and stops recall from blocking
on persist. Two more upstream-aligned improvements remain:

### Option 3 — Recall takes a read-lock (or no lock)

Right now `graph_aware_query` calls `state.graphrag.write().await` because
`graphrag.ask()` takes `&mut self`. With option-5 the lock is held only briefly
during extend_graph + snapshot, so contention is rare — but recall and append
still serialize through the same write-lock by type.

LightRAG upstream `aquery_llm` takes **zero** locks; queries route directly
into `entities_vdb` / `relationships_vdb` without touching the graph storage.

To match:
- [ ] Audit `graphrag.ask()` / `ask_explained()` / `ask_with_reasoning()` for
      true mutation. Read-paths hidden in mutable wrappers (caches, internal
      counters) should be split into a `&self` retrieval API + a `&mut self`
      cache-update tail.
- [ ] If the cache needs mutation, hold the cache behind its own `Mutex`
      (interior mutability) so `ask` can take `&self`.
- [ ] Change `graph_aware_query` to use `state.graphrag.read().await`.
- [ ] Estimate: ~1 day. Touches a chunk of graphrag-core.

### Option 4 — Per-entity keyed locks (fully upstream-equivalent)

LightRAG's `KeyedUnifiedLock` (`lightrag/kg/shared_storage.py:529`) acquires
locks at **entity-id granularity** during merge so two unrelated entity
upserts never serialize. Combined with option 3 it means concurrent appends
across distinct entity sets run in parallel.

To match:
- [ ] Replace `RwLock<Option<GraphRAG>>` with a structure that holds the
      graphrag instance behind a `KeyedRwLock<EntityId>` for per-key
      acquisition during merge, plus a global "build/extend" lock for
      pipeline-level serialization.
- [ ] Worth doing only if you measure contention bottlenecks after 3.
- [ ] Estimate: 2-3 days. Significant refactor.

## Repo restructuring (longer term)

- [ ] Merge `graphrag-rs` (the Rust server fork) into `graphrag-rs-nix`. The fork has diverged enough that "fork" is misleading; we own the whole stack.
- [ ] Single Cargo workspace at the repo root containing graphrag-server, graphrag-core, knowledge-mcp, knowledge-watcher, plus the plugin under `plugins/obsidian/`.
- [ ] Single nix flake that builds the lot.
- [ ] Single CI surface.
