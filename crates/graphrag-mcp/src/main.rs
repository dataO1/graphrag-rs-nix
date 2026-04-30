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
                "description": "Vector similarity search over the user's notes. Returns ranked excerpts (no LLM-composed answer). Fast (~350ms). PRIMARY tool for 'do I have notes on X?' or 'show me passages about Y' style questions where you want raw source material. Pick this over `query_ask`/`query_explain` when you only need excerpts to read or quote, not a synthesized answer. Always try this first before deciding to ingest new content.",
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
                "name": "query_explain",
                "description": "Graph-aware retrieval + LLM-composed answer with attribution. Use when the user asks a question they want ANSWERED in natural language. Walks the entity graph, ranks chunks/entities/relationships, has the configured chat backend synthesize an answer, AND returns confidence (0-1), the key entities the answer relied on, a step-by-step reasoning trace, and a typed source list (text-chunk / entity / relationship). The metadata is computed from data already gathered for the answer — same compute cost as a metadata-less ask. Use `confidence` to gauge how grounded the answer is: <0.3 means the engine is guessing (surface uncertainty to the user); >0.7 means well-supported. Pick this for nearly every answer-seeking question. Pick `query_reason` instead only when the question has multiple sub-parts that need decomposition. Slower than plain `query` (LLM round-trip; ~3-10s on local hardware).",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": { "type": "string", "description": "Natural-language question to answer." },
                        "max_results": { "type": "integer", "default": 8, "description": "Top-K source chunks the engine considers. Higher = more context for the LLM, slower call." }
                    },
                    "required": ["question"]
                }
            },
            {
                "name": "query_reason",
                "description": "Multi-hop / compound questions. Decomposes the question into sub-queries, answers each, and composes a final answer. Use when the question combines multiple facts that aren't co-located in the corpus — e.g. 'What did I write about X, and how does it relate to Y?', 'Compare A and B from my notes', 'What's the timeline of events involving Z?'. Slowest mode — multiple LLM round-trips. Don't pick this for simple single-fact questions; `query_ask` is faster and just as good there.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": { "type": "string", "description": "Natural-language compound or multi-hop question." },
                        "max_results": { "type": "integer", "default": 8, "description": "Top-K source chunks the engine considers per sub-query." }
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
            // graphrag-server's QueryRequest takes `query` + `top_k`,
            // not `question` + `max_results`. Tool input names stay
            // human-friendly; we translate here so callers don't need to
            // know the wire shape.
            let body = json!({
                "query": args.get("question").and_then(|v| v.as_str()).unwrap_or(""),
                "top_k": args.get("max_results").and_then(|v| v.as_u64()).unwrap_or(8),
                "mode": "search",
            });
            let r = client.post(format!("{base}/api/query")).json(&body).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "query_explain" => {
            // Routes to /api/query mode=explain. graphrag-core's
            // ask() and ask_explained() share the same retrieval +
            // LLM call — the only difference is whether the
            // already-computed metadata (confidence, sources,
            // reasoning steps, key entities) is packaged in the
            // response. Since the cost is identical, we expose only
            // the metadata-rich variant as a single tool. Agents
            // can ignore fields they don't need.
            let body = json!({
                "query": args.get("question").and_then(|v| v.as_str()).unwrap_or(""),
                "top_k": args.get("max_results").and_then(|v| v.as_u64()).unwrap_or(8),
                "mode": "explain",
            });
            let r = client.post(format!("{base}/api/query")).json(&body).send().await?;
            r.error_for_status()?.json::<Value>().await?
        }
        "query_reason" => {
            let body = json!({
                "query": args.get("question").and_then(|v| v.as_str()).unwrap_or(""),
                "top_k": args.get("max_results").and_then(|v| v.as_u64()).unwrap_or(8),
                "mode": "reason",
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
