# todo.md — graphrag-rs-nix deferred work

Tracks work that's planned but explicitly deferred from the current implementation cycle.

## Drop graphrag-core's in-memory embedding architecture

Researched 2026-05-06. Triggered by the Layer 3 deploy: my `/config`-time
`warm_up_embeddings()` call blew systemd's ExecStartPost timeout on a 4k+
doc / 90k+ chunk corpus, putting the unit in a restart loop. Pulling the
thread revealed the in-memory chunk + entity embedding layer in
graphrag-core is mostly unused on the actual hot path.

### Two chunk universes today

| Store | Chunks | Embeddings | Used by |
|---|---|---|---|
| Qdrant `graphrag` | block-bound, real ingest IDs | ✅ | hybrid/global/mix recall |
| Qdrant `graphrag-entities` sidecar | — (entity vectors) | ✅ | hybrid keyword search |
| Qdrant `graphrag-relationships` sidecar | — (rel vectors) | ✅ | hybrid keyword search |
| graphrag-core in-memory KG (chunks) | re-chunked at character windows | ❌ until warmed | only graphrag-core standalone `ask` / `ask_explained` (which graphrag-server doesn't expose via MCP) |
| graphrag-core in-memory KG (entities/rels) | restored from Qdrant sidecar | ✅ deserialized | hybrid graph traversal (ID + neighbor lookup, NOT vector search) |

The MCP `recall` default = `hybrid` → `ask_with_dual_seeds`, which seeds
from Qdrant entity/relationship hits and traverses the in-memory entity
graph by ID. It does **not** read in-memory chunk or entity embeddings.

### Findings — graph + vector consolidation evaluated, NOT pursued

Evaluated Qdrant-native graph (none), Weaviate cross-refs (slow at 3-hop),
Neo4j 5+vector (JVM, 2–4 GB heap), Memgraph (in-memory openCypher),
ArangoDB (BSL relicense), Postgres+pgvector+AGE (AGE sparsely
maintained), SurrealDB (official Rust client, native graph + HNSW),
TigerGraph (overkill).

Verdict: **stay on Qdrant + petgraph in-memory entity/relationship
graph.** At 1,469 edges the graph is ~50 KB, petgraph traversal is
nanoseconds, no DB beats it. Recall bottleneck is the 50s LLM call —
shaving microseconds off graph hops is invisible. Migration cost
> consolidation benefit at this scale.

If we ever consolidate (graph >1M edges or RAM pressure):
**SurrealDB** is the only candidate matching the stack ethos (single
Rust binary, official `surrealdb` crate, no JVM). Revisit then.

### Refactor plan

Phase 1 — already shipped:
- [x] Drop `warm_up_embeddings()` call from `/config` hydrate
- [x] Layer 3 read-lock + recall semaphore (the warm-up call was a
      Layer 3 invariant under the old assumption recall reads the
      in-memory chunk vectors)

Phase 2 — drop the dead code paths from graphrag-server (shipped):
- [x] Remove `warm_up_embeddings()` calls from `build_graph`,
      `do_append_graph`, `ingest_blocks`, `ingest_one_text` in
      `graphrag-server/src/main.rs`. The hot path doesn't read what
      they populate.

Phase 3 — strip the in-memory embedding API from graphrag-core (shipped):
- [x] Remove `warm_up_embeddings()` from `GraphRAG` (lib.rs).
- [x] Remove `add_embeddings_to_graph`, `add_embeddings_parallel`,
      `add_embeddings_sequential` from `RetrievalSystem`
      (retrieval/mod.rs).
- [x] `query_internal` / `query_internal_with_results` no longer call
      the lazy embed; they take `&self`.


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

## Stale-context awareness for shared knowledge graph (research → proposal)

When two agents/users share the same graphrag, A reads chunks at T1, B
edits the underlying doc at T2 > T1. A's LLM context window now holds
stale assertions A will reason over as truth. Existing literature
treats this as cache invalidation across read-replicas, but with a twist
no database has: the "cache" is the model's KV-cache, and you can't
selectively evict. Once a stale chunk is folded into context, it's
acted on as ground truth.

Researched 2026-05-06 (see conversation log). Key findings:

- **MCP `resources/subscribe` + `notifications/resources/updated`** is
  the existing protocol primitive. Spec stable since 2025-06-18, client
  coverage uneven. Notification carries only the URI; client re-fetches.
- **Zep's bi-temporal model** (`valid_at` / `invalid_at` /
  `created_at` / `expired_at`, arxiv 2501.13956) is the cleanest
  prior art for graph-shaped agent memory. Auditable: "what did the
  agent think was true at T1?"
