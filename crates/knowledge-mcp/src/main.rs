// Stdio MCP server exposing your local knowledge graph.
//
// Five tools, mapped onto graphrag-server's REST API:
//
//   recall    — search/answer (POST /api/query, mode-parametric)
//   remember  — ingest (POST /api/documents, polymorphic body)
//   forget    — delete one document (DELETE /api/documents/:id)
//   catalog   — list ingested documents (GET /api/documents)
//   status    — graph counts + last-built timestamp (GET /api/graph/stats)
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
                "description": "Ask the local knowledge graph a question. Returns an LLM-composed answer plus confidence, key entities, and sources.\n\nMode picks retrieval strategy:\n  • `default` — graph-aware hybrid (entity + relationship). Start here.\n  • `thorough` — `default` + raw chunk-vector recall. Use when `default` came back low-confidence and you suspect the answer is in the corpus, or for compound multi-hop questions (\"compare A and B\", \"timeline of X\").\n  • `local` — entity-centric (skips keyword extraction). Use when the question is about a specific named entity already in the graph.\n  • `simple` — vector excerpts, no LLM (~350ms). Use to cheaply check whether the corpus has anything on a topic.\n\nTime/history filters — USE THESE whenever the user asks about \"today\", \"yesterday\", \"since X\", \"this week\", \"what changed\", or wants to compare versions:\n  • `as_of` — RFC 3339 (e.g. `\"2026-05-06T00:00:00Z\"` for \"today\"). Only consider chunks valid at-or-after this time.\n  • `max_versions_per_doc` — defaults to 1 (current only). Set ≥2 for diff-style questions (\"what changed in doc X\") so prior versions are visible.\n\nPARALLELIZE — independent recall questions run server-side without contention. If the user asks about several distinct topics, fire one recall per topic in the same tool batch and wait, instead of serializing them.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": { "type": "string", "description": "Natural-language question. Your phrasing usually retrieves better than aggressive paraphrase." },
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
                "description": "Save doc(s) to the local knowledge graph. Recallable shortly after — no follow-up call needed.\n\nPick one body shape:\n  ✅ `path` — file on disk\n  ✅ `paths_glob` — glob like `/abs/dir/**/*.md`\n  ✅ `paths` — explicit list of files\n  ✅ `content` + `title` — generated/pasted text\n  ❌ Read+forward via `content` — use `path` instead.\n\nBatch response: `results[]`, per-entry `status` ∈ {ingested, duplicate, unsupported, rejected, error}.",
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
                "name": "catalog",
                "description": "Page through what's in the local knowledge graph — id, title, ~160-char excerpt. Capped at 256 entries (use `recall` to drill deeper). Use to discover what's already there before deciding to `remember` something that may already be present.",
                "inputSchema": { "type": "object", "properties": {} }
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
        "catalog" => {
            let r = client.get(format!("{base}/api/documents")).send().await?;
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

    Ok(json!({
        "content": [{
            "type": "text",
            "text": serde_json::to_string_pretty(&resp_value).unwrap_or_else(|_| resp_value.to_string())
        }],
        "isError": false
    }))
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
