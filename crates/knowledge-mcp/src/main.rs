// Stdio MCP server exposing your local knowledge graph.
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
const SERVER_NAME: &str = "knowledge-mcp";
const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone)]
struct Config {
    base_url: String,
    timeout_secs: u64,
}

impl Config {
    fn from_env() -> Self {
        // KNOWLEDGE_BASE_URL is the canonical name; GRAPHRAG_BASE_URL
        // stays accepted as a fallback so existing systemd unit envs
        // and `mcp.json` files don't break the moment the binary is
        // upgraded.
        let base_url = env::var("KNOWLEDGE_BASE_URL")
            .or_else(|_| env::var("GRAPHRAG_BASE_URL"))
            .unwrap_or_else(|_| "http://127.0.0.1:8080".to_string());
        Self {
            base_url,
            timeout_secs: env::var("KNOWLEDGE_TIMEOUT_SECS")
                .or_else(|_| env::var("GRAPHRAG_TIMEOUT_SECS"))
                .ok()
                .and_then(|s| s.parse().ok())
                .unwrap_or(120),
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
                "description": "Ask the local knowledge graph a question. Returns an LLM-composed answer + confidence + sources (top-K excerpts).\n\n**THE CHUNK IS THE ANSWER.** When `recall` returns content, the `answer` block + `results[].excerpt` carry the information you need to respond to the user. Do NOT follow up with `read`/`cat`/`find`/`grep` against the source. The most common failure mode is: agent gets a good chunk, gets nervous, tries to read the file, guesses the wrong path, hits ENOENT, runs `find /` to recover, eats 30+ seconds — when the original chunk was already sufficient.\n\nFIRST RULE: when the user asks about anything stored in their personal knowledge — notes, journal, tasks, projects, prior conversations, vault contents — your FIRST tool call should be `recall`. Never `read`, `find`, `grep`, or shell against `/home/data01/Notes` or anywhere else; the corpus is indexed and the answer is one tool call away.\n\nRESPONSE SHAPE — what you get back:\n```\n{\n  \"answer\":     \"<LLM-composed answer grounded in retrieved chunks>\",\n  \"confidence\": 0.0–1.0,\n  \"results\":    [ { \"title\", \"excerpt\", \"source\", \"absolutePath\", \"lineStart\", \"blockId\", \"etag\", \"lastModified\" }, ... ],\n  \"sources\":    [ { \"id\", \"kind\": \"text_chunk|entity|relationship\", \"excerpt\", \"relevance\" }, ... ],\n  \"keyEntities\": [...],\n  \"reasoningSteps\": [...]\n}\n```\n\n**Field semantics:**\n  • `excerpt` — up to ~800 chars of chunk content. Cite from this directly.\n  • `source` — URI for citation provenance (`obsidian://vault/...`, `file://...`, `https://...`). **NEVER pass to a shell `read` / `cat`** — it's a URI, not a path. If the user wants to open the source, render it as a hyperlink.\n  • `absolutePath` — when present, the server-resolved filesystem path (under one of the configured ingest roots). Pass THIS to a `read` tool **only when the chunk is genuinely insufficient** (user asked for the full document, or the excerpt was truncated mid-content the user explicitly needs). Absent → source is external (https, arxiv, …) or not under a configured root; do not try to filesystem-read it.\n  • `lineStart` / `blockId` — navigation hints; recall again with a sharper query is usually cheaper than reading the file.\n\n**When in doubt, recall again with a sharper query** rather than reaching for the filesystem. Recall is wait-free server-side; a second targeted query is faster than a `read` + LLM-re-summarize loop.\n\nMODES — pick by question shape, not by retry pattern:\n  • `default` — LightRAG hybrid (entity + relationship). 95% of questions go here.\n  • `thorough` — hybrid + chunk-vector. Use for compound questions (\"compare A and B\", \"timeline of X\") OR when the user explicitly says they want a wide search.\n  • `local` — entity-centric, skips keyword extraction. Use when asking about a specific named entity you already know is in the graph.\n  • `simple` — vector excerpts, no LLM (~350ms). Use to cheaply probe whether anything on a topic exists in the corpus.\n\nPARALLELIZE — when the user asks several distinct things, FIRE ALL THE RECALLS IN ONE ASSISTANT TURN. Recall is wait-free server-side; sequential is purely wasted wall-clock time. Example:\n  User: \"What's on my plate this week and what's the status of project X?\"\n  ✅ Two `recall` tool calls in the same response.\n  ❌ One `recall`, wait, read it, then another `recall`.\n\nNON-DETERMINISTIC FAN-OUT — if a single recall returns 0 hits, DO NOT auto-fan-out to 5 paraphrases. That spends LLM budget without raising hit-rate. Instead: try ONE rephrasing with different keywords, or `mode: thorough`, or report the gap to the user and ask what they want.\n\nTIME / HISTORY FILTERS — use whenever the user references time:\n  • `as_of` — RFC 3339 (`\"2026-05-06T00:00:00Z\"` = \"today\"). Only chunks valid at-or-after this time.\n  • `max_versions_per_doc` — defaults to 1 (current only). Set ≥2 for diff-style questions (\"what changed in doc X\").\n\nDO NOT call `status` as a warm-up. Just `recall`.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": { "type": "string", "description": "Natural-language question. Your phrasing often retrieves better than aggressive paraphrase — keep the user's words when possible." },
                        "mode": {
                            "type": "string",
                            "enum": ["default", "thorough", "local", "simple"],
                            "default": "default"
                        },
                        "max_results": { "type": "integer", "default": 8, "description": "Top-K seeds. 5-10 typical." },
                        "as_of": { "type": "string", "format": "date-time", "description": "RFC 3339; only consider chunks updated at or after this time. Use for 'what changed since X'." },
                        "max_versions_per_doc": { "type": "integer", "default": 1, "description": "Per source doc, how many recent versions to consider. 1 = current only (default)." }
                    },
                    "required": ["question"]
                }
            },
            {
                "name": "remember",
                "description": "Save doc(s) to the local knowledge graph. Recallable within ~minute (entity extraction is async). No follow-up call needed.\n\nPick one body shape:\n  ✅ `path` — single file on disk\n  ✅ `paths_glob` — glob like `/abs/dir/**/*.md`\n  ✅ `paths` — explicit list of files\n  ✅ `content` + `title` — generated/pasted text\n  ❌ Don't read a file in your shell and forward it via `content` — use `path`. The server reads + chunks + embeds + extracts atomically.\n\nResponse: `results[]`, per-entry `status` ∈ {ingested, duplicate, unsupported, rejected, error}. `duplicate` = content_hash already known; safe to ignore.",
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
                "description": "Drop a document from the local knowledge graph. Accepts either the id you supplied to `remember` or the server-assigned UUID. Use sparingly — prefer asking the user before deleting from a personal knowledge base.",
                "inputSchema": {
                    "type": "object",
                    "properties": { "id": { "type": "string" } },
                    "required": ["id"]
                }
            },
            {
                "name": "status",
                "description": "Graph counts (documents, entities, relationships, vectors) + `lastBuiltAt`. DO NOT call as a warm-up before `recall` — only call when the user explicitly asks about graph size/build state, or to disambiguate empty-corpus vs no-match after a 0-hit recall.",
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
            let r = client.post(format!("{base}/api/query")).json(&body).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "status" => {
            let r = client.get(format!("{base}/api/graph/stats")).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "remember" => {
            let r = client.post(format!("{base}/api/documents")).json(args).send().await?;
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
            tracing_subscriber::EnvFilter::try_from_env("KNOWLEDGE_MCP_LOG")
                .or_else(|_| tracing_subscriber::EnvFilter::try_from_env("GRAPHRAG_MCP_LOG"))
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cfg = Config::from_env();
    tracing::info!(base_url = %cfg.base_url, "knowledge-mcp starting");

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
