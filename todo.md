# todo.md — graphrag-rs-nix deferred work

Tracks work that's planned but explicitly deferred from the current implementation cycle.

## Risks introduced by the streaming extract↔embed pipeline (2026-05-07)

Followups for the cross-page-pipelined `do_append_graph` that ships
in graphrag-rs commit `<TBD>`. Architecture:

  Producer (graphrag-core `extend_graph_streaming`)
    → mpsc::channel(64) of `ChunkExtractionDelta`
    → Consumer (tokio::spawn'd in graphrag-server, embeds via OVMS
                concurrent-8, upserts to qdrant in 32-item flushes)

Per-batch consumer hands off across pages: while batch N's consumer
is still draining, batch N+1's LLM extraction starts.
`list_unextracted_chunks_excluding(N+1, prev_batch_ids)` keeps the
in-flight set out of the next page. Mark-extracted for batch N
happens after its consumer drains, before the iteration that holds
batch N+1's consumer as the new prev.

### Risks tracked

1. **Consumer panic safety — `mark_chunks_extracted` skipped on
   prev-consumer failure.** If `persist_touched_snapshot` errors
   inside the consumer task and the JoinHandle returns Err, the loop
   logs a warning and skips marking the prev batch's chunks
   extracted. They re-appear on the next /api/graph/append cycle and
   re-extract idempotently (merge_entity dedupes). **Self-healing,
   acceptable.** But: the in-memory graph already has the entities
   merged for that batch. Recall against that snapshot sees them;
   recall against qdrant doesn't (their entity-vector rows aren't
   persisted). Drift is bounded — next cycle re-extracts and
   re-persists. Worth adding a `tracing::error!` instead of `warn!`
   when this happens so it's visible in the journal.

