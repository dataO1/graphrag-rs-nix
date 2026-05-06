// Coordinator: vault file → block diff → server ingest.

import { App, TFile, Vault } from "obsidian";
import { GraphragClient } from "./client";
import {
  blockIndexFromBlocks,
  diffBlocks,
  hashFile,
  splitBlocks,
} from "./blocks";
import type { IndexState, IngestRequest, PluginSettings } from "./types";

export type IngestResult =
  | { kind: "skipped"; reason: string }
  | { kind: "noop"; reason: string }
  | {
      kind: "ingested";
      changedBlocks: number;
      removedBlocks: number;
    }
  | { kind: "error"; error: string };

function isExcludedByGlob(path: string, globs: string[]): boolean {
  // Tiny glob matcher: `*` matches any chars within a path segment;
  // patterns are matched against vault-relative paths. Anchored at
  // start by default. Sufficient for `.obsidian/*` style patterns.
  for (const g of globs) {
    if (!g) continue;
    const re = new RegExp(
      "^" +
        g
          .replace(/[.+?^${}()|[\]\\]/g, "\\$&")
          .replace(/\*/g, ".*") +
        "$",
    );
    if (re.test(path)) return true;
  }
  return false;
}

function vaultName(vault: Vault): string {
  return vault.getName();
}

function sourceUriFor(vault: Vault, file: TFile): string {
  // obsidian://vault/<vault-name>/<vault-relative-path>
  // Used as user_id on the server so re-ingests are upserts. URL-
  // encode the path so spaces / # / ? don't break round-trip.
  return `obsidian://vault/${encodeURIComponent(vaultName(vault))}/${encodeURIComponent(
    file.path,
  )}`;
}

interface FrontmatterCheck {
  excluded: boolean;
  customId?: string;
}

function checkFrontmatter(
  app: App,
  file: TFile,
  excludeKey: string,
): FrontmatterCheck {
  const cache = app.metadataCache.getFileCache(file);
  const fm = cache?.frontmatter as Record<string, unknown> | undefined;
  if (!fm) return { excluded: false };
  const flag = fm[excludeKey];
  // `knowledge: false` excludes; nested `{ knowledge: { exclude: true } }` also works.
  if (flag === false) return { excluded: true };
  if (typeof flag === "object" && flag !== null) {
    const obj = flag as Record<string, unknown>;
    if (obj.exclude === true) return { excluded: true };
    if (typeof obj.id === "string" && obj.id.length > 0) {
      return { excluded: false, customId: obj.id };
    }
  }
  return { excluded: false };
}

export async function ingestFile(
  app: App,
  client: GraphragClient,
  state: IndexState,
  settings: PluginSettings,
  file: TFile,
): Promise<IngestResult> {
  if (file.extension !== "md") {
    return { kind: "skipped", reason: `not markdown (.${file.extension})` };
  }
  if (isExcludedByGlob(file.path, settings.excludeGlobs)) {
    return { kind: "skipped", reason: "excluded by glob" };
  }
  const fm = checkFrontmatter(app, file, settings.excludeFrontmatterKey);
  if (fm.excluded) return { kind: "skipped", reason: "excluded by frontmatter" };

  const text = await app.vault.cachedRead(file);
  const fileHash = await hashFile(text);
  const prev = state.files[file.path];
  if (prev && prev.fileHash === fileHash) {
    return { kind: "noop", reason: "fileHash unchanged" };
  }

  const blocks = await splitBlocks(text);
  const prevHashes = prev?.blocks ?? {};
  const { changed, removedBlockIds } = diffBlocks(prevHashes, blocks);

  if (changed.length === 0 && removedBlockIds.length === 0) {
    state.files[file.path] = {
      path: file.path,
      fileHash,
      blocks: blockIndexFromBlocks(blocks),
      lastIngestedAt: new Date().toISOString(),
    };
    return { kind: "noop", reason: "no block changes" };
  }

  const source = sourceUriFor(app.vault, file);
  const req: IngestRequest = {
    source,
    title: file.basename,
    vaultPath: file.path,
    changedBlocks: changed,
    removedBlockIds,
    fileHash,
  };

  try {
    await client.ingest(req, text);
  } catch (e: any) {
    return { kind: "error", error: e?.message ?? String(e) };
  }

  // Persist new index AFTER a successful ingest so a failed POST
  // means we'll try again on the next change.
  state.files[file.path] = {
    path: file.path,
    fileHash,
    blocks: blockIndexFromBlocks(blocks),
    lastIngestedAt: new Date().toISOString(),
  };

  return {
    kind: "ingested",
    changedBlocks: changed.length,
    removedBlocks: removedBlockIds.length,
  };
}

export async function forgetFile(
  app: App,
  client: GraphragClient,
  state: IndexState,
  file: TFile,
): Promise<void> {
  const source = sourceUriFor(app.vault, file);
  try {
    await client.forget(source);
  } catch {
    // Best-effort: missing-doc 404 is fine.
  }
  delete state.files[file.path];
}

/**
 * Map renames so we don't re-ingest under a new source URI.
 * Strategy: forget(old source); next ingest will create under new.
 */
export async function renameFile(
  app: App,
  client: GraphragClient,
  state: IndexState,
  file: TFile,
  oldPath: string,
): Promise<void> {
  const oldSource = `obsidian://vault/${encodeURIComponent(
    app.vault.getName(),
  )}/${encodeURIComponent(oldPath)}`;
  try {
    await client.forget(oldSource);
  } catch {}
  delete state.files[oldPath];
}
