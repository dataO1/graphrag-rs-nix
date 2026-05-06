// Thin REST client to graphrag-rs server.

import type { Block, IngestRequest } from "./types";

export class GraphragClient {
  constructor(private baseUrl: string) {}

  setBaseUrl(url: string) {
    this.baseUrl = url.replace(/\/+$/, "");
  }

  private async request(
    method: "GET" | "POST" | "DELETE",
    path: string,
    body?: unknown,
  ): Promise<any> {
    const res = await fetch(`${this.baseUrl}${path}`, {
      method,
      headers: { "Content-Type": "application/json" },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) {
      const t = await res.text();
      throw new Error(`graphrag ${method} ${path} → ${res.status}: ${t}`);
    }
    if (res.status === 204) return null;
    const ct = res.headers.get("content-type") ?? "";
    if (ct.includes("application/json")) return res.json();
    return res.text();
  }

  async health(): Promise<boolean> {
    try {
      await this.request("GET", "/health");
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Block-aware ingest. The plugin owns the diff state, so we send:
   *   - `content`: full file body (used by the server's graphrag
   *     pipeline for entity extraction over the whole doc)
   *   - `blocks`: only the changed blocks (used by qdrant for
   *     surgical chunk insert; one point per block)
   *   - `removedBlockIds`: ids that vanished since last ingest
   *   - `source` + `id`: doc identity (we use the source URI for both)
   *   - `fileHash`: file-level fingerprint for catalog-side checks
   */
  async ingest(
    req: IngestRequest,
    fullContent: string,
  ): Promise<any> {
    const body = {
      title: req.title,
      source: req.source,
      id: req.source,
      content: fullContent,
      blocks: req.changedBlocks.map((b) => ({
        id: b.id,
        content: b.content,
        hash: b.hash,
        lineStart: b.lineStart,
        lineEnd: b.lineEnd,
        headingPath: b.headingPath,
      })),
      removedBlockIds: req.removedBlockIds,
      fileHash: req.fileHash,
    };
    return this.request("POST", "/api/documents", body);
  }

  async forget(source: string): Promise<any> {
    return this.request("DELETE", `/api/documents/${encodeURIComponent(source)}`);
  }

  async query(question: string, mode = "hybrid", topK = 8, asOf?: string, maxVersionsPerDoc?: number): Promise<any> {
    const body: Record<string, unknown> = {
      query: question,
      mode,
      topK,
    };
    if (asOf) body.asOf = asOf;
    if (maxVersionsPerDoc && maxVersionsPerDoc > 1)
      body.maxVersionsPerDoc = maxVersionsPerDoc;
    return this.request("POST", "/api/query", body);
  }

  async stats(): Promise<any> {
    return this.request("GET", "/api/graph/stats");
  }
}