2. **Two consumers in flight at once × OVMS contention.** The cross-
   page pipeline holds prev_consumer (still embedding batch N) AND
   the new consumer (just spawned for batch N+1, which won't get
   data until batch N+1's LLM finishes — 8+ min). So in steady state
   it's only ever ONE consumer doing actual OVMS work at a time.
   Edge case: if a batch's LLM finishes faster than expected
   (cached prompt prefix, all-empty extractions), the new
   consumer's first deltas hit OVMS while the prev is still
   draining. Both share the OVMS NPU bottleneck → no extra
   throughput, just additional queue depth at OVMS. Bounded by the
   buffer_unordered(8) cap inside each consumer's
   `generate_with_openai`, so peak concurrent OVMS calls ≤ 16.
   OVMS handles that fine. **Acceptable.**

3. **No automated test coverage for the streaming path.** Bench-
   validated only. If a refactor breaks the per-chunk dedupe set,
   the channel-close semantic, or `mark_chunks_extracted` ordering,
   we'd discover in production. **Add an integration test:** start
   graphrag-server against a sandbox qdrant, ingest N test docs,
   POST /api/graph/append, assert (a) all chunks marked extracted,
   (b) entity sidecar count grew by N_entities, (c) RSS stayed
   under 1 GB through the run.

4. **In-memory graph drift on partial failure.** `extend_graph`
   merges entities into the master IN PLACE during LLM extraction.
   If the consumer fails to persist some of those, the entities are
   in the master snapshot (Layer 4 ArcSwap) but not in qdrant. A
   recall using mode=default (graph-aware, reads master) sees them;
   a recall using mode=simple (vector, reads qdrant) doesn't. Next
   cycle re-extracts → re-persists → consistent again. The drift
   window is bounded to one /api/graph/append cycle. **Acceptable.**
   Worth a small status endpoint that surfaces "in-memory entity
   count vs qdrant entity count" for visibility.

5. **Channel capacity (64) is a hard cap on extraction-vs-embed
   imbalance.** Today embed is faster than LLM extraction by ~5×,
   so the channel never fills. If the LLM ever gets dramatically
   faster (Spark hardware bump, MTP enabled) AND embedding stays
   the same speed, the channel could fill, blocking the merge loop.
   Backpressure is the *correct* behavior — the alternative is OOM
   — but the user-facing symptom would be "extraction stalls
   during persistence." Mitigations: bump capacity OR scale OVMS
   concurrency. **Track but don't fix preemptively.**

6. **The "embed text" for an entity is `"name (type)"`. If the LLM
   ever returns the same name+type with different descriptions
   across chunks, the dedupe-by-id collapses them — only the FIRST
   surfacing's description gets embedded.** The current
   merge_entity strategy is "richer-mentions wins, first-seen
   description wins". Whether that's the right semantic for
   embedding is uncertain. Today it's not visibly wrong because
   our `EmbeddingsResponse` text is just `name (type)` not
   description; description doesn't affect the vector. But if we
   ever switch to embedding the description, this becomes load-
   bearing. **Note for if/when description embedding gets enabled.**

7. **No retry on transport failures inside the consumer.** The
   inner `persist_touched_snapshot` call can fail on transient
   OVMS or qdrant errors (network blip, OVMS restart, qdrant
   compaction stall). Currently the consumer logs and continues
   draining, but those flush's items are lost from the qdrant
   side (not retried). They'll re-extract next cycle, but the
   write-amplification stings at scale. **Add per-flush retry:**
   on transient error, re-queue items into next flush; on
   permanent error, surface to the caller.



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

Phase A — rip MS-GraphRAG QueryMode arms (shipped):
- [x] Delete `QueryMode::Ask` / `Explain` / `Reason` from
      `graphrag-server/src/models.rs` and the dispatch arms in
      `graph_aware_query` (main.rs).
- [x] Drop the `reason: true` flag from MCP `recall` tool description
      and inputSchema. Multi-hop questions now route through
      `mode: thorough` (= server `mix` mode).

Phase B — collapse dead retrieval tree in graphrag-core (shipped):
- [x] Delete `GraphRAG::ask`, `ask_explained`, `ask_with_reasoning`,
      `query_internal*`, `ask_with_pagerank`,
      `generate_semantic_answer_from_results`.
- [x] Delete `RetrievalSystem`'s big dead impl block (~1.3k LOC):
      `hybrid_query`, `hybrid_query_with_trees`, `legacy_hybrid_query`,
      `batch_query`, `execute_adaptive_retrieval`, plus all helpers
      (`vector_similarity_search`, `entity_centric_search`,
      `hierarchical_search`, etc.).
- [x] Delete `retrieval/adaptive.rs` (only consumer was the deleted
      `execute_adaptive_retrieval`).
- [x] Preserve LightRAG core: `extract_query_keywords`,
      `ask_with_dual_seeds`, `ask_with_seed_entities`.

Phase B.1 — workspace pruning (shipped):
- [x] Cargo.toml members reduced to `[graphrag-core, graphrag-server]`.
- [x] Delete `graphrag-cli`, `graphrag-wasm`, `graphrag_py`,
      `graphrag` (umbrella), `examples/`, `benches/`, `tests/`.
- [x] `pkgs/graphrag-rs.nix` cargoExtraArgs drops `-p graphrag-cli`.
- [x] flake.nix drops the `graphrag-cli` package output.
- [x] Drop `graphrag-cli` from dotfiles `environment.systemPackages`.

Phase C / 6 — kill the in-memory chunk universe (shipped):
- [x] Add `entities_extracted_at: Option<i64>` field to qdrant chunk
      payload (`DocumentMetadata` in `qdrant_store.rs`).
- [x] Add `QdrantStore::list_unextracted_chunks(limit)` — scrolls
      `is_current=true AND entities_extracted_at IS NULL`.
- [x] Add `QdrantStore::mark_chunks_extracted(point_ids, ts)` — bulk
      payload update after successful LLM extraction.
- [x] Add `QdrantStore::fetch_chunks_by_ids(point_ids)` — batch
      content-by-id read for the recall prefetch path.
- [x] Refactor `GraphRAG::extend_graph(&mut self)` →
      `extend_graph(&mut self, chunks: &[(ChunkId, String)])`. Caller
      drives "what to extract"; graphrag-core just consumes chunks
      and merges entities.
- [x] Refactor `ask_with_dual_seeds` and `ask_with_seed_entities` to
      take `chunk_contents: HashMap<ChunkId, String>` from caller.
- [x] Add `collect_chunk_ids_for_dual_seeds` and
      `collect_chunk_ids_for_seed_entities` helpers in graphrag-core
      that walk the entity graph to enumerate chunk ids the recall
      would touch — used by graphrag-server to prefetch via
      `fetch_chunks_by_ids`.
- [x] graphrag-server `do_append_graph` now: query qdrant for
      unextracted chunks → `extend_graph(&chunks)` →
      `mark_chunks_extracted` post-hoc.
- [x] graphrag-server `build_graph` HTTP handler is now a force-
      rebuild: `clear_graph()` + `extend_graph(all_qdrant_chunks)`
      + `mark_chunks_extracted(all)`.
- [x] graphrag-server query dispatch (`Local`, `Hybrid`, `Global`,
      `Mix`) prefetches chunk content from qdrant via
      `fetch_chunks_by_ids` before calling the corresponding
      ask_with_* function.
- [x] Drop `GraphRAG::add_document_from_text`, `add_document`,
      `seed_processed_chunks`, `clear_processed_chunks`,
      `processed_chunk_count`, `build_graph` (sync + async). The
      `processed_chunks: HashSet<ChunkId>` field is gone.
- [x] Drop `pipeline_executor` module + standalone constructors
      (`quick_start`, `quick_start_with_config`,
      `from_config_and_document`) — all bound to the deleted
      in-memory chunk path.
- [x] `/config` hydrate stops re-chunking every doc on every restart.
      Boot is now seconds, not minutes; ExecStartPost timeout
      regression resolved.
- [x] Ingest paths (`ingest_blocks`, `ingest_one_text`) drop the
      `add_document_from_text` call after qdrant write.
- [x] Update `recall-parallel-e2e.sh` to assert the new Phase 6 flow
      (`extend_graph: N delta chunks` log line) instead of the
      retired `warm_up_embeddings` log line.

Phase 5 — strip remaining MS-GraphRAG submodules (deferred, ~half day):

graphrag-core's `retrieval/` directory still contains submodules
nobody calls post-Phase 4: `bm25.rs`, `causal_analysis.rs`,
`enriched.rs`, `hipporag_ppr.rs`, `hybrid.rs`,
`pagerank_retrieval.rs`, `symbolic_anchoring.rs`. Plus `rograg/`
(only kept for `From` impls in `core/error.rs`) and
`query/planner.rs` (dead since `ask_with_reasoning` removal). Plus
`async_graphrag.rs` (separate parallel async impl, never wired).
They compile clean today; pruning is a separate cleanup pass.

Phase 7 — strip `KnowledgeGraph::chunks` storage (deferred, ~half day):

The in-memory `KnowledgeGraph` still has a `chunks: …` field, but
graphrag-server never writes to it after Phase 6. The `Chunk.embedding`
field is also dead (always None). Removing them cascades through
internal modules (`incremental.rs`, `core/mod.rs`, `optimization/`,
`rograg/`) — most of which are themselves dead in Phase 5. Best done
together with Phase 5 since the cascades overlap.

## Agent UX — MCP/Pi tool descriptions (shipped 2026-05-06)

Observed production failure modes from the 2026-05-06 agent trace:
- Agent dumped 4448-document `catalog` listing on a "what are my
  next work tasks?" question. `catalog` was meant for `remember`-path
  pre-flight ("is this already there?") but agents kept treating it
  as an LLM-readable filesystem ls.
- Agent fanned out 6 sequential paraphrased recalls (~46s wall-clock)
  instead of one-turn parallel; the MCP description's "PARALLELIZE"
  hint wasn't strong enough.
- Agent invented a `read main` shell command after seeing
  `top: main` in a recall result — treated the result `title` as a
  filesystem path. The response-schema interpretation needed to be
  explicit in the tool description.
- After getting a usable recall response, agent re-recalled instead
  of using the embedded answer — needed clearer "the answer block
  IS the answer" framing.

Shipped fixes:
- [x] `catalog` tool removed from MCP (`crates/knowledge-mcp/src/main.rs`).
      Agents have no business enumerating documents; they recall.
      Humans use `curl /api/documents` or the gateway plugin.
- [x] `recall` description rewritten with explicit response shape,
      "FIRST RULE" (always recall before any shell/find/grep),
      stronger PARALLELIZE guidance with positive/negative examples,
      anti-fan-out warning ("if 0 hits, ONE rephrase or report gap;
      don't auto-paraphrase 5 times"), and explicit "the `source`
      field is for citation, NOT a filesystem path."
- [x] Header doc-comment updated to reflect the four-tool surface.

Follow-ups (not yet shipped):

### Pi system-prompt addition: forbid filesystem-chase on vault content

Observed 2026-05-06 (second eval trace): even after the rewritten MCP
recall description told the agent "FIRST RULE: recall before any
shell/find/grep" and "the `source` field is for citation, NOT a
filesystem path", the agent:
- Called recall, got the right answer with fresh content,
- Then constructed a filesystem path from the recall's emoji-bearing
  `source` URI (mangling 🗂️ → 🔒🸀 in the process),
- Ran `find /home -name "*Yageo*"` for **84.9 seconds**,
- Read the file directly, re-stating what recall already returned.

The MCP tool description fires only when the agent decides to look at
tools. By the second turn ("any news on that?") it's running on
heuristics built from the first turn — and chose `find/grep/read`
over recall entirely.

Tool-description prose isn't strong enough as a forcing function. The
fix has to live one level up — at the Pi system prompt, where it
applies before the agent picks a tool.

Implementation:
- [ ] Audit how Pi (badlogic/pi-mono via dotfiles `pi-mono.nix`)
      composes its system prompt. Confirm where to inject a
      site-specific instruction block.
- [ ] Add a system-prompt block (verbatim, terse):
      ```
      Personal-knowledge questions — about the user's notes, journal,
      tasks, projects, prior conversations, vault contents — go
      THROUGH `recall` only. NEVER `find`, `grep`, `read`, `cat`, or
      `ls` against `/home/data01/Notes/` or any vault path. The
      recall result IS the answer. Don't filesystem-verify it.

      Allowed exception: the user explicitly asks you to inspect a
      specific file at a known path.

      Recall's `source` field is a citation URI, not a filesystem
      path. Never construct a shell path from it.
      ```
- [ ] Wire as a Pi extension or dotfiles-managed prompt fragment so
      it deploys with the rest of the system config and stays in
      lockstep across hosts.
- [ ] Verify by replaying the 2026-05-06 trace: agent should answer
      "any news on yageo?" with one `recall`, no shell. Capture the
      transcript as a regression test fixture.

Other follow-ups:
- [ ] Pi extensions / coding agent: tool-description tightening
      audit on any `pi-ext-rpiv-*` packages that wrap recall. Should
      drift from the canonical MCP one.
- [ ] After HippoRAG (Phase 8) ships: re-evaluate the "anti-fan-out"
      hint. Once first-shot recall hit-rate is high, the hint matters
      less; we may be able to relax it.
- [ ] Quantitative test harness: replay the 2026-05-06 trace
      (catalog dump → 6 sequential recalls) against the new tool
      descriptions to confirm the agent now: (a) skips catalog,
      (b) issues parallel recalls, (c) doesn't shell out to read
      result IDs as paths, (d) trusts the answer block.

## LightRAG quality improvements (deferred — research-backed; revisit later)

Researched 2026-05-06. The dead retrieval submodules (Phase 5 list)
weren't all noise — three of them are documented improvements over
plain LightRAG dual-level retrieval. Worth resurrecting selectively
**after** Phase 5 deletes the existing implementations (cleanest base
to evolve from). Each is a separate phase with measurable A/B against
the current LightRAG-only baseline.

### Phase 8 — HippoRAG (Personalized PageRank) seed scoring [PRIORITY] (~1 day)

**Marked as next priority** based on observed recall-quality
failures in production. Reference: HippoRAG, Yao et al. 2024.
Reported **12-19% improvement** over plain GraphRAG/RAG on
multi-hop benchmarks (MuSiQue, 2WikiMultihopQA, HotpotQA).

**Production motivating example (2026-05-06):**
The agent asked "what are my next work tasks?" against a corpus that
demonstrably contained the answer (`Tasks` doc, daily journal entries
with explicit `[ ] todo` checkboxes, `2026-05-06, Wednesday.md` with
"Debug WCDC due 2026-05-07"). LightRAG dual-keyword + 1-hop expansion
returned **0 hits on the first attempt**, forcing the agent to
fan out 5 sequential paraphrased queries, each ~7-8s, total ~40s
wall-clock. With HippoRAG's PPR personalization the entity-rich
"todo / task / debug / WCDC" subgraph would have ranked first hit and
the answer landed in one round.

This is exactly the multi-hop-with-implicit-entity-bridges shape
HippoRAG was designed for: query mentions abstract concept
("work tasks"), corpus contains specific entities ("WCDC", "oVirt",
"Christian", "Debug"), bridges via co-occurrence in dated journal
entries.

How: combine query→fact similarity (entity weights) with dense passage
signal (chunk weights) as the personalization vector for PPR over the
entity graph. Higher-PPR-rank entities + chunks rise to the top of
the seed set fed to `ask_with_dual_seeds`.

Implementation:
- [ ] Resurrect `retrieval/hipporag_ppr.rs` against the post-Phase-6
      API (no in-memory chunks; mention.chunk_id = qdrant block id;
      caller pre-fetches chunk content).
- [ ] Add MCP `mode: deep` (server `mode: hipporag`). The MCP
      description should pitch it as "default for multi-hop questions"
      and the agent should pick it when the question phrasing is
      abstract while answers are likely entity-specific.
- [ ] A/B test against the Yageo / WCDC / "what are my next tasks"
      corpus. Goal: 0-hit rate drops below 5%, top-1 hit rate ≥ 70%.
      Measure hit-rate-on-known-answer + LLM-judge quality.

### Phase 9 — BM25 / sparse retrieval fusion (~1 day)

Why: dense embeddings flatten rare/technical terms (model names like
`Qwen3.6-27B-Text-NVFP4-MTP`, NixOS module names, Obsidian tags,
code identifiers). BM25 nails them. Reciprocal Rank Fusion (RRF) of
BM25 + dense is the production-RAG default (ColBERT-X, RankGPT,
every commercial vector-DB benchmark).

Where it adds value for our vault: code snippets, NixOS configs,
machine-specific identifiers, jargon — anything dense embeddings
tend to confuse with semantically-similar-but-wrong neighbors.

Implementation:
- [ ] Decide path: (a) qdrant's built-in keyword search via tantivy
      backend, (b) tantivy index alongside qdrant, (c) graphrag-core's
      existing `retrieval/bm25.rs` module ported to Phase-6 API.
- [ ] Wire RRF fusion at the seed-finding step in
      `graph_aware_query`: dense entity-vector + BM25 keyword over
      entity sidecar names → fuse → top-K seeds.
- [ ] Same for relationship sidecar (high-level keyword stream).
- [ ] A/B test: 20 questions with rare proper nouns / identifiers.

### Phase 10 — Query decomposition mode (~half day)

Why: LightRAG `mix` mode adds chunk-vector seeds but doesn't
*decompose* compound questions. "Compare how Kafka and Pulsar handle
backpressure" benefits from running each subquery through
`ask_with_dual_seeds` independently, then synthesizing.

The existing `query/planner.rs` was driving the deleted
`ask_with_reasoning` and itself got removed in the Phase 5 sweep
(planned). Resurrect against Phase-6 API.

Implementation:
- [ ] Add MCP `mode: compound` (server `mode: decompose`).
- [ ] LLM call 1: split query into N independent subqueries.
- [ ] Per-subquery: extract_query_keywords → seed search →
      ask_with_dual_seeds (parallelizes nicely under Layer 3).
- [ ] LLM call 2: synthesize across subquery answers.
- [ ] A/B test: compound questions ("compare X and Y",
      "timeline of Z").

### Skipped from the dead-module list

- `retrieval/symbolic_anchoring.rs` (CatRAG) — moderate value for
  philosophy/concept-heavy corpora; low value for our (mostly
  technical) vault. Skip.
- `retrieval/causal_analysis.rs` — needs entity timestamps in
  payload; revisit if/when temporal queries become a workload.
- `retrieval/pagerank_retrieval.rs` (plain PageRank) — subsumed by
  HippoRAG; if we do PPR we do HippoRAG.
- `retrieval/enriched.rs` — already covered by qdrant payload
  filters + block-aware ingest.
- `rograg/` — heavy logic-form parser subsystem; modern LLMs do
  query parsing zero-shot well enough; dubious ROI vs maintenance.
- `async_graphrag.rs` — runtime, not algorithm; Layer 3 already
  delivers parallelism.

## Operational issues from 2026-05-06 deploy (action items)

### Phase C deploy fallout — first-time `entities_extracted_at` backfill

**Root cause**: pre-Phase-6 qdrant payloads have no
`entities_extracted_at` field. The new `list_unextracted_chunks`
filter (`is_current=true AND entities_extracted_at IS NULL`)
matches **all 4448** existing chunks on first /api/graph/append
post-deploy. Server tried to re-extract everything via vLLM at
:17170 — many minutes of LLM work, lots of `JSON repair failed`
warnings on the Obsidian-emoji-heavy chunks.

**Decision**: do NOT wipe the qdrant collection. The re-extraction
is correct behavior given the schema migration; the system
self-heals as chunks complete. A one-shot backfill would be faster
but adds operational complexity for marginal benefit.

Optional future work:
- [ ] One-shot backfill script: scroll qdrant, set
      `entities_extracted_at = now()` on every is_current=true
      chunk that lacks the field. Skips the cold-start re-extraction.
      Useful next time we ship a similar payload-schema migration.

### UTF-8 char-boundary panic in excerpt formatter (FIXED)

`graphrag-server/src/main.rs:912` (and :767, :839) sliced excerpts
by byte: `&s[..200]`. With your vault's heavy emoji usage
(`🗂️`, `📔`, `🗒️`, `✅`), the 200-byte boundary frequently fell
inside a multi-byte UTF-8 sequence and the runtime SIGABRTed mid-
extraction (status=6/ABRT). Replaced with a `truncate_excerpt`
helper that walks `char_indices()` to the nearest grapheme boundary.

## Content quality filtering — boilerplate / templates / stubs (research → proposal)

Researched 2026-05-06. Triggered by the post-Phase-6 cold-start
re-extraction: ~30% of the 4448 chunks produced 0 entities and 0
relationships, mostly because they were templated content (daily
journal habit-lists `Reading / drums / skating / HIIT`, frontmatter
scaffolding, empty stub notes like "something about WCDC project").
This is **not primarily a cost optimization** — the LLM cycles are
cheap. The real problem is **data quality**: when boilerplate does
extract anything, the entities ("Reading", "drums") become noise
hubs that pollute recall on unrelated queries.

### The general problem

Three failure modes from low-signal content:
1. **Storage waste** — chunks that contribute nothing to recall still
   take vector space and qdrant payload bytes.
2. **Graph pollution** — entities extracted from boilerplate appear
   in *every* chunk that contains the boilerplate, inflating their
   mention counts. Vector search then ranks them above more-relevant
   but less-frequent entities. Classic IDF-failure mode.
3. **Recall poisoning** — a query about, say, "skating safety
   research" surfaces personal-journal entries because the entity
   "skating" has 400+ mentions there.

### Production references

- **LightRAG** (paper): minimal filtering, relies on LLM extraction
  quality. Suffers exactly this problem on user-generated corpora.
- **Microsoft GraphRAG**: community detection partially absorbs
  boilerplate (it clusters together) but expensive index step.
- **HippoRAG**: PPR's personalization vector down-weights high-degree
  hubs naturally — partial mitigation.
- **LlamaIndex**: ships `KeywordExtractorFilter`, `RelevantTextFilter`,
  metadata-based filters at the node-postprocessor stage. Heuristic.
- **Cursor / Continue.dev / code-RAG**: aggressive ingest-time
  filters — drop generated files, lockfiles, vendor dirs, minified
  code. Path-glob-driven.
- **Notion AI, Mem.ai (retired)**: per-user "promotional content"
  blacklists; UI to mark notes as fleeting/template.
- **Common Crawl pipelines**: simhash / minhash near-duplicate
  detection; only extract from one representative per cluster.
- **Zettelkasten / Obsidian convention**: distinct folders for
  fleeting vs permanent notes; frontmatter tags
  (`status: fleeting`).

### Approach taxonomy (from cheap to deep)

**Tier 1 — heuristic ingest-time filters (cheap):**
- Length floor: skip chunks under N chars after stripping markdown.
- Frontmatter opt-out: respect `knowledge.skip: true` /
  `knowledge.priority: low` / `tags: [template, scratch]`.
- Path-glob exclude: vault config decides
  `exclude: ["📔 Journal/**", "**/templates/**", "_Drafts/**"]`.
- Heading-aware: skip `## Habits` blocks, `> [!todo]- Habits`
  callout blocks (these are Obsidian template markers).

**Tier 2 — statistical noise filters (computed post-ingest):**
- IDF cap on entity mentions: if entity appears in >K% of chunks,
  flag as boilerplate; surface entities below the threshold first
  in vector search.
- Near-duplicate clustering at chunk-vector level: cosine-similarity
  hierarchical cluster the entity sidecar; entities whose
  mention chunks are all near-duplicates get a "boilerplate" flag.
- Mention-frequency / unique-doc ratio: an entity mentioned 400×
  but only across 3 unique documents is a template artifact, not
  a real concept.

**Tier 3 — LLM-based quality gate (more expensive but precise):**
- Pre-extraction filter: tiny prompt to a cheap model — "Does this
  chunk contain extractable knowledge or is it template/boilerplate?"
  → skip if boilerplate. Saves the bigger extraction LLM call.
- Post-extraction filter: confidence-scored entity output → drop
  entities below threshold.

**Tier 4 — declarative curation (user-driven):**
- A `knowledge.toml` per-vault config: include/exclude globs,
  per-folder defaults, per-extension defaults, per-tag rules.
- Per-note frontmatter override:
  `knowledge: { include: false, reason: "personal-only" }`.

### Proposal for graphrag-rs

Tier 1 + Tier 2 + Tier 4 buy ~80% of the win. Tier 3 is overkill
for a personal-vault scale; revisit if/when we ship to multi-user
or hosted scenarios.

Discrete items:
- [ ] **Ingest-time path-glob filtering**: extend `IngestPolicy`
      (graphrag-server/src/ingest_policy.rs) with `exclude_globs:
      Vec<String>`. Default for neo-16:
      `["**/📔 Journal/**", "**/_Templates/**", "**/_Drafts/**"]`
      configurable in home-manager option.
- [ ] **Frontmatter opt-out**: parser respects `knowledge.skip:
      true` and `knowledge.priority: low` (low = ingested, but
      excluded from entity extraction).
- [ ] **Length floor**: skip chunks under 50 chars of non-whitespace
      content. Already partially happens (empty `text` skipped) but
      should respect a configurable minimum.
- [ ] **Heading-aware section skip**: detect Obsidian callout blocks
      `> [!todo]- Habits` and skip their bodies. Same for any
      sections matching configurable patterns
      (e.g. `## Habits$`, `## Daily$`).
- [ ] **Mention-frequency cap on entity sidecar**: at recall time,
      apply IDF-like down-weighting to entities whose mention count
      exceeds N% of total chunks. Cheap — just a payload filter
      adjustment.
- [ ] **Near-duplicate detection at ingest**: simhash of chunk
      content; if simhash matches an existing chunk within Hamming
      distance 3, mark new chunk as `is_duplicate_of: <prior_id>`
      and skip extraction (point still goes to qdrant for vector
      search, just doesn't run the LLM). Idempotent + restart-safe.
- [ ] **Per-vault `knowledge.toml`**: declarative include/exclude
      overlay. Lives at vault root; loaded once per session;
      affects both ingest and recall.

Cost: Tier-1 items ~half day each. Tier-2 mention-frequency cap
~half day. Near-duplicate detection ~1 day (needs simhash impl +
qdrant payload field). knowledge.toml ~1 day end-to-end (TOML
schema + loader + plugin pickup + home-manager overlay).

### Stale-content recall after file edit (open)

User edited a previously-ingested file in Obsidian; subsequent
`recall` returned the old stub content. No SSE notification fired
to the agent session. Three things to investigate:

- [ ] Does the Obsidian gateway plugin actually send the modified
      file? (Check plugin's diff logic — block-hash dedup might be
      treating it as unchanged.)
- [ ] Does qdrant's supersede logic flip `is_current=false` on the
      old chunk after upsert? Look at the
      `mark_block_superseded` / `find_current_block` path under
      block-form ingest in main.rs:~1300-1400.
- [ ] SSE delivery: agent (claude-code session) doesn't subscribe
      to /api/events/stream by default. Stale-context layer ships
      events but no client listens. Either wire the MCP to
      auto-subscribe on session start, or add an `agent` extension
      that does.


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

## Memory writes via Obsidian instead of direct graphrag ingest (idea — needs research)

Today the `remember` MCP tool (and the Pi toolcall equivalent) write
straight into the graphrag service for ingest. The graph ends up as
the only durable store of those memories — opaque vectors + entity
records, not human-readable prose anywhere on disk.

Alternative: route memory writes through the Obsidian vault first.
The MCP/Pi toolcall composes a markdown note (frontmatter + body),
drops it in a `_Memory/` (or similar) folder, and lets the existing
gateway plugin → graphrag ingest path pick it up like any other note.

Wins if it works:
- Memories exist as plain markdown files. User can read, edit,
  delete them by hand. Other agents (any tool that can read the
  vault) can grep/recall/cite the full text without going through
  graphrag.
- Single source of truth for "knowledge the user has accumulated";
  no divergence between vault content and graph-only content.
- Edits to a memory note flow through the same supersede /
  block-hash path as any other doc — no separate update API.

Open questions to research:
- Where do memory notes live? Dedicated folder vs frontmatter tag?
  Dedicated folder is cleanest for `exclude_globs` if the user
  wants to opt out per-vault.
- Note shape: one note per memory (matches MEMORY.md / per-file
  layout used for Claude Code auto-memory) or daily-aggregated?
  Per-memory is more diff-friendly and easier to delete.
- How does the `remember` tool name files? Slug from a one-line
  summary? Hash? Datestamp prefix?
- Round-trip: when `remember` is called from a session that's not
  inside the vault host, how does the note get written? Gateway
  plugin's HTTP API would need a "create note" endpoint, or
  graphrag-server gains a write-through-to-vault path.
- Latency: writing a markdown file + waiting for the gateway to
  ingest is slower than direct graphrag ingest. Acceptable?
- Conflict with the graphrag-rs `remember` tool's current
  semantics — does it become an alias for "create vault note +
  ingest" or stay as a separate fast path?

This is a research idea, not a planned phase. Revisit after the
near-term agent-UX and HippoRAG work settles.

## Repo restructuring (longer term)

- [ ] Merge `graphrag-rs` (the Rust server fork) into `graphrag-rs-nix`. The fork has diverged enough that "fork" is misleading; we own the whole stack.
- [ ] Single Cargo workspace at the repo root containing graphrag-server, graphrag-core, knowledge-mcp, knowledge-watcher, plus the plugin under `plugins/obsidian/`.
- [ ] Single nix flake that builds the lot.
- [ ] Single CI surface.
