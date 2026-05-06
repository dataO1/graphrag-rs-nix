// Local HTTP gateway. Exposes:
//   POST /gateway/recall    → proxies to graphrag /api/query
//   POST /gateway/remember  → writes a note in vault, returns immediately
//   POST /gateway/forget    → deletes a vault note + tells server to drop it
//   GET  /gateway/status    → graphrag stats
//
// Why a gateway at all (instead of clients hitting graphrag directly):
// the user wants Obsidian to be the canonical layer. `remember` from
// pi/MCP becomes a vault note, the user can see it / edit it / move
// it, and the existing vault.on("modify") path takes care of ingest.
// One source of truth.
//
// 127.0.0.1 only — no auth, but no remote exposure either.

import { App, Notice, TFile, TFolder, Vault } from "obsidian";
import * as http from "http";
import { GraphragClient } from "./client";
import type { PluginSettings } from "./types";

interface GatewayContext {
  app: App;
  client: GraphragClient;
  settings: PluginSettings;
}

export class GatewayServer {
  private server?: http.Server;

  constructor(private ctx: GatewayContext) {}

  start(): Promise<void> {
    return new Promise((resolve, reject) => {
      this.server = http.createServer((req, res) => this.handle(req, res));
      this.server.once("error", (e) => {
        console.error("[graphrag-gateway] listen failed", e);
        reject(e);
      });
      this.server.listen(this.ctx.settings.gatewayPort, "127.0.0.1", () =>
        resolve(),
      );
    });
  }

  async stop(): Promise<void> {
    if (!this.server) return;
    await new Promise<void>((resolve) =>
      this.server!.close(() => resolve()),
    );
    this.server = undefined;
  }

  private send(res: http.ServerResponse, status: number, body: unknown) {
    res.writeHead(status, { "Content-Type": "application/json" });
    res.end(JSON.stringify(body));
  }

  private async readJson(req: http.IncomingMessage): Promise<any> {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    if (chunks.length === 0) return {};
    const raw = Buffer.concat(chunks).toString("utf8");
    return raw ? JSON.parse(raw) : {};
  }

  private async handle(req: http.IncomingMessage, res: http.ServerResponse) {
    try {
      const url = new URL(req.url ?? "/", "http://127.0.0.1");
      const path = url.pathname;
      if (req.method === "GET" && path === "/gateway/status") {
        return this.send(res, 200, await this.ctx.client.stats());
      }
      if (req.method === "POST" && path === "/gateway/recall") {
        const body = await this.readJson(req);
        if (!body.question) return this.send(res, 400, { error: "missing question" });
        const r = await this.ctx.client.query(
          body.question,
          body.mode ?? "hybrid",
          body.topK ?? 8,
          body.asOf,
          body.maxVersionsPerDoc,
        );
        return this.send(res, 200, r);
      }
      if (req.method === "POST" && path === "/gateway/remember") {
        return this.handleRemember(req, res);
      }
      if (req.method === "POST" && path === "/gateway/forget") {
        return this.handleForget(req, res);
      }
      this.send(res, 404, { error: "not found" });
    } catch (e: any) {
      console.error("[graphrag-gateway]", e);
      this.send(res, 500, { error: e?.message ?? String(e) });
    }
  }

  /**
   * Body shape:
   *   { title: string, content: string, source: string, folder?: string }
   * The note is written into `<folder>/<sanitized-title>.md` (default
   * folder = `_Generated`). Frontmatter `source` is set so provenance
   * survives later edits.
   */
  private async handleRemember(req: http.IncomingMessage, res: http.ServerResponse) {
    const body = await this.readJson(req);
    if (!body.title || !body.content) {
      return this.send(res, 400, {
        error: "missing required fields: title, content",
      });
    }
    if (!body.source || typeof body.source !== "string") {
      return this.send(res, 400, {
        error: "missing required field: source (URI for provenance)",
      });
    }
    const folder = (body.folder ?? "_Generated").replace(/^\/+|\/+$/g, "");
    const title = sanitizeFilename(String(body.title));
    const vaultPath = `${folder}/${title}.md`;

    await ensureFolder(this.ctx.app.vault, folder);

    const fm = `---\nsource: ${escapeYaml(body.source)}\nremembered_at: ${new Date().toISOString()}\n---\n\n`;
    const data = fm + String(body.content).replace(/\r\n/g, "\n");

    const existing = this.ctx.app.vault.getAbstractFileByPath(vaultPath);
    if (existing instanceof TFile) {
      await this.ctx.app.vault.modify(existing, data);
    } else {
      await this.ctx.app.vault.create(vaultPath, data);
    }
    new Notice(`Knowledge: remembered "${title}"`);
    return this.send(res, 200, { vaultPath, title, source: body.source });
  }

  private async handleForget(req: http.IncomingMessage, res: http.ServerResponse) {
    const body = await this.readJson(req);
    if (!body.path) return this.send(res, 400, { error: "missing path" });
    const f = this.ctx.app.vault.getAbstractFileByPath(body.path);
    if (f instanceof TFile) {
      await this.ctx.app.vault.delete(f);
      // ingest-side delete cascades through the rename/delete handler.
      return this.send(res, 200, { deleted: f.path });
    }
    return this.send(res, 404, { error: `not found: ${body.path}` });
  }
}

function sanitizeFilename(s: string): string {
  return s
    .replace(/[\\/:*?"<>|#^[\]]/g, "-")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 200);
}

function escapeYaml(s: string): string {
  // Quote if contains anything yaml-special; otherwise leave bare.
  if (/[:#&*!{}\[\],?<>=%@`'"]/.test(s) || /^\s|\s$/.test(s)) {
    return JSON.stringify(s);
  }
  return s;
}

async function ensureFolder(vault: Vault, folder: string) {
  if (!folder) return;
  const ex = vault.getAbstractFileByPath(folder);
  if (ex instanceof TFolder) return;
  await vault.createFolder(folder);
}
