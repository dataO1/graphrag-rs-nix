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

use anyhow::Result;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::env;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

const PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "memory-mcp";
const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");

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

fn tool_definitions() -> Value {
    json!({
        "tools": [
            {
                "name": "recall",
                "description": "Use whenever the user's question depends on something in their long-term memory — anything they have written down, decided, planned, or noted. Use even if the user does not say \"recall\" / \"check\" / \"look up\". Even if you think you already know, if the answer depends on user-specific facts you MUST recall first.\n\nTHE CHUNK IS THE ANSWER. The `answer` block + each result's `excerpt` are what you respond from. Do NOT follow up with `read`/`cat`/`find`/`grep` against the source. If the user explicitly asks for the full file, use the result's `absolutePath` field VERBATIM — never reconstruct paths from `source` URIs or training data.\n\nABSTENTION (structural, not confidence): before answering any non-trivial question that depends on user-specific context, ask whether you can point to the exact passage in THIS conversation. If no — recall.\n\nRESPONSE FIELDS: `excerpt` (cite directly) · `source` (citation URI for provenance, never a shell input) · `absolutePath` (resolved local path when present; only safe filesystem input; absent → external source) · `lastModified` (when results disagree, prefer the most recent — older entries are stale, not conflicting).\n\nFor multi-hop synthesis, diff-style questions, or when a recall leaves sub-claims unsupported, use the `/claude-code-memory:recall-and-think` skill instead of stitching ad-hoc recalls. For independent topics, fire parallel recalls in one turn (recall is wait-free).",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": { "type": "string", "description": "Natural-language question. Keep the user's wording when possible — it often retrieves better than aggressive paraphrase." },
                        "mode": {
                            "type": "string",
                            "enum": ["default", "thorough", "local", "simple"],
                            "default": "default",
                            "description": "Pick by question shape, not retry count. `default` = relational + semantic (95% of cases). `thorough` = + verbatim, for compound/wide searches. `local` = entity-centric, for a specific named entity already in memory. `simple` = verbatim only (~350ms probe), cheap topic-existence check."
                        },
                        "max_results": { "type": "integer", "default": 8, "description": "Top-K seeds. 5-10 typical." },
                        "as_of": { "type": "string", "format": "date-time", "description": "RFC 3339; only consider chunks valid at-or-after this time. Use whenever the user references time ('today', 'since X')." },
                        "max_versions_per_doc": { "type": "integer", "default": 1, "description": "Per source doc, how many recent versions to consider. 1 = current only (default). ≥2 for diff-style questions ('what changed in X')." }
                    },
                    "required": ["question"]
                }
            },
            {
                "name": "remember",
                "description": "Commit material to the user's long-term memory. Recallable within ~minute (indexing is async); no follow-up call needed.\n\nPick one body shape:\n  ✅ `path` — single file on disk\n  ✅ `paths_glob` — glob like `/abs/dir/**/*.md`\n  ✅ `paths` — explicit list of files\n  ✅ `content` + `title` — generated/pasted text\n  ❌ Don't read a file in your shell and forward it via `content` — use `path`. Ingestion reads + chunks + indexes atomically.\n\nResponse: `results[]`, per-entry `status` ∈ {ingested, duplicate, unsupported, rejected, error}. `duplicate` = content already in memory; safe to ignore.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "path":       { "type": "string", "description": "Absolute path to one file." },
                        "paths_glob": { "type": "string", "description": "Glob, e.g. `/abs/dir/**/*.md` or relative + `glob_root`." },
                        "glob_root":  { "type": "string", "description": "Anchor for relative `paths_glob`." },
                        "paths":      { "type": "array", "items": { "type": "string" }, "description": "Explicit list of absolute paths." },
                        "content":    { "type": "string", "description": "Inline body. Use only for generated/pasted text." },
                        "title":      { "type": "string", "description": "Required for `content`." },
                        "id":         { "type": "string", "description": "Optional caller-supplied id for later `forget`." }
                    }
                }
            },
            {
                "name": "forget",
                "description": "Remove an entry from the user's long-term memory. Accepts either the id supplied to `remember` or the server-assigned UUID. Use sparingly — prefer asking the user before deleting personal material.",
                "inputSchema": {
                    "type": "object",
                    "properties": { "id": { "type": "string" } },
                    "required": ["id"]
                }
            },
            {
                "name": "status",
                "description": "Memory health stats (entry counts, entity counts, relationship counts, vector counts) + `lastBuiltAt`. DO NOT call as a warm-up before `recall` — only call when the user explicitly asks about memory size / build state, or to disambiguate empty-memory vs no-match after a 0-hit recall.",
                "inputSchema": { "type": "object", "properties": {} }
            }
        ]
    })
}

async fn call_tool(client: &Client, cfg: &Config, name: &str, args: &Value) -> Result<Value> {
    let base = &cfg.base_url;
    let resp_value = match name {
        "recall" => {
            // Single parametric retrieval tool. Maps the agent-facing
            // mode names onto graphrag-server's /api/query mode field.
            //
            // Agent-facing → server mode:
            //   default     → hybrid    (LightRAG paper recommended)
            //   thorough    → mix       (hybrid + raw chunk recall)
            //   local       → local     (entity-vector seeded only)
            //   simple      → search    (vector excerpts, no LLM)
            //
            // The server's `global` mode exists for completeness but
            // is intentionally NOT exposed here — agents reliably
            // misroute to it where `default`/`thorough` answer the
            // same questions equally well.
            let agent_mode = args.get("mode").and_then(|v| v.as_str()).unwrap_or("default");
            let server_mode = match agent_mode {
                "default" => "hybrid",
                "thorough" => "mix",
                "local" => "local",
                "simple" => "search",
                other => anyhow::bail!(
                    "unknown mode: {other} (expected one of: default, thorough, local, simple)"
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

async fn handle(req: JsonRpcRequest, client: &Client, cfg: &Config) -> Option<JsonRpcResponse> {
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
        "tools/list" => Some(ok(id, tool_definitions())),
        "tools/call" => {
            let name = req.params.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let args = req.params.get("arguments").cloned().unwrap_or(json!({}));
            match call_tool(client, cfg, name, &args).await {
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
    tracing::info!(base_url = %cfg.base_url, "memory-mcp starting");

    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(cfg.timeout_secs))
        .build()?;

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
            Ok(req) => handle(req, &client, &cfg).await,
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
