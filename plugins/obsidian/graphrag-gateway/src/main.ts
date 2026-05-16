import {
  App,
  Modal,
  Notice,
  Plugin,
  PluginSettingTab,
  Setting,
  TAbstractFile,
  TFile,
} from "obsidian";
import { GraphragClient } from "./client";
import { GatewayServer } from "./gateway-server";
import { forgetFile, ingestFile, renameFile } from "./ingest";
import { loadIndexState, saveIndexState } from "./state";
import {
  DEFAULT_SETTINGS,
  type IndexState,
  type PluginSettings,
} from "./types";

export default class GraphragGatewayPlugin extends Plugin {
  settings!: PluginSettings;
  state!: IndexState;
  client!: GraphragClient;
  gateway!: GatewayServer;

  /** path → debounce timer id (Node `Timeout`). */
  private pending = new Map<string, ReturnType<typeof setTimeout>>();
  /** Live counter of pending ingests for the status bar. */
  private pendingCount = 0;
  /** Live status: server-reachable. */
  private reachable = false;
  private healthTimer?: ReturnType<typeof setInterval>;
  private statusEl?: HTMLElement;
  private indexSaveTimer?: ReturnType<typeof setTimeout>;

  async onload() {
    await this.bootstrap();
    this.registerCommands();
    this.addSettingTab(new GraphragSettingTab(this.app, this));
    this.statusEl = this.addStatusBarItem();
    this.refreshBadge();

    // Periodic health ping so the badge reflects reality.
    this.healthTimer = setInterval(() => this.healthPing(), 30_000);
    void this.healthPing();

    // Lazy-start the gateway. If the port is taken, log + carry on
    // (vault ingest still works without it).
    try {
      await this.gateway.start();
      this.log(`gateway listening on 127.0.0.1:${this.settings.gatewayPort}`);
    } catch (e) {
      console.warn("[graphrag-gateway] gateway server start failed", e);
      new Notice(
        `GraphRAG Gateway: port ${this.settings.gatewayPort} unavailable — vault watch still active.`,
      );
    }

    // Defer vault event registration until after Obsidian's startup
    // scan is done. Obsidian fires `create` for every existing file at
    // boot ("newly loaded files are treated as 'created' at that
    // time"), and we don't want to queue ~vault-size ingests on every
    // launch. The 5 s grace lets other plugins (make.md, tasks,
    // kanban, dataview, templater) finish their layout-ready frontmatter
    // rewrites before we start observing — otherwise their writes
    // surface to us as real modifies and we re-POST unchanged content.
    this.app.workspace.onLayoutReady(() => {
      window.setTimeout(() => {
        this.registerVaultEvents();
        this.log("vault watch armed (post layout-ready grace)");
      }, 5_000);
    });

    this.log("ready");
  }

  async onunload() {
    if (this.healthTimer) clearInterval(this.healthTimer);
    for (const t of this.pending.values()) clearTimeout(t);
    this.pending.clear();
    if (this.indexSaveTimer) clearTimeout(this.indexSaveTimer);
    await this.gateway?.stop();
    await this.persistState();
  }

  private async bootstrap() {
    const data = (await this.loadData()) as
      | { settings?: Partial<PluginSettings>; blockIndexState?: IndexState }
      | null;
    this.settings = { ...DEFAULT_SETTINGS, ...(data?.settings ?? {}) };
    this.state = data?.blockIndexState ?? { files: {} };
    this.client = new GraphragClient(this.settings.graphragBaseUrl);
    this.gateway = new GatewayServer({
      app: this.app,
      client: this.client,
      settings: this.settings,
    });
  }

  private registerVaultEvents() {
    this.registerEvent(
      this.app.vault.on("modify", (f) => this.scheduleIngest(f)),
    );
    this.registerEvent(
      this.app.vault.on("create", (f) => this.scheduleIngest(f)),
    );
    this.registerEvent(
      this.app.vault.on("delete", (f) => this.handleDelete(f)),
    );
    this.registerEvent(
      this.app.vault.on("rename", (f, oldPath) => this.handleRename(f, oldPath)),
    );
  }

