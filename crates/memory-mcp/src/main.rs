// Stdio MCP server exposing the user's long-term memory.
//
// Four tools, mapped onto graphrag-server's REST API:
//
//   recall    — search/answer (POST /api/query, mode-parametric)
//   remember  — ingest (POST /api/documents, polymorphic body)
//   forget    — delete one document (DELETE /api/documents/:id)
//   status    — graph counts + last-built timestamp (GET /api/graph/stats)
//
// `catalog` was removed: agents misused it to dump 4448-document lists
// when answering content questions. The right path is always `recall`.
// Humans who want a doc list use `curl /api/documents` or the gateway.
//
// `append_graph` and `build_graph` are NOT exposed: graphrag-server
// runs an in-process debounced coalescer that wakes on every
// successful ingest and folds new chunks into the entity graph
// after a brief quiet window. Agents just call `recall` / `remember`
// / `forget` and the graph stays fresh on its own.
//
// Protocol: JSON-RPC 2.0 over newline-delimited stdin/stdout, MCP
// version 2024-11-05. Skeleton modeled on samyama-ai/graphrag-rs.

mod logging;

use anyhow::Result;
use logging::{LogActionArgs, LogContext, LogDecisionArgs};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::env;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

const PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "memory-mcp";
const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");

/// The URL path for the /recall/kinds endpoint on the graphrag-rs
/// server. Note: NOT under /api/ — the server registers this on the
/// plain web::scope (Card 2 deviation confirmed in PRD).
const RECALL_KINDS_PATH: &str = "/recall/kinds";

#[derive(Debug, Clone)]
struct Config {
    base_url: String,
    timeout_secs: u64,
    /// Stable session id for stale-context lease tracking. When set,
    /// every `recall` body gets a `sessionId` field so the server tags
    /// its lease table per session and the matching `/lease/check` /
    /// `/events/stream` endpoints can report which leased blocks have
    /// since changed. Pi sets this in-process; stdio MCP clients
    /// (Claude Code, Cursor, …) supply it via `MEMORY_SESSION_ID` on
    /// startup. Unset → no sessionId injection (server keeps its prior
    /// agent-passes-it-or-nothing semantics).
    session_id: Option<String>,
}

impl Config {
    fn from_env() -> Self {
        let base_url = env::var("MEMORY_BASE_URL")
            .unwrap_or_else(|_| "http://127.0.0.1:17180".to_string());
        Self {
            base_url,
            timeout_secs: env::var("MEMORY_TIMEOUT_SECS")
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(120),
            session_id: env::var("MEMORY_SESSION_ID")
                .ok()
                .filter(|s| !s.is_empty()),
        }
    }
}

// ---------------------------------------------------------------------------
// /recall/kinds response types
// ---------------------------------------------------------------------------

/// Recency configuration for a kind.
#[derive(Debug, Clone, Deserialize)]
pub struct RecencyInfo {
    pub enable: bool,
    #[serde(rename = "halfLifeDays")]
    pub half_life_days: u32,
}

/// Per-kind metadata as returned by the server's /recall/kinds endpoint.
#[derive(Debug, Clone, Deserialize)]
pub struct KindInfo {
    #[serde(rename = "pathPrefix")]
    pub path_prefix: String,
    pub recency: RecencyInfo,
    #[serde(rename = "defaultMode")]
    pub default_mode: String,
    pub explanation: String,
}

/// Pass-through backfill info from /recall/kinds — not used by mcp,
/// but required for correct deserialization (unknown fields are fine
/// with serde's deny_unknown_fields off, but having this avoids
/// silent drops when we log debug output).
#[derive(Debug, Clone, Deserialize)]
pub struct BackfillInfo {
    pub state: String,
    #[serde(rename = "lastCompletedAt")]
    pub last_completed_at: Option<String>,
    #[serde(rename = "completedHash")]
    pub completed_hash: Option<String>,
    #[serde(rename = "currentHash")]
    pub current_hash: Option<String>,
}

/// Full response from GET /recall/kinds.
#[derive(Debug, Clone, Deserialize)]
pub struct RecallKindsResponse {
    /// Sorted BTreeMap so iteration order is deterministic (alphabetical by key).
    pub kinds: BTreeMap<String, KindInfo>,
    #[serde(rename = "kindsConfigHash")]
    pub kinds_config_hash: String,
    pub backfill: BackfillInfo,
}

// ---------------------------------------------------------------------------
// Boot-time fetch of /recall/kinds with retry/backoff
// ---------------------------------------------------------------------------

/// Attempt to fetch /recall/kinds from the server with exponential
/// backoff. Up to 5 attempts; total wall-time cap ≈ 30s.
///
/// Retry delays: 200ms, 500ms, 1.2s, 3s, 7s → total ≈ 11.9s before
/// the 5th attempt; the 5th attempt timeout is included in the 30s
/// budget via the client timeout.
///
/// Returns Ok(response) on success, Err on permanent failure (all
/// retries exhausted). Never panics.
pub async fn fetch_recall_kinds(
    client: &Client,
    base_url: &str,
) -> Result<RecallKindsResponse> {
    // Short-timeout client for the boot-fetch — we don't want to burn
    // the full query timeout on metadata discovery.
    let boot_client = Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .unwrap_or_else(|_| client.clone());

    let url = format!("{base_url}{RECALL_KINDS_PATH}");
    let delays_ms: &[u64] = &[200, 500, 1200, 3000, 7000];

    let mut last_err: anyhow::Error = anyhow::anyhow!("no attempts made");
    for (attempt, &delay_ms) in delays_ms.iter().enumerate() {
        if attempt > 0 {
            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
        }
        match boot_client.get(&url).send().await {
            Ok(resp) => {
                if resp.status().is_success() {
                    match resp.json::<RecallKindsResponse>().await {
                        Ok(parsed) => return Ok(parsed),
                        Err(e) => {
                            last_err = anyhow::anyhow!("JSON parse error: {e}");
                            tracing::warn!(
                                attempt = attempt + 1,
                                err = %last_err,
                                "fetch /recall/kinds: parse failed, retrying"
                            );
                        }
                    }
                } else {
                    last_err = anyhow::anyhow!("HTTP {}", resp.status());
                    tracing::warn!(
                        attempt = attempt + 1,
                        status = %resp.status(),
                        "fetch /recall/kinds: non-2xx, retrying"
                    );
                }
            }
            Err(e) => {
                last_err = anyhow::anyhow!("connection error: {e}");
                tracing::warn!(
                    attempt = attempt + 1,
                    err = %last_err,
                    "fetch /recall/kinds: connection error, retrying"
                );
            }
        }
    }

    Err(anyhow::anyhow!(
        "fetch /recall/kinds failed after {} attempts: {last_err}",
        delays_ms.len()
    ))
}

