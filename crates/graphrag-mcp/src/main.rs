// Stdio MCP server that proxies tool calls to a running graphrag-rs REST
// instance. Protocol: JSON-RPC 2.0 over newline-delimited stdin/stdout, MCP
// version 2024-11-05.
//
// Skeleton modeled on samyama-ai/graphrag-rs/src/mcp/. Tool implementations
// here translate to HTTP calls against automataIA/graphrag-rs's
// graphrag-server REST API (default scope /api).

use anyhow::Result;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::env;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

const PROTOCOL_VERSION: &str = "2024-11-05";
const SERVER_NAME: &str = "graphrag-mcp";
const SERVER_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Debug, Clone)]
struct Config {
    base_url: String,
    timeout_secs: u64,
}

impl Config {
    fn from_env() -> Self {
        Self {
            base_url: env::var("GRAPHRAG_BASE_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:8080".to_string()),
            timeout_secs: env::var("GRAPHRAG_TIMEOUT_SECS")
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
                "name": "query",
                "description": "Ask the user's notes a question. Returns an LLM-composed answer plus confidence (0-1), key entities, reasoning steps, and typed sources (text-chunk / entity / relationship) — confidence < 0.3 means the engine is guessing, > 0.7 means well-supported. PRIMARY retrieval tool. Mode picks the retrieval strategy:\n  • default  — Hybrid graph retrieval (entity + relationship seeds). Trusts the keyword extractor and the graph. LightRAG paper's recommended starting point. Use first.\n  • thorough — default + raw chunk-vector recall (entity + relation + chunk seeds). Distrusts the keyword extractor; adds raw-text recall as insurance. Use ONLY when `default` returned low confidence and you suspect the corpus has the answer. Slower (~5-10s vs ~4-7s).\n  • local    — Entity-centric retrieval only (entity vector index → 1-hop neighbors). Use when the question is unambiguously about a specific named entity you've already seen in the corpus. Skips the keyword-extraction LLM call.\n  • simple   — Vector excerpts, no LLM answer (~350ms, no `answer` field). Use when you want raw passages to read or quote, not a synthesized answer; or to cheaply check whether the corpus has anything on a topic before committing to a full LLM call.\nSet `reason: true` for compound multi-hop questions that need decomposition (e.g. 'compare A and B', 'timeline of X', 'how does X relate to Y') — multiple LLM round-trips, slowest. Composes with mode but currently overrides retrieval strategy.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": { "type": "string", "description": "Natural-language question. The user's own phrasing usually retrieves better than aggressive paraphrase." },
                        "mode": {
                            "type": "string",
                            "enum": ["default", "thorough", "local", "simple"],
                            "default": "default",
                            "description": "Retrieval strategy. See the tool description for which to pick. Default: `default` (hybrid)."
                        },
                        "reason": {
                            "type": "boolean",
                            "default": false,
                            "description": "Decompose the question into sub-queries, answer each, compose a final answer. Use only for genuinely compound questions; slowest path."
                        },
                        "max_results": { "type": "integer", "default": 8, "description": "Top-K source chunks/seeds the engine considers. 5-10 is typical; raise for breadth, lower for focus." }
                    },
                    "required": ["question"]
                }
            },
            {
                "name": "graph_stats",
                "description": "Counts of documents, entities, relationships, vectors plus `lastBuiltAt` (RFC 3339 of the last build/append, null pre-first-build). Use to (a) sanity-check the graph isn't empty before a query, (b) decide whether `append_graph` is needed, (c) decide whether `build_graph` is needed (only if documentCount > 0 AND entityCount == 0). Cheap.",
                "inputSchema": { "type": "object", "properties": {} }
            },
            {
                "name": "list_documents",
                "description": "Page through ingested documents — id, optional user_id, title, timestamp, ~160-char excerpt. Capped at 256 entries (use `query` to drill in beyond that). Use to discover what's indexed when the user asks 'what notes do I have on …' style questions, OR before deciding whether to ingest content that may already be present.",
                "inputSchema": { "type": "object", "properties": {} }
            },
            {
                "name": "add_document",
                "description": "Ingest one document (title + body) into the vector store. Returns the assigned id. Does NOT extract entities — that happens via `append_graph` (after a batch) or `build_graph` (cold-start). Content-hash dedup is automatic: ingesting the same content twice returns the existing id without duplicating. After a batch of add_document calls, run `append_graph` once — NOT once per document. The optional `id` field lets you supply a stable user-side id (the path you used, a UUID you assigned, etc.) so you can later delete by it.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "id": { "type": "string", "description": "Optional caller-supplied id. Stored alongside the auto-assigned UUID; either can be passed to delete_document later." },
                        "title": { "type": "string", "description": "Human-readable title shown in list_documents and query results." },
                        "content": { "type": "string", "description": "Document body (markdown / plain text). Will be chunked." }
                    },
                    "required": ["content"]
                }
            },
            {
                "name": "delete_document",
                "description": "Remove a document. Accepts either the user-supplied id (the one you passed to `add_document`) or the server-assigned UUID; the server resolves user_ids first, falls back to UUID. Use sparingly — deletion is rarely the right action for an agent on a personal knowledge base. Prefer asking the user before deleting.",
                "inputSchema": {
                    "type": "object",
                    "properties": { "id": { "type": "string" } },
                    "required": ["id"]
                }
            },
            {
                "name": "append_graph",
                "description": "Run entity extraction on chunks added since the last build/append. A 30-minute cron timer already fires this automatically, so in steady state agents do NOT need to call it — newly-ingested documents become queryable through the graph-aware modes within ~30 min without intervention. Call manually only when (a) you just ingested content the user wants to query immediately and don't want to wait for the next cron tick, or (b) the user explicitly asks. Cheap fast-path no-op when nothing has changed (returns immediately with documentCount=0) — safe to call defensively. Real-extraction cost scales with new content: ~15-60s for a handful of fresh chunks on a local LLM. Always preferred over `build_graph` for incremental updates.",
                "inputSchema": { "type": "object", "properties": {} }
            },
            {
                "name": "build_graph",
                "description": "[DEPRECATED FOR AGENTS — DO NOT CALL UNLESS THE USER EXPLICITLY ASKS.] Full LLM re-extraction over the entire corpus. Tens of seconds to minutes; no incremental savings. The server now persists the entity graph to Qdrant and rehydrates it on startup, AND a cron timer fires `append_graph` every 30 minutes to pick up new ingests, so agents never need to run a full build in normal operation. Only valid use cases: (a) the user explicitly asks for a rebuild, (b) recovery after a config change (entity_types, prompts, chat model swap) where you want to re-extract everything from scratch. For (a)/(b), confirm with the user first; this is not an action to take autonomously. Tool kept exposed for reference and emergency recovery.",
                "inputSchema": { "type": "object", "properties": {} }
            }
        ]
    })
}