- **Recency-decay retrieval scoring** (arxiv 2509.19376) — fuse
  cosine similarity with half-life decay so stale chunks never even
  surface. Works orthogonally to invalidation.
- **Vector DBs are passive.** No production vector store offers a
  client-facing change-notification API as of mid-2026. CDC over the
  source DB is the workaround, but it doesn't reach an agent already
  holding a snapshot.
- **Real gap in the literature**: no in-band staleness surface in
  tool-call protocols, no "retrieval ETag" convention, no
  `revalidate_context()` tool, no benchmark for the multi-user
  A-reads-then-B-edits scenario.

We already have most of the substrate: `is_current` / `version` /
`valid_from` per chunk, `block_hash` as a natural ETag, `asOf` +
`maxVersionsPerDoc` filters, and the Obsidian gateway plugin which
*originates* the change events.

### Proposal — server-push event log with delta payloads, per-session scoped

The architecture: an append-only event log on the server emits a
record every time a block is added, superseded, or removed. Clients
subscribe to a Server-Sent Events (SSE) stream filtered by their
session's lease table. Each event ships the *delta itself*
(old/new excerpt + unified diff), so the agent can reason about
changes without re-querying. Resumability is built into SSE via the
`Last-Event-ID` header — a client that disconnects (network blip,
laptop suspend, CLI restart) reconnects with its last-seen id and
the server replays everything missed since.

**Per-session scoping is the core invariant.** Agent A's session
tracks only the chunks A retrieved. B's edits don't invalidate the
*graph* for everyone; they fan out as events to *whichever sessions
hold the affected blocks in their lease tables*. Cross-session
isolation falls out for free: two CLI tabs in the same user account
each have their own session id, lease table, and SSE stream.

```
   Obsidian gateway  ─────POST /api/documents──────►  graphrag-server
                                                        │
                                                        │  on each block
                                                        │  insert/supersede/delete
                                                        ▼
                                                ┌────────────────────┐
                                                │  events sidecar    │
                                                │  monotonic id +    │
                                                │  block_id + etag   │
                                                │  + delta + ts      │
                                                └────────┬───────────┘
                                                         │
                                                         │  filter by
                                                         │  session's
                                                         │  lease table
                                                         ▼
   pi / claude-code ◄─────GET /api/events/stream─────  SSE
       │  Last-Event-ID: 12345
       │  ?session_id=...
       ▼
  session file on disk: { session_id, last_event_id }
```

#### Storage layer — three small additions
- `lease_table` keyed by `session_id`: `[(block_id, etag, retrieved_at)]`,
  plus `last_activity` timestamp for TTL
- `event_log` append-only: `(event_id u64 monotonic, ts, block_id,
  source, change_type ∈ {added, updated, removed}, old_etag,
  new_etag, old_excerpt, new_excerpt, unified_diff)`
- `compaction_watermark`: smallest event_id still in the log; clients
  reconnecting with `Last-Event-ID < watermark` get a "do full
  re-sync" signal