// ---------------------------------------------------------------------------
// Tool description builder
// ---------------------------------------------------------------------------

/// Base recall description (without the TYPE section).
const RECALL_BASE_DESC: &str = "Use whenever the user's question depends on something in their long-term memory — anything they have written down, decided, planned, or noted. Use even if the user does not say \"recall\" / \"check\" / \"look up\". Even if you think you already know, if the answer depends on user-specific facts you MUST recall first.\n\nTHE CHUNK IS THE ANSWER. The `answer` block + each result's `excerpt` are what you respond from. Do NOT follow up with `read`/`cat`/`find`/`grep` against the source. If the user explicitly asks for the full file, use the result's `absolutePath` field VERBATIM — never reconstruct paths from `source` URIs or training data.\n\nABSTENTION (structural, not confidence): before answering any non-trivial question that depends on user-specific context, ask whether you can point to the exact passage in THIS conversation. If no — recall.\n\nRESPONSE FIELDS: `excerpt` (cite directly) · `source` (citation URI for provenance, never a shell input) · `absolutePath` (resolved local path when present; only safe filesystem input; absent → external source) · `lastModified` (when results disagree, prefer the most recent — older entries are stale, not conflicting).\n\nFor multi-hop synthesis, diff-style questions, or when a recall leaves sub-claims unsupported, use the `/claude-code-memory:recall-and-think` skill instead of stitching ad-hoc recalls. For independent topics, fire parallel recalls in one turn (recall is wait-free).";

/// Build the TYPE section to append to the recall tool description.
/// Returns empty string when kinds map is empty (graceful degradation).
///
/// Multi-line explanation values have internal newlines replaced with
/// spaces so each bullet stays a single logical line in the rendered
/// description. This keeps the tool description clean for JSON
/// serialisation (no embedded newlines in a JSON string bullet).
pub fn build_type_section(kinds: &BTreeMap<String, KindInfo>) -> String {
    if kinds.is_empty() {
        return String::new();
    }

    let mut out = String::from(
        "\n\nTYPE (optional, kind filter): when set, restricts recall to documents \
         of that kind. Each kind has its own defaults for retrieval depth and \
         recency. Omit to query all documents.\n\n\
         PARALLELISE: for temporal queries (\"what's recent in X\", \"when did \
         we Y\", \"development of Z\"), batch a type-filtered call alongside the \
         default untyped call.\n\n\
         Kinds:",
    );

    // BTreeMap iterates in sorted (alphabetical) order — deterministic.
    for (name, info) in kinds {
        // Replace internal newlines in explanation with spaces so the
        // bullet stays one logical line. This is the documented choice
        // (see Card 7 spec: "replace them with spaces").
        let flat_explanation = info.explanation.replace('\n', " ");
        out.push_str(&format!("\n  \u{2022} {name} \u{2014} {flat_explanation}"));
    }

    out
}

/// Build the full recall tool description: base + optional TYPE section.
pub fn build_recall_description(kinds: &BTreeMap<String, KindInfo>) -> String {
    let type_section = build_type_section(kinds);
    format!("{RECALL_BASE_DESC}{type_section}")
}

#[derive(Debug, Deserialize)]
struct JsonRpcRequest {
    jsonrpc: String,
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Serialize)]
struct JsonRpcResponse {
    jsonrpc: &'static str,
    id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<JsonRpcError>,
}

#[derive(Debug, Serialize)]
struct JsonRpcError {
    code: i32,
    message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<Value>,
}

fn ok(id: Value, result: Value) -> JsonRpcResponse {
    JsonRpcResponse { jsonrpc: "2.0", id, result: Some(result), error: None }
}

fn err(id: Value, code: i32, message: impl Into<String>) -> JsonRpcResponse {
    JsonRpcResponse {
        jsonrpc: "2.0",
        id,
        result: None,
        error: Some(JsonRpcError { code, message: message.into(), data: None }),
    }
}

