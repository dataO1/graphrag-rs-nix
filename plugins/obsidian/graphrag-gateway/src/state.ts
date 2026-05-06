// Persistent block-hash index — survives Obsidian restarts so we
// don't re-ingest everything on first boot.

import { Plugin } from "obsidian";
import type { IndexState } from "./types";

const INDEX_KEY = "blockIndexState";

export async function loadIndexState(plugin: Plugin): Promise<IndexState> {
  const raw = (await plugin.loadData()) as
    | { settings?: any; [INDEX_KEY]?: IndexState }
    | null;
  if (raw && raw[INDEX_KEY] && typeof raw[INDEX_KEY] === "object") {
    return raw[INDEX_KEY] as IndexState;
  }
  return { files: {} };
}

export async function saveIndexState(
  plugin: Plugin,
  settings: unknown,
  state: IndexState,
): Promise<void> {
  await plugin.saveData({ settings, [INDEX_KEY]: state });
}

export async function loadSettings(plugin: Plugin): Promise<unknown> {
  const raw = (await plugin.loadData()) as
    | { settings?: unknown }
    | null;
  return raw?.settings ?? null;
}