Backend choice: **SQLite via `rusqlite`** rather than a qdrant
sidecar. Event logs are relational (ORDER BY id, range scans by ts),
qdrant is built for vector search. SQLite gives us
`AUTOINCREMENT`, ordered queries, transactions for "append event +
update lease atomically", and trivial cleanup via `DELETE WHERE ts
< ?`. No new system dependency — `rusqlite` is bundled.
DB file lives next to the qdrant data path, e.g.
`/var/lib/graphrag-rs/state.sqlite`.

#### API surface
- `POST /api/recall` — gains optional `sessionId` body field; when
  set, server adds the recall hits to that session's lease table.
  Response gains `etag` per hit.
- `POST /api/recall/revalidate` — body `[{blockId, etag}]`, returns
  `{stale, current, missing}`. Pure SQL lookup. Cheap.
- `GET /api/lease/check?sessionId=X` — server-side equivalent: looks
  up the session's lease table internally and returns the verdict
  without payload.
- `GET /api/events/stream?sessionId=X` — SSE stream filtered by
  session's lease table. Honors `Last-Event-ID` request header for
  resume. On `last_event_id < compaction_watermark` emits a single
  `event: cursor-too-old` then closes; client falls back to one-shot
  `lease/check`.
- `DELETE /api/lease/{sessionId}` — explicit session teardown;
  cleanup task does this automatically after TTL.

#### Event payload shape
```json
{
  "id": 12345,
  "ts": "2026-05-06T10:09:07Z",
  "blockId": "Foo > Bar::0",
  "source": "obsidian://vault/Notes/foo.md",
  "changeType": "updated",
  "oldEtag": "abc123",
  "newEtag": "def456",
  "delta": {
    "oldExcerpt": "...up to 500 chars before...",
    "newExcerpt": "...up to 500 chars after...",
    "unifiedDiff": "@@ -3,4 +3,4 @@\n-old line\n+new line"
  }
}
```
Eager delta storage (compute + store on event emit, not on read) so
playback is fast and stream consumers don't need follow-up GETs.

#### Retention + cleanup (the "don't flow over" part)

Two TTLs, both configurable in the home-manager service definition:

- **eventRetentionDays** (default `7`): events older than this are
  deleted; the watermark advances. Replays beyond it require the
  client to do a one-shot full lease/check.
- **sessionTtlDays** (default `7`): sessions whose `last_activity`
  is older than this are deleted (lease table + any cached state).
  Active sessions naturally bump `last_activity` on every recall.

Cleanup runs as a tokio interval task inside graphrag-server,
firing every `cleanupIntervalHours` (default `6`). On each tick:
1. `DELETE FROM event_log WHERE ts < now - eventRetentionDays`
2. Update `compaction_watermark` to current `MIN(event_id)`
3. `DELETE FROM lease_table WHERE last_activity < now - sessionTtlDays`
4. `VACUUM` periodically (every 7 days, opportunistically)
5. Log line: `"cleanup: dropped N events, M sessions; event log now {} rows, {:.1}MB"`

Bound on storage in steady state:

```
events ≤ writes_per_day × eventRetentionDays
       ≈ (typical: ~1000 ingests × 5 changed blocks / day × 7 days)
       ≈ ~35K events × ~2KB each = ~70MB

sessions ≤ active_sessions × sessionTtlDays
        ≈ (~10 × 7 days) = ~70 sessions of trivial size