/// Build the full tools/list response. Accepts the live kinds map so
/// that the recall description can be templated with discovered kinds.
/// An empty map produces the base description only (no TYPE section) —
/// graceful degradation for the server-unreachable case.
fn tool_definitions(kinds: &BTreeMap<String, KindInfo>) -> Value {
    let recall_desc = build_recall_description(kinds);

    // Build type param only when kinds are available.
    let type_param: Option<Value> = if kinds.is_empty() {
        None
    } else {
        let valid_kinds: Vec<&str> = kinds.keys().map(|s| s.as_str()).collect();
        Some(json!({
            "type": "string",
            "enum": valid_kinds,
            "description": "Kind filter. Restricts recall to documents of this kind. See TYPE section in the tool description."
        }))
    };

    // Build the properties object dynamically; add type + recencyBoost
    // only when kinds are known.
    let mut props = json!({
        "question": { "type": "string", "description": "Natural-language question. Keep the user's wording when possible — it often retrieves better than aggressive paraphrase." },
        "mode": {
            "type": "string",
            "enum": ["default", "quick"],
            "default": "default",
            "description": "`default`: Returns a synthesised answer with full multi-hop reasoning across the knowledge graph. Handles complex, associative, or multi-step questions. ~6s. `quick`: Returns fast keyword-matched excerpts directly, without synthesis. Use for straightforward lookups or existence checks. ~50ms."
        },
        "max_results": { "type": "integer", "default": 8, "description": "Top-K seeds. 5-10 typical." },
        "as_of": { "type": "string", "format": "date-time", "description": "RFC 3339; only consider chunks valid at-or-after this time. Use whenever the user references time ('today', 'since X')." },
        "max_versions_per_doc": { "type": "integer", "default": 1, "description": "Per source doc, how many recent versions to consider. 1 = current only (default). ≥2 for diff-style questions ('what changed in X')." }
    });

    if let Some(type_val) = type_param {
        props["type"] = type_val;
        props["recencyBoost"] = json!({
            "type": "boolean",
            "description": "When true, applies recency rerank (score *= 0.5^(age_days / halfLifeDays)) after chunk selection. Overrides the kind's default. Useful for 'what's recent' queries when type is set."
        });
    }

    json!({
        "tools": [
            {
                "name": "recall",
                "description": recall_desc,
                "inputSchema": {
                    "type": "object",
                    "properties": props,
                    "required": ["question"]
                }
            },
            // `remember` and `forget` are intentionally NOT advertised
            // in this list. The Obsidian gateway plugin owns ingest +
            // delete: the agent writes/edits/removes Markdown files in
            // the user's recorded material via its normal Write/Edit/
            // Bash(rm) tools, and the gateway picks up vault.on()
            // events to propagate add/modify/delete to the index with
            // block-level diffing. Embedding ingest is fast (1-2s) so
            // write-then-recall in the same turn is unnecessary — the
            // agent already knows what it just wrote.
            //
            // The handlers below in call_tool() are preserved so the
            // surface can be re-exposed (one-line change here adding
            // back the entries) if the design changes.
            {
                "name": "status",
                "description": "Memory health stats (entry counts, entity counts, relationship counts, vector counts) + `lastBuiltAt`. DO NOT call as a warm-up before `recall` — only call when the user explicitly asks about memory size / build state, or to disambiguate empty-memory vs no-match after a 0-hit recall.",
                "inputSchema": { "type": "object", "properties": {} }
            },
            {
                "name": "log_action",
                "description": "Append a row to the active session's log file when the just-completed turn produced any of: an architectural change, a bug fix, a non-trivial doc write or edit (new file, restructured section, distilled findings — anything beyond a single-sentence tweak), a research finding, an unexpected outcome that changes the user's mental model, OR a completed user-facing deliverable (new file, code change, config edit) — INCLUDING when the deliverable was produced by a subagent you dispatched (their work counts; the log row is a SEPARATE artifact from the deliverable itself).\n\nInvoke ONLY in response to the Stop or SubagentStop hook's end-of-turn nudge. NEVER invoke proactively mid-turn — wait for the nudge. Each hook-nudged turn that meets criteria gets its own row, even if logged earlier in the session. Single-sentence tweaks, read-only operations (recall/grep/read), and trivial chores (git status, ls) do NOT trigger.\n\nThe server stamps the row's time on call arrival and resolves the log file path from cwd captured at server startup; no path or timestamp args needed. For decisions (choice between alternatives with rationale), use `log_decision` instead — decisions get their own seven-column schema.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "actions": { "type": "string", "description": "One-line verb-phrase summary of what happened this turn. For earlier-session actions, qualify in text (\"Earlier this session: …\")." },
                        "mutations": { "type": "string", "description": "Files/configs/paths touched, comma-separated. Empty for design-discussion rows that landed no mutations." },
                        "why": { "type": "string", "description": "One sentence: motivation in technical/business terms, not the literal task." },
                        "outcome": { "type": "string", "description": "One phrase: what concretely landed." },
                        "related": { "type": "array", "items": { "type": "string" }, "description": "Wiki-link targets (e.g. `My Note Title`). Server wraps each in `[[…]]` and unions into the file's frontmatter `topics:`. Empty array is fine." }
                    },
                    "required": ["actions", "why", "outcome"]
                }
            },
            {
                "name": "log_decision",
                "description": "Append a Decision row to the active session's log file when the just-completed turn made a decision — a choice between alternatives with rationale + rollout + rollback. Decisions live in the log (with their temporal context), NOT as sibling knowledge notes.\n\nInvoke ONLY in response to the Stop or SubagentStop hook's end-of-turn nudge — never mid-turn. For non-decision turns (architectural change / bug fix / config edit / deliverable / etc. without a choice between options), use `log_action` instead.\n\nThe server stamps the Time column and resolves the log file path automatically; the schema-matching append rule inserts a fresh Decisions table header if the latest table in the file is a Log table (or vice versa) — alternating chronological flow comes out of that for free.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "context": { "type": "string", "description": "What problem prompted the choice. 1–2 sentences." },
                        "options": { "type": "string", "description": "Alternatives genuinely considered. Inline format: `A: <name> — <one-line reason rejected/kept> / B: … / C: …`. Only options that were really on the table." },
                        "decision": { "type": "string", "description": "Chosen option + one-paragraph rationale. Falsifiable reasoning, not \"because it's better\"." },
                        "rollout": { "type": "string", "description": "Concrete steps the decision triggers. Use \"N/A — <reason>\" when nothing to roll out." },
                        "rollback": { "type": "string", "description": "Concrete reverse steps if the decision turns out wrong. Use \"N/A — <reason>\" when truly inapplicable." },
                        "related": { "type": "array", "items": { "type": "string" }, "description": "Wiki-link targets. Server wraps in `[[…]]` and unions into frontmatter." }
                    },
                    "required": ["context", "options", "decision"]
                }
            }
        ]
    })
}

