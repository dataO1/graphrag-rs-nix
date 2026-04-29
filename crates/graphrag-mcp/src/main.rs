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
                "description": "Search the knowledge graph for relevant content. PRIMARY tool for any question about the user's notes / documents. Returns ranked excerpts with similarity scores. Fast (~350ms). Vector + graph traversal — handles both lexical and conceptual matches. Always try this first; only ingest/index if results are empty AND you have new content to add.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": { "type": "string", "description": "Natural-language question. The user's own phrasing usually retrieves better than aggressive paraphrase." },
                        "max_results": { "type": "integer", "default": 8, "description": "Top-K results to return. 5-10 is typical; raise for breadth, lower for focus." }
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
                "description": "Run entity extraction on chunks added since the last build/append. THE RIGHT TOOL after a batch ingest: call `add_document` N times, then `append_graph` exactly once. Do NOT call after each individual add. Cheap fast-path no-op when nothing has changed since last run (returns immediately with documentCount=0) — safe to call defensively. Currently delegates to a full rebuild internally; LLM-call caching makes repeat work near-free, so cost scales with new content. Expect ~15-60s for a handful of fresh chunks on a local LLM.",
                "inputSchema": { "type": "object", "properties": {} }
            },
            {
                "name": "build_graph",
                "description": "FULL rebuild of the entity/relationship graph from scratch. Expensive (15-60s + per chunk on a local LLM). Use `append_graph` instead in almost all cases. Reserve `build_graph` for: (1) cold-start — `graph_stats` shows documentCount > 0 but entityCount == 0; (2) recovery after a config change (entity_types, prompts) where you want to re-extract everything; (3) explicit user request. Never call after a routine ingest — that's what `append_graph` is for.",
                "inputSchema": { "type": "object", "properties": {} }
            }
        ]
    })
}

async fn call_tool(client: &Client, cfg: &Config, name: &str, args: &Value) -> Result<Value> {
    let base = &cfg.base_url;
    let resp_value = match name {
        "query" => {
            // graphrag-server's QueryRequest takes `query` + `top_k`,
            // not `question` + `max_results`. Tool input names stay
            // human-friendly; we translate here so callers don't need to
            // know the wire shape.
            let body = json!({
                "query": args.get("question").and_then(|v| v.as_str()).unwrap_or(""),
                "top_k": args.get("max_results").and_then(|v| v.as_u64()).unwrap_or(8),
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