  private registerCommands() {
    this.addCommand({
      id: "graphrag-recall",
      name: "Knowledge: Recall…",
      callback: () => new RecallModal(this.app, this).open(),
    });
    this.addCommand({
      id: "graphrag-reindex-active",
      name: "Knowledge: Reindex this note",
      checkCallback: (checking) => {
        const f = this.app.workspace.getActiveFile();
        if (!f || f.extension !== "md") return false;
        if (!checking) {
          // Force re-ingest by clearing the cached fileHash.
          const prev = this.state.files[f.path];
          if (prev) prev.fileHash = "";
          this.scheduleIngest(f, /*immediate*/ true);
        }
        return true;
      },
    });
    this.addCommand({
      id: "graphrag-forget-active",
      name: "Knowledge: Forget this note",
      checkCallback: (checking) => {
        const f = this.app.workspace.getActiveFile();
        if (!f || f.extension !== "md") return false;
        if (!checking) void this.runForget(f);
        return true;
      },
    });
    this.addCommand({
      id: "graphrag-reindex-all",
      name: "Knowledge: Reindex entire vault",
      callback: () => void this.reindexAll(),
    });
  }

  private scheduleIngest(file: TAbstractFile, immediate = false) {
    if (!(file instanceof TFile)) return;
    if (file.extension !== "md") return;
    const existing = this.pending.get(file.path);
    if (existing) clearTimeout(existing);

    if (immediate) {
      this.runIngest(file);
      return;
    }

    this.pendingCount++;
    this.refreshBadge();
    const timer = setTimeout(() => this.runIngest(file), this.settings.debounceMs);
    this.pending.set(file.path, timer);
  }

  private async runIngest(file: TFile) {
    this.pending.delete(file.path);
    try {
      const r = await ingestFile(
        this.app,
        this.client,
        this.state,
        this.settings,
        file,
      );
      if (this.settings.debug) {
        console.log("[graphrag-gateway] ingest", file.path, r);
      }
      if (r.kind === "error") {
        new Notice(`GraphRAG ingest failed: ${file.basename} — ${r.error}`);
      }
    } finally {
      this.pendingCount = Math.max(0, this.pendingCount - 1);
      this.refreshBadge();
      this.scheduleStatePersist();
    }
  }

  private async handleDelete(file: TAbstractFile) {
    if (!(file instanceof TFile)) return;
    if (file.extension !== "md") return;
    await forgetFile(this.app, this.client, this.state, file);
    this.scheduleStatePersist();
  }

  private async handleRename(file: TAbstractFile, oldPath: string) {
    if (!(file instanceof TFile)) return;
    if (file.extension !== "md") return;
    await renameFile(this.app, this.client, this.state, file, oldPath);
    // Trigger a fresh ingest under the new path.
    this.scheduleIngest(file);
  }

  private async runForget(file: TFile) {
    await forgetFile(this.app, this.client, this.state, file);
    new Notice(`Knowledge: forgot "${file.basename}"`);
    this.scheduleStatePersist();
  }

  private async reindexAll() {
    const files = this.app.vault.getMarkdownFiles();
    new Notice(`GraphRAG: reindexing ${files.length} notes`);
    // Clear the cached hashes to force full re-ingest.
    this.state = { files: {} };
    for (const f of files) this.scheduleIngest(f);
  }

  private scheduleStatePersist() {
    // Short debounce: enough to coalesce a burst of ingests, small
    // enough that a force-kill loses at most one ingest's worth of
    // updated hashes (without persistence, those files re-ingest on
    // the next boot).
    if (this.indexSaveTimer) clearTimeout(this.indexSaveTimer);
    this.indexSaveTimer = setTimeout(() => void this.persistState(), 500);
  }

  private async persistState() {
    await saveIndexState(this, this.settings, this.state);
  }

  private async healthPing() {
    const ok = await this.client.health();
    if (ok !== this.reachable) {
      this.reachable = ok;
      this.refreshBadge();
    }
  }

  private refreshBadge() {
    if (!this.statusEl) return;
    if (!this.reachable) {
      this.statusEl.setText("know ○");
      this.statusEl.title = "graphrag server unreachable";
      return;
    }
    if (this.pendingCount > 0) {
      this.statusEl.setText(`know ⋯ (${this.pendingCount})`);
      this.statusEl.title = `${this.pendingCount} ingest(s) pending`;
      return;
    }
    this.statusEl.setText("know ●");
    this.statusEl.title = "graphrag connected, idle";
  }

  // Settings tab calls this after settings change to apply them.
  applySettings() {
    this.client.setBaseUrl(this.settings.graphragBaseUrl);
    void this.persistState();
  }

  log(msg: string) {
    if (this.settings.debug) console.log(`[graphrag-gateway] ${msg}`);
  }
}