async fn call_tool(
    client: &Client,
    cfg: &Config,
    log_ctx: Option<&LogContext>,
    name: &str,
    args: &Value,
    kinds: &BTreeMap<String, KindInfo>,
) -> Result<Value> {
    // log_action / log_decision are local file-IO tools — they don't
    // talk to graphrag-server. Short-circuit here BEFORE the REST
    // dispatch so the http client/timeout doesn't enter the path.
    match name {
        "log_action" => {
            let parsed: LogActionArgs = serde_json::from_value(args.clone())
                .map_err(|e| anyhow::anyhow!("invalid_field: {e}"))?;
            return logging::handle_log_action(log_ctx, parsed).await;
        }
        "log_decision" => {
            let parsed: LogDecisionArgs = serde_json::from_value(args.clone())
                .map_err(|e| anyhow::anyhow!("invalid_field: {e}"))?;
            return logging::handle_log_decision(log_ctx, parsed).await;
        }
        _ => {}
    }

    let base = &cfg.base_url;
    let resp_value = match name {
        "recall" => {
            // Single parametric retrieval tool. Maps the agent-facing
            // mode names onto graphrag-server's /api/query mode field.
            //
            // Agent-facing → server mode:
            //   default → hipporag  (full multi-hop synthesis via HippoRAG)
            //   quick   → search    (fast vector-keyword excerpt lookup, no LLM)
            //
            // Removed mappings (hipporag-consolidation plan):
            //   thorough → mix     (was: hybrid + raw chunk recall)
            //   local    → local   (was: entity-vector seeded only)
            //   simple   → search  (was: vector excerpts, no LLM)
            //   deep     → hipporag (was: multi-hop HippoRAG, now the default)
            let agent_mode = args.get("mode").and_then(|v| v.as_str()).unwrap_or("default");
            let server_mode = match agent_mode {
                "default" => "hipporag",
                "quick" => "search",
                other => anyhow::bail!(
                    "unknown mode: {other} (expected one of: default, quick)"
                ),
            };
            // Forward optional history-aware params verbatim. Default
            // (both unset) preserves the per-doc current-only behavior.
            let mut body = json!({
                "query": args.get("question").and_then(|v| v.as_str()).unwrap_or(""),
                "top_k": args.get("max_results").and_then(|v| v.as_u64()).unwrap_or(8),
                "mode": server_mode,
            });
            if let Some(v) = args.get("as_of") {
                body["asOf"] = v.clone();
            }
            if let Some(v) = args.get("max_versions_per_doc") {
                body["maxVersionsPerDoc"] = v.clone();
            }
            // Tag the recall with our session id so the server's lease
            // table picks up (block_id, etag) per hit. The companion
            // `/lease/check` / `/events/stream` endpoints can then tell
            // a hook script which previously cited blocks have since
            // changed. No-op when MEMORY_SESSION_ID is unset.
            if let Some(sid) = &cfg.session_id {
                body["sessionId"] = json!(sid);
            }
            // Card 7: forward optional `type` as `sourceKind` if the
            // kinds map is non-empty AND the value is a known kind.
            // Unknown kind values produce a 400 from the server — we
            // let that propagate as-is so the agent learns.
            if !kinds.is_empty() {
                if let Some(kind_val) = args.get("type").and_then(|v| v.as_str()) {
                    body["sourceKind"] = json!(kind_val);
                }
            }
            // Card 7: forward optional `recencyBoost` verbatim.
            // The server applies the recency rerank when this is true.
            if !kinds.is_empty() {
                if let Some(rb) = args.get("recencyBoost").and_then(|v| v.as_bool()) {
                    body["recencyBoost"] = json!(rb);
                }
            }
            let r = client.post(format!("{base}/api/query")).json(&body).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "status" => {
            let r = client.get(format!("{base}/api/graph/stats")).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "remember" => {
            // Server's /api/documents requires a `source` URI for
            // content-form ingest (provenance) — but path-form
            // synthesizes one from the file path. Auto-synthesize
            // an `mcp://generated/<uuid>` URI for content-form
            // calls when the caller didn't supply one, so the
            // agent contract stays as just `content` + `title`
            // without exposing implementation details. Decision
            // 2026-05-10 — see GraphRAG-rs Memory System Roadmap.
            let mut body = args.clone();
            let has_content = body.get("content").is_some();
            let has_source = body.get("source").is_some();
            if has_content && !has_source {
                let synthesized = format!("mcp://generated/{}", uuid::Uuid::new_v4());
                body["source"] = json!(synthesized);
            }
            let r = client.post(format!("{base}/api/documents")).json(&body).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "forget" => {
            let id = args.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let r = client.delete(format!("{base}/api/documents/{id}")).send().await?;
            r.error_for_status()?.json::<Value>().await.unwrap_or(json!({"deleted": id}))
        }
        other => anyhow::bail!("unknown tool: {other}"),
    };

    let pretty = serde_json::to_string_pretty(&resp_value)
        .unwrap_or_else(|_| resp_value.to_string());
    let body = if name == "recall" {
        let preamble = build_recall_preamble(&resp_value);
        if preamble.is_empty() {
            pretty
        } else {
            format!("{preamble}\n\n{pretty}")
        }
    } else {
        pretty
    };

    Ok(json!({
        "content": [{ "type": "text", "text": body }],
        "isError": false
    }))
}

/// Build a plaintext preamble that goes ABOVE the JSON dump in the
/// recall tool response. This is the first thing the agent reads.
///
/// Why: the response payload pretty-prints to ~10 KB with 8 results,
/// and the `absolutePath` field on each result ends up buried mid-
/// blob. Empirical failure mode (2026-05-07): a small/quantized local
/// model (Q3 27B on llama.cpp `--parallel 1`, when the Spark fallover
/// path is active) confabulates a familiar-looking path from training
/// data (`/Users/jk/testbed/...`) instead of using the field. The
/// preamble surfaces the resolved paths up-front so the model can't
/// miss them.
///
/// Format:
///
///   READABLE FILES (absolute paths — pass these verbatim to your read
///   tool ONLY if the chunk excerpts are insufficient. Do NOT guess
///   paths from `source` URIs or training data.):
///     • /home/data01/Notes/<...>.md
///     • ...
///
///   THE CHUNKS BELOW ARE THE ANSWER for most queries — read them
///   first, only escalate to a file read if the user explicitly asked
///   for the full document or the excerpts are clearly truncated mid-
///   content the user needs.
///
/// Returns "" when the response has no `results[]` with `absolutePath`
/// (e.g. all sources are external https/arxiv URIs, or the response
/// is an error). The caller skips the preamble in that case.
fn build_recall_preamble(resp: &Value) -> String {
    let results = match resp.get("results").and_then(|v| v.as_array()) {
        Some(rs) if !rs.is_empty() => rs,
        _ => return String::new(),
    };
    let mut paths: Vec<&str> = Vec::new();
    for r in results {
        if let Some(p) = r.get("absolutePath").and_then(|v| v.as_str()) {
            if !paths.contains(&p) {
                paths.push(p);
            }
        }
    }
    if paths.is_empty() {
        return String::new();
    }
    let mut out = String::from(
        "READABLE FILES (absolute paths — pass these verbatim to your read tool \
         ONLY if the chunk excerpts below are insufficient. Do NOT guess paths \
         from `source` URIs or training data; do NOT prepend cwd to relative-\
         looking strings.):\n",
    );
    for p in &paths {
        out.push_str("  • ");
        out.push_str(p);
        out.push('\n');
    }
    out.push_str(
        "\nTHE CHUNK EXCERPTS BELOW ARE THE ANSWER for most queries — read \
         them first, only escalate to a file read if the user explicitly asked \
         for the full document or the excerpts are clearly truncated mid-\
         content the user needs.",
    );
    out
}

async fn handle(
    req: JsonRpcRequest,
    client: &Client,
    cfg: &Config,
    log_ctx: Option<&LogContext>,
    kinds: &BTreeMap<String, KindInfo>,
) -> Option<JsonRpcResponse> {
    if req.jsonrpc != "2.0" {
        return req.id.map(|id| err(id, -32600, "invalid jsonrpc version"));
    }
    let id = req.id.clone().unwrap_or(Value::Null);

    match req.method.as_str() {
        "initialize" => Some(ok(id, json!({
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": { "tools": {} },
            "serverInfo": { "name": SERVER_NAME, "version": SERVER_VERSION }
        }))),
        "notifications/initialized" => None,
        "tools/list" => Some(ok(id, tool_definitions(kinds))),
        "tools/call" => {
            let name = req.params.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let args = req.params.get("arguments").cloned().unwrap_or(json!({}));
            match call_tool(client, cfg, log_ctx, name, &args, kinds).await {
                Ok(v) => Some(ok(id, v)),
                Err(e) => Some(ok(id, json!({
                    "content": [{ "type": "text", "text": format!("error: {e:#}") }],
                    "isError": true
                }))),
            }
        }
        other => Some(err(id, -32601, format!("method not found: {other}"))),
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("MEMORY_MCP_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cfg = Config::from_env();
    let log_ctx = match LogContext::from_env_and_cwd() {
        Ok(Some(ctx)) => {
            tracing::info!(
                log_root = %ctx.session_log_root.display(),
                host = %ctx.host,
                project = %ctx.project,
                session_start = %ctx.session_start_hhmmss,
                "log_action / log_decision enabled",
            );
            Some(ctx)
        }
        Ok(None) => {
            tracing::warn!(
                "MEMORY_SESSION_LOG_ROOT not set — log_action / log_decision will refuse with `logging_disabled`. recall / status unaffected."
            );
            None
        }
        Err(e) => {
            tracing::warn!(err = ?e, "could not derive LogContext — log_action / log_decision will refuse");
            None
        }
    };
    tracing::info!(base_url = %cfg.base_url, "memory-mcp starting");

    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(cfg.timeout_secs))
        .build()?;

    // Boot-time fetch of /recall/kinds. On failure: log a warning and
    // continue without the type param (graceful degradation per PRD
    // Decision 9). On success: use the kinds to template the recall
    // tool description.
    let kinds: BTreeMap<String, KindInfo> =
        match fetch_recall_kinds(&client, &cfg.base_url).await {
            Ok(resp) => {
                tracing::info!(
                    kinds_count = resp.kinds.len(),
                    config_hash = %resp.kinds_config_hash,
                    backfill_state = %resp.backfill.state,
                    "fetched /recall/kinds"
                );
                resp.kinds
            }
            Err(e) => {
                tracing::warn!(
                    err = %e,
                    "failed to fetch /recall/kinds after retries — \
                     registering recall tool WITHOUT type param (graceful degradation). \
                     Restart memory-mcp to retry."
                );
                BTreeMap::new()
            }
        };

    let stdin = tokio::io::stdin();
    let mut reader = BufReader::new(stdin);
    let mut stdout = tokio::io::stdout();
    let mut line = String::new();

    loop {
        line.clear();
        let n = reader.read_line(&mut line).await?;
        if n == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let response = match serde_json::from_str::<JsonRpcRequest>(trimmed) {
            Ok(req) => handle(req, &client, &cfg, log_ctx.as_ref(), &kinds).await,
            Err(e) => Some(err(Value::Null, -32700, format!("parse error: {e}"))),
        };

        if let Some(resp) = response {
            let bytes = serde_json::to_vec(&resp)?;
            stdout.write_all(&bytes).await?;
            stdout.write_all(b"\n").await?;
            stdout.flush().await?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    // ---------------------------------------------------------------------------
    // Helper: extract the `mode` enum variants from tool_definitions().
    // ---------------------------------------------------------------------------
    fn recall_mode_enum() -> Vec<String> {
        let defs = tool_definitions(&BTreeMap::new());
        let tools = defs["tools"].as_array().expect("tools array");
        let recall = tools.iter().find(|t| t["name"] == "recall").expect("recall tool");
        recall["inputSchema"]["properties"]["mode"]["enum"]
            .as_array()
            .expect("mode enum array")
            .iter()
            .map(|v| v.as_str().expect("string variant").to_owned())
            .collect()
    }

    // ---------------------------------------------------------------------------
    // Test 1 — schema: mode enum must be exactly ["default", "quick"]
    // ---------------------------------------------------------------------------
    #[test]
    fn test_mode_enum_is_default_and_quick_only() {
        let variants = recall_mode_enum();
        assert_eq!(
            variants,
            vec!["default".to_string(), "quick".to_string()],
            "mode enum must be exactly [\"default\", \"quick\"], got {variants:?}"
        );
        // Removed modes must NOT appear.
        for removed in &["thorough", "local", "simple", "deep"] {
            assert!(
                !variants.contains(&removed.to_string()),
                "mode enum must NOT contain removed mode '{removed}'"
            );
        }
    }

    // ---------------------------------------------------------------------------
    // Test 2 — description: must contain new descriptions for "default" and
    // "quick" and must NOT contain implementation names or removed mode names.
    // ---------------------------------------------------------------------------
    #[test]
    fn test_mode_description_clean() {
        let defs = tool_definitions(&BTreeMap::new());
        let tools = defs["tools"].as_array().expect("tools array");
        let recall = tools.iter().find(|t| t["name"] == "recall").expect("recall tool");
        let mode_desc = recall["inputSchema"]["properties"]["mode"]["description"]
            .as_str()
            .expect("mode description string");

        // Must mention both public-facing mode names.
        assert!(
            mode_desc.contains("default"),
            "mode description must mention 'default'"
        );
        assert!(
            mode_desc.contains("quick"),
            "mode description must mention 'quick'"
        );

        // Must NOT contain internal server mode names or removed agent modes.
        for forbidden in &["hipporag", "hybrid", "mix", "thorough", "local", "simple", "deep"] {
            assert!(
                !mode_desc.contains(forbidden),
                "mode description must NOT contain '{forbidden}'"
            );
        }
    }

    // ---------------------------------------------------------------------------
    // Test 3 — integration: recall with mode:"default" sends mode:"hipporag"
    // ---------------------------------------------------------------------------
    #[tokio::test]
    async fn test_default_mode_round_trips_to_hipporag() {
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("local addr");
        let (tx, rx) = tokio::sync::oneshot::channel::<String>();

        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept");
            let mut buf = vec![0u8; 4096];
            let n = stream.read(&mut buf).await.expect("read");
            let raw = String::from_utf8_lossy(&buf[..n]);
            let body_str = raw.split("\r\n\r\n").nth(1).unwrap_or("{}");
            let body: serde_json::Value =
                serde_json::from_str(body_str.trim_end_matches('\0'))
                    .unwrap_or(serde_json::Value::Null);
            let mode = body
                .get("mode")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_owned();
            let _ = tx.send(mode);
            let response_body = r#"{"results":[],"answer":""}"#;
            let http_resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                response_body.len(),
                response_body
            );
            stream.write_all(http_resp.as_bytes()).await.expect("write");
        });

        let cfg = Config {
            base_url: format!("http://{addr}"),
            timeout_secs: 10,
            session_id: None,
        };
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .expect("client");

        let args = serde_json::json!({
            "question": "what are my current priorities?",
            "mode": "default"
        });

        let _result = call_tool(&client, &cfg, None, "recall", &args, &BTreeMap::new())
            .await
            .expect("call_tool");

        let captured_mode = rx.await.expect("mode captured");
        assert_eq!(
            captured_mode, "hipporag",
            "expected server-side mode 'hipporag' for agent mode 'default' but got '{captured_mode}'"
        );
    }

    // ---------------------------------------------------------------------------
    // Test 4 — integration: recall with mode:"quick" sends mode:"search"
    // ---------------------------------------------------------------------------
    #[tokio::test]
    async fn test_quick_mode_round_trips_to_search() {
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("local addr");
        let (tx, rx) = tokio::sync::oneshot::channel::<String>();

        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept");
            let mut buf = vec![0u8; 4096];
            let n = stream.read(&mut buf).await.expect("read");
            let raw = String::from_utf8_lossy(&buf[..n]);
            let body_str = raw.split("\r\n\r\n").nth(1).unwrap_or("{}");
            let body: serde_json::Value =
                serde_json::from_str(body_str.trim_end_matches('\0'))
                    .unwrap_or(serde_json::Value::Null);
            let mode = body
                .get("mode")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_owned();
            let _ = tx.send(mode);
            let response_body = r#"{"results":[],"answer":""}"#;
            let http_resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                response_body.len(),
                response_body
            );
            stream.write_all(http_resp.as_bytes()).await.expect("write");
        });

        let cfg = Config {
            base_url: format!("http://{addr}"),
            timeout_secs: 10,
            session_id: None,
        };
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .expect("client");

        let args = serde_json::json!({
            "question": "does note X exist?",
            "mode": "quick"
        });

        let _result = call_tool(&client, &cfg, None, "recall", &args, &BTreeMap::new())
            .await
            .expect("call_tool");

        let captured_mode = rx.await.expect("mode captured");
        assert_eq!(
            captured_mode, "search",
            "expected server-side mode 'search' for agent mode 'quick' but got '{captured_mode}'"
        );
    }

    // ---------------------------------------------------------------------------
    // Test 5 — unknown mode returns an error (not a panic)
    // ---------------------------------------------------------------------------
    #[tokio::test]
    async fn test_unknown_mode_returns_error() {
        // No server needed — the error fires before any HTTP call.
        let cfg = Config {
            base_url: "http://127.0.0.1:1".to_string(), // unreachable port
            timeout_secs: 1,
            session_id: None,
        };
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(1))
            .build()
            .expect("client");

        let args = serde_json::json!({
            "question": "test",
            "mode": "deep"  // was valid before, must now be unknown
        });

        let result = call_tool(&client, &cfg, None, "recall", &args, &BTreeMap::new()).await;
        assert!(
            result.is_err(),
            "expected an error for removed mode 'deep' but got Ok"
        );
        let err_msg = result.unwrap_err().to_string();
        assert!(
            err_msg.contains("unknown mode"),
            "error message should mention 'unknown mode', got: {err_msg}"
        );
    }

    // =========================================================================
    // Card 7 — card7_kinds_render_tests
    // =========================================================================

    /// Build a test KindInfo for use in Card 7 tests.
    fn make_kind_info(path_prefix: &str, explanation: &str) -> KindInfo {
        KindInfo {
            path_prefix: path_prefix.to_string(),
            recency: RecencyInfo { enable: true, half_life_days: 365 },
            default_mode: "hipporag".to_string(),
            explanation: explanation.to_string(),
        }
    }

    // ---------------------------------------------------------------------------
    // Card 7 Test 1 — single kind: rendered description contains name,
    // explanation, TYPE header, and PARALLELISE hint.
    // ---------------------------------------------------------------------------
    #[test]
    fn test_card7_single_kind_description_contains_required_substrings() {
        let mut kinds = BTreeMap::new();
        kinds.insert(
            "log".to_string(),
            make_kind_info(
                "/home/data01/Notes/\u{1f4d4} Journal/agent-log",
                "Session-based chronological log files. Query when the user asks about recent changes.",
            ),
        );

        let desc = build_recall_description(&kinds);

        assert!(
            desc.contains("log"),
            "description must contain kind name 'log'"
        );
        assert!(
            desc.contains("Session-based chronological log files"),
            "description must contain the kind's explanation"
        );
        assert!(
            desc.contains("TYPE (optional, kind filter)"),
            "description must contain the TYPE header"
        );
        assert!(
            desc.contains("PARALLELISE"),
            "description must contain the PARALLELISE hint"
        );
    }

    // ---------------------------------------------------------------------------
    // Card 7 Test 2 — multi-kind: two kinds both appear, sorted alphabetically.
    // ---------------------------------------------------------------------------
    #[test]
    fn test_card7_multi_kind_sorted_alphabetically() {
        let mut kinds = BTreeMap::new();
        kinds.insert(
            "research".to_string(),
            make_kind_info(
                "/home/data01/Notes/\u{1f5c2}\u{fe0f} Collection",
                "Permanent research notes and architectural insights.",
            ),
        );
        kinds.insert(
            "log".to_string(),
            make_kind_info(
                "/home/data01/Notes/\u{1f4d4} Journal/agent-log",
                "Session-based chronological log files.",
            ),
        );

        let desc = build_recall_description(&kinds);

        // Both bullets must appear.
        assert!(
            desc.contains("• log"),
            "description must contain bullet for 'log'"
        );
        assert!(
            desc.contains("• research"),
            "description must contain bullet for 'research'"
        );

        // Alphabetical order: 'log' before 'research'.
        let pos_log = desc.find("• log").expect("• log present");
        let pos_research = desc.find("• research").expect("• research present");
        assert!(
            pos_log < pos_research,
            "kinds must appear in alphabetical order: 'log' ({pos_log}) before 'research' ({pos_research})"
        );

        // Explanations both appear.
        assert!(
            desc.contains("Session-based chronological log files"),
            "log explanation must appear"
        );
        assert!(
            desc.contains("Permanent research notes"),
            "research explanation must appear"
        );
    }

    // ---------------------------------------------------------------------------
    // Card 7 Test 3 — empty kinds: description does NOT contain the TYPE section.
    // ---------------------------------------------------------------------------
    #[test]
    fn test_card7_empty_kinds_no_type_section() {
        let kinds: BTreeMap<String, KindInfo> = BTreeMap::new();
        let desc = build_recall_description(&kinds);

        assert!(
            !desc.contains("TYPE (optional, kind filter)"),
            "empty kinds must NOT produce TYPE section in description"
        );
        assert!(
            !desc.contains("PARALLELISE"),
            "empty kinds must NOT produce PARALLELISE hint"
        );
        // But the base description must still be present.
        assert!(
            desc.contains("long-term memory"),
            "base description must still be present for empty kinds"
        );
    }

    // ---------------------------------------------------------------------------
    // Card 7 Test 4 — multiline explanation has newlines flattened to spaces.
    // ---------------------------------------------------------------------------
    #[test]
    fn test_card7_multiline_explanation_flattened() {
        let mut kinds = BTreeMap::new();
        kinds.insert(
            "log".to_string(),
            make_kind_info(
                "/some/path",
                "First line of explanation.\nSecond line of explanation.",
            ),
        );

        let type_section = build_type_section(&kinds);

        // The newline between the two sentences must be replaced with a space.
        assert!(
            type_section.contains("First line of explanation. Second line of explanation."),
            "multiline explanation newlines must be replaced with spaces, got: {type_section:?}"
        );
        // The raw newline must NOT appear inside a bullet.
        // (The section itself has structural newlines but the explanation
        // value specifically must not contribute extra newlines.)
        let bullet_line = type_section
            .lines()
            .find(|l| l.contains("• log"))
            .expect("bullet for 'log' must exist");
        assert!(
            bullet_line.contains("First line") && bullet_line.contains("Second line"),
            "both explanation parts must appear on the same bullet line: {bullet_line:?}"
        );
    }

    // ---------------------------------------------------------------------------
    // Card 7 Test 5 — type param absent from schema when kinds empty.
    // ---------------------------------------------------------------------------
    #[test]
    fn test_card7_no_type_param_when_kinds_empty() {
        let defs = tool_definitions(&BTreeMap::new());
        let tools = defs["tools"].as_array().expect("tools array");
        let recall = tools.iter().find(|t| t["name"] == "recall").expect("recall tool");
        let props = &recall["inputSchema"]["properties"];

        assert!(
            props.get("type").is_none(),
            "type param must NOT appear in schema when kinds are empty"
        );
        assert!(
            props.get("recencyBoost").is_none(),
            "recencyBoost param must NOT appear in schema when kinds are empty"
        );
    }

    // ---------------------------------------------------------------------------
    // Card 7 Test 6 — type param present in schema when kinds are populated.
    // ---------------------------------------------------------------------------
    #[test]
    fn test_card7_type_param_present_when_kinds_populated() {
        let mut kinds = BTreeMap::new();
        kinds.insert("log".to_string(), make_kind_info("/some/path", "Log files."));

        let defs = tool_definitions(&kinds);
        let tools = defs["tools"].as_array().expect("tools array");
        let recall = tools.iter().find(|t| t["name"] == "recall").expect("recall tool");
        let props = &recall["inputSchema"]["properties"];

        assert!(
            props.get("type").is_some(),
            "type param MUST appear in schema when kinds are populated"
        );
        assert!(
            props.get("recencyBoost").is_some(),
            "recencyBoost param MUST appear in schema when kinds are populated"
        );

        // Enum must list the known kind names.
        let type_enum = props["type"]["enum"].as_array().expect("type enum array");
        assert!(
            type_enum.iter().any(|v| v.as_str() == Some("log")),
            "type enum must include 'log'"
        );
    }

    // ---------------------------------------------------------------------------
    // Card 7 Test 7 — sourceKind forwarded in POST body when type is set.
    // ---------------------------------------------------------------------------
    #[tokio::test]
    async fn test_card7_source_kind_forwarded_in_post_body() {
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("local addr");
        let (tx, rx) = tokio::sync::oneshot::channel::<(Option<String>, Option<bool>)>();

        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept");
            let mut buf = vec![0u8; 4096];
            let n = stream.read(&mut buf).await.expect("read");
            let raw = String::from_utf8_lossy(&buf[..n]);
            let body_str = raw.split("\r\n\r\n").nth(1).unwrap_or("{}");
            let body: serde_json::Value =
                serde_json::from_str(body_str.trim_end_matches('\0'))
                    .unwrap_or(serde_json::Value::Null);
            let source_kind = body
                .get("sourceKind")
                .and_then(|v| v.as_str())
                .map(|s| s.to_owned());
            let recency_boost = body
                .get("recencyBoost")
                .and_then(|v| v.as_bool());
            let _ = tx.send((source_kind, recency_boost));
            let response_body = r#"{"results":[],"answer":""}"#;
            let http_resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                response_body.len(),
                response_body
            );
            stream.write_all(http_resp.as_bytes()).await.expect("write");
        });

        let cfg = Config {
            base_url: format!("http://{addr}"),
            timeout_secs: 10,
            session_id: None,
        };
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .expect("client");

        let mut kinds = BTreeMap::new();
        kinds.insert("log".to_string(), make_kind_info("/some/path", "Log files."));

        let args = serde_json::json!({
            "question": "what did we do recently?",
            "type": "log",
            "recencyBoost": true
        });

        let _result = call_tool(&client, &cfg, None, "recall", &args, &kinds)
            .await
            .expect("call_tool");

        let (captured_kind, captured_boost) = rx.await.expect("captured");
        assert_eq!(
            captured_kind.as_deref(),
            Some("log"),
            "sourceKind must be forwarded as 'log', got {captured_kind:?}"
        );
        assert_eq!(
            captured_boost,
            Some(true),
            "recencyBoost must be forwarded as true, got {captured_boost:?}"
        );
    }

    // ---------------------------------------------------------------------------
    // Card 7 Test 8 — sourceKind NOT forwarded when kinds map is empty
    // (graceful degradation: treat as if type param was never set).
    // ---------------------------------------------------------------------------
    #[tokio::test]
    async fn test_card7_source_kind_not_forwarded_when_kinds_empty() {
        use tokio::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("local addr");
        let (tx, rx) = tokio::sync::oneshot::channel::<bool>();

        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept");
            let mut buf = vec![0u8; 4096];
            let n = stream.read(&mut buf).await.expect("read");
            let raw = String::from_utf8_lossy(&buf[..n]);
            let body_str = raw.split("\r\n\r\n").nth(1).unwrap_or("{}");
            let body: serde_json::Value =
                serde_json::from_str(body_str.trim_end_matches('\0'))
                    .unwrap_or(serde_json::Value::Null);
            // true = "sourceKind was absent", false = "sourceKind was present"
            let absent = body.get("sourceKind").is_none();
            let _ = tx.send(absent);
            let response_body = r#"{"results":[],"answer":""}"#;
            let http_resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                response_body.len(),
                response_body
            );
            stream.write_all(http_resp.as_bytes()).await.expect("write");
        });

        let cfg = Config {
            base_url: format!("http://{addr}"),
            timeout_secs: 10,
            session_id: None,
        };
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .expect("client");

        // Kinds empty = graceful degradation mode.
        let kinds: BTreeMap<String, KindInfo> = BTreeMap::new();

        let args = serde_json::json!({
            "question": "what did we do recently?",
            "type": "log"  // agent passes it, but it should be ignored
        });

        let _result = call_tool(&client, &cfg, None, "recall", &args, &kinds)
            .await
            .expect("call_tool");

        let source_kind_absent = rx.await.expect("captured");
        assert!(
            source_kind_absent,
            "sourceKind must NOT be forwarded when kinds map is empty (graceful degradation)"
        );
    }

    // ---------------------------------------------------------------------------
    // Card 7 Test 9 — server-unreachable: fetch_recall_kinds returns Err
    // (not panic) for closed port. This verifies the retry path exits cleanly.
    // The actual retry backoff is tested here with a minimal 1-attempt
    // client to avoid waiting full 30s in CI — the retry logic is covered
    // by the production boot path.
    // ---------------------------------------------------------------------------
    #[tokio::test]
    async fn test_card7_fetch_kinds_returns_err_on_unreachable_server() {
        // Port 1 is reserved and should be unreachable (connection refused).
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_millis(200))
            .build()
            .expect("client");

        // We test the error path by pointing at a port that refuses connections.
        // The retry loop will fail all attempts quickly due to the short timeout.
        let result = fetch_recall_kinds(&client, "http://127.0.0.1:1").await;
        assert!(
            result.is_err(),
            "fetch_recall_kinds must return Err on unreachable server, got Ok"
        );
    }
}