```

So a week of event history is comfortably ≤ 100MB on disk.

#### Settings (home-manager service definition)

```nix
services.graphrag-rs.staleContext = {
  enable = true;
  eventRetentionDays = 7;        # how long event deltas are kept
  sessionTtlDays = 7;            # how long an idle session lease lives
  cleanupIntervalHours = 6;      # how often the cleanup task runs
  maxLeasesPerSession = 1000;    # bound runaway sessions
  deltaExcerptChars = 500;       # max chars of old/new excerpt per event
};
```

All exposed as environment variables to graphrag-server (e.g.
`STALE_CONTEXT_EVENT_RETENTION_DAYS`) so the binary stays
twelve-factor-friendly.

#### Client-side behavior (pi extension as the prototype)

- On extension load: read or generate `session_id`; persist to
  `~/.pi/agent/extensions/knowledge-state.json` alongside
  `last_event_id`
- On agent session start: open SSE stream
  `GET /api/events/stream?sessionId=X` with `Last-Event-ID: <last>`
- For each event: persist new `last_event_id` AFTER consuming;
  enqueue a system note for the next turn:
  *"Note: chunk {blockId} you cited was edited.
  Old: '<oldExcerpt>'
  New: '<newExcerpt>'
  The new content is now in your knowledge graph; cite it directly,
  no re-recall needed."*
- On `cursor-too-old`: call `lease/check`, get bulk verdict, prepend
  one summary note (*"M of N retrieved chunks updated since session
  was last active. Recommend re-recalling key facts."*)
- On stream disconnect (network blip, server restart): reconnect
  with exponential backoff (250ms → 30s); persisted `last_event_id`
  makes reconnects idempotent
- Slash command `/refresh` for an explicit re-run of the recent
  recalls when a bulk note appears

#### Resumability scenarios (covered)

| Scenario | Behavior |
|---|---|
| User closes pi mid-session, reopens 2 minutes later | Replay 2-min gap (likely 0 events). Live stream continues. |
| User reopens pi 2 days later | If `last_event_id < watermark`: full lease/check + bulk note. Else replay normally. |
| Server restarts | Event log on disk; clients see TCP drop, reconnect with cursor, replay since cursor. |
| Two pi tabs same user | Each has its own session_id + cursor + stream. No cross-contamination. |
| Brief network loss | Browser-style reconnect with `Last-Event-ID`. No events lost as long as gap < retention. |
| Client crashes mid-event | `last_event_id` updated AFTER the system note is enqueued. Worst case: same event delivered twice; client dedups by event_id. |
| Long-running CLI session crosses the 7-day window | Cursor falls behind compaction watermark → full re-sync at next reconnect. Active sessions stay live (since `last_activity` keeps bumping). |

#### Cost

| | Effort |
|---|---|
| SQLite schema + migrations + emit-on-ingest | ~1 day |
| SSE endpoint with `Last-Event-ID` cursor + per-session filter | ~1 day |
| Server-side lease table + recall augmentation | ~half day |
| Periodic cleanup task + flake settings + nixos module wiring | ~half day |
| Pi extension SSE consumer + system-note injection | ~1 day |
| Delta payload (oldExcerpt/newExcerpt/diff computation) | ~half day |
| e2e test (edit a doc, assert event delivered with delta) | ~half day |

**Total: ~5 days.** The delta-shipping piece is the biggest user-
visible win — agent gets the change *as the change*, doesn't have
to query again.

### Open design choices remaining (rare edge cases; not blockers)

- **Block_hash drift across embedders**: if the embedding model is
  swapped, every block_hash changes and every lease appears stale.
  Solution: separate `content_hash` (text only, embedder-independent)
  from `embedding_hash`; use `content_hash` as the etag.
- **Multi-vault scoping**: when multi-vault lands, the events sidecar
  needs a `scope` field; SSE filter adds `scope IN (...)` to the
  WHERE clause. Trivial extension.
- **Agent UX for "agent re-cites" the new content**: when an event
  fires for a block the agent quoted, should the system note
  *replace* the prior quoted text in some way? Agent context is
  immutable; we can't edit. Best we can do is the system note
  pattern. Worth a UX experiment.
- **Backpressure**: SSE has no native ack. If a slow client falls
  behind enough that the server's send buffer fills, drop oldest
  events and effectively force a cursor-too-old re-sync. Standard
  practice.
- **Benchmark**: there isn't a public one for multi-user stale-
  context. We could publish "GraphRAG-A-then-B" as a small eval
  suite alongside the implementation.

### What this would mean if upstreamed

The closest existing primitive is MCP `resources/subscribe`, but the
spec stops at the resource level — not the chunk level — and doesn't
standardize cursor-based resume. A "retrieval ETag" + per-session
lease table + auto-revalidating SSE stream + delta payloads is
genuinely green-field. Worth landing as a graphrag-rs feature,
possibly with upstream contribution to the MCP spec for the
chunk-ETag + resume-via-cursor convention.

## Repo restructuring (longer term)

- [ ] Merge `graphrag-rs` (the Rust server fork) into `graphrag-rs-nix`. The fork has diverged enough that "fork" is misleading; we own the whole stack.
- [ ] Single Cargo workspace at the repo root containing graphrag-server, graphrag-core, knowledge-mcp, knowledge-watcher, plus the plugin under `plugins/obsidian/`.
- [ ] Single nix flake that builds the lot.
- [ ] Single CI surface.