class GraphragSettingTab extends PluginSettingTab {
  constructor(app: App, private plugin: GraphragGatewayPlugin) {
    super(app, plugin);
  }
  display() {
    const { containerEl } = this;
    containerEl.empty();
    containerEl.createEl("h2", { text: "GraphRAG Gateway" });

    new Setting(containerEl)
      .setName("graphrag base URL")
      .setDesc("REST endpoint of the local graphrag-rs server.")
      .addText((t) =>
        t
          .setValue(this.plugin.settings.graphragBaseUrl)
          .onChange(async (v) => {
            this.plugin.settings.graphragBaseUrl = v.trim();
            await this.plugin.saveData({
              settings: this.plugin.settings,
              blockIndexState: this.plugin.state,
            });
            this.plugin.applySettings();
          }),
      );

    new Setting(containerEl)
      .setName("Gateway port")
      .setDesc("127.0.0.1 port the gateway HTTP server binds. Restart Obsidian to apply.")
      .addText((t) =>
        t
          .setValue(String(this.plugin.settings.gatewayPort))
          .onChange(async (v) => {
            const n = Number(v);
            if (!Number.isFinite(n) || n < 1024 || n > 65535) return;
            this.plugin.settings.gatewayPort = n;
            await this.plugin.saveData({
              settings: this.plugin.settings,
              blockIndexState: this.plugin.state,
            });
          }),
      );

    new Setting(containerEl)
      .setName("Debounce (ms)")
      .setDesc("Idle time after the last edit before ingesting.")
      .addText((t) =>
        t
          .setValue(String(this.plugin.settings.debounceMs))
          .onChange(async (v) => {
            const n = Number(v);
            if (!Number.isFinite(n) || n < 1000) return;
            this.plugin.settings.debounceMs = n;
            await this.plugin.saveData({
              settings: this.plugin.settings,
              blockIndexState: this.plugin.state,
            });
          }),
      );

    new Setting(containerEl)
      .setName("Exclude globs")
      .setDesc("One per line. Star matches any chars within a path segment.")
      .addTextArea((t) =>
        t
          .setValue(this.plugin.settings.excludeGlobs.join("\n"))
          .onChange(async (v) => {
            this.plugin.settings.excludeGlobs = v
              .split(/\r?\n/)
              .map((s) => s.trim())
              .filter(Boolean);
            await this.plugin.saveData({
              settings: this.plugin.settings,
              blockIndexState: this.plugin.state,
            });
          }),
      );

    new Setting(containerEl)
      .setName("Frontmatter exclude key")
      .setDesc(
        "Notes with this frontmatter key set to false (or { exclude: true }) are skipped.",
      )
      .addText((t) =>
        t
          .setValue(this.plugin.settings.excludeFrontmatterKey)
          .onChange(async (v) => {
            this.plugin.settings.excludeFrontmatterKey = v.trim() || "knowledge";
            await this.plugin.saveData({
              settings: this.plugin.settings,
              blockIndexState: this.plugin.state,
            });
          }),
      );

    new Setting(containerEl)
      .setName("Debug logging")
      .setDesc("Print plugin events to the developer console.")
      .addToggle((t) =>
        t.setValue(this.plugin.settings.debug).onChange(async (v) => {
          this.plugin.settings.debug = v;
          await this.plugin.saveData({
            settings: this.plugin.settings,
            blockIndexState: this.plugin.state,
          });
        }),
      );
  }
}

class RecallModal extends Modal {
  private input!: HTMLTextAreaElement;
  private resultEl!: HTMLElement;

  constructor(app: App, private plugin: GraphragGatewayPlugin) {
    super(app);
  }

  onOpen() {
    this.titleEl.setText("Knowledge Recall");
    const w = this.contentEl;
    this.input = w.createEl("textarea", { cls: "graphrag-recall-input" });
    this.input.style.width = "100%";
    this.input.style.minHeight = "5em";
    this.input.placeholder = "Ask the knowledge graph…";
    const btn = w.createEl("button", { text: "Recall" });
    btn.style.marginTop = "0.5em";
    btn.addEventListener("click", () => void this.run());
    this.resultEl = w.createDiv("graphrag-recall-result");
    this.resultEl.style.marginTop = "1em";
    this.resultEl.style.whiteSpace = "pre-wrap";
    this.input.focus();
  }

  private async run() {
    const q = this.input.value.trim();
    if (!q) return;
    this.resultEl.setText("Thinking…");
    try {
      const r = await this.plugin.client.query(q);
      const ans = r?.answer ?? "(no answer)";
      const conf =
        typeof r?.confidence === "number" ? ` (conf ${r.confidence.toFixed(2)})` : "";
      const hits = Array.isArray(r?.results) ? r.results.length : 0;
      this.resultEl.setText(`${ans}${conf}\n\n${hits} hit(s)`);
    } catch (e: any) {
      this.resultEl.setText(`error: ${e?.message ?? String(e)}`);
    }
  }
}