async fn call_tool(client: &Client, cfg: &Config, name: &str, args: &Value) -> Result<Value> {
    let base = &cfg.base_url;
    let resp_value = match name {
        "query" => {
            // Single parametric query tool. Maps the agent-facing
            // mode names onto graphrag-server's /api/query mode
            // field. `reason: true` overrides mode and routes to
            // the decomposition path on the server.
            //
            // Agent-facing → server mode:
            //   default   → hybrid   (LightRAG paper recommended)
            //   thorough  → mix      (hybrid + raw chunk recall)
            //   local     → local    (entity-vector seeded only)
            //   simple    → search   (vector excerpts, no LLM)
            //   reason=true → reason (regardless of mode)
            //
            // The `global` mode exists on the server for completeness
            // but is intentionally NOT exposed here — agents reliably
            // misroute to it where `default`/`thorough` answer the
            // same questions equally well.
            let agent_mode = args.get("mode").and_then(|v| v.as_str()).unwrap_or("default");
            let reason = args.get("reason").and_then(|v| v.as_bool()).unwrap_or(false);
            let server_mode = if reason {
                "reason"
            } else {
                match agent_mode {
                    "default" => "hybrid",
                    "thorough" => "mix",
                    "local" => "local",
                    "simple" => "search",
                    other => anyhow::bail!(
                        "unknown mode: {other} (expected one of: default, thorough, local, simple)"
                    ),
                }
            };
            let body = json!({
                "query": args.get("question").and_then(|v| v.as_str()).unwrap_or(""),
                "top_k": args.get("max_results").and_then(|v| v.as_u64()).unwrap_or(8),
                "mode": server_mode,
            });
            let r = client.post(format!("{base}/api/query")).json(&body).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "graph_stats" => {
            let r = client.get(format!("{base}/api/graph/stats")).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "list_documents" => {
            let r = client.get(format!("{base}/api/documents")).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "add_document" => {
            let r = client.post(format!("{base}/api/documents")).json(args).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "delete_document" => {
            let id = args.get("id").and_then(|v| v.as_str()).unwrap_or("");
            let r = client.delete(format!("{base}/api/documents/{id}")).send().await?;
            r.error_for_status()?.json::<Value>().await.unwrap_or(json!({"deleted": id}))
        }
        "build_graph" => {
            let r = client.post(format!("{base}/api/graph/build")).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "append_graph" => {
            let r = client.post(format!("{base}/api/graph/append")).send().await?;
            r.error_for_status()?.json::<Value>().await?
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
            tracing_subscriber::EnvFilter::try_from_env("GRAPHRAG_MCP_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cfg = Config::from_env();
    tracing::info!(base_url = %cfg.base_url, "graphrag-mcp starting");

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
