// Catalog cache — used by the recall-hint heuristic to detect when
// the user's prompt mentions known docs without paying for an LLM
// "should I recall?" decision call. Refreshed periodically; stale
// entries are tolerable.
// ---------------------------------------------------------------------------

import { memoryRequest } from "./memory-client";
import type { CatalogEntry } from "./types";
import { CATALOG_REFRESH_MS, HINT_OVERLAP_THRESHOLD, HINT_MAX_TITLES } from "./config";

// ── Stop-words ────────────────────────────────────────────────────
const STOP_WORDS = new Set([
  "the", "a", "an", "and", "or", "but", "if", "then", "than", "of",
  "to", "in", "on", "at", "by", "for", "with", "from", "into", "about",
  "i", "me", "my", "we", "our", "you", "your", "it", "its", "this",
  "that", "these", "those", "is", "are", "was", "were", "be", "been",
  "being", "have", "has", "had", "do", "does", "did", "doing", "will",
  "would", "should", "could", "can", "may", "might", "must", "shall",
  "what", "which", "who", "whom", "whose", "where", "when", "why",
  "how", "all", "any", "some", "not", "no", "nor", "so", "as", "out",
  "up", "down", "off", "over", "under", "again", "just", "only",
  "very", "more", "most", "other", "such", "own", "same", "too",
]);

// ── Module state ──────────────────────────────────────────────────
let catalog: CatalogEntry[] = [];
let catalogTimer: ReturnType<typeof setInterval> | undefined;

// ── Tokenisation ──────────────────────────────────────────────────
export function tokenize(text: string): Set<string> {
  return new Set(
    text
      .toLowerCase()
      .replace(/[^\p{L}\p{N}\s]/gu, " ")
      .split(/\s+/)
      .filter((w) => w.length >= 3 && !STOP_WORDS.has(w)),
  );
}

// ── Catalog refresh ───────────────────────────────────────────────
export async function refreshCatalog(): Promise<void> {
  try {
    const r = await memoryRequest("GET", "/api/documents");
    if (Array.isArray(r?.documents)) {
      catalog = r.documents.map((d: any) => ({
        id: d.id,
        title: d.title ?? "",
      }));
    }
  } catch {
    // Server unreachable — leave the previous catalog in place so
    // hints still work when the laptop briefly loses the network.
  }
}

// ── Catalog matching ──────────────────────────────────────────────
export function matchCatalog(promptText: string): CatalogEntry[] {
  if (catalog.length === 0) return [];
  const promptTokens = tokenize(promptText);
  if (promptTokens.size === 0) return [];
  const scored: { entry: CatalogEntry; score: number }[] = [];
  for (const entry of catalog) {
    if (!entry.title) continue;
    const titleTokens = tokenize(entry.title);
    let overlap = 0;
    for (const t of titleTokens) if (promptTokens.has(t)) overlap++;
    if (overlap >= HINT_OVERLAP_THRESHOLD) {
      scored.push({ entry, score: overlap });
    }
  }
  scored.sort((a, b) => b.score - a.score);
  return scored.slice(0, HINT_MAX_TITLES).map((s) => s.entry);
}

// ── Timer management ──────────────────────────────────────────────
export function startCatalogRefreshTimer(): void {
  if (catalogTimer) return;
  catalogTimer = setInterval(() => {
    refreshCatalog().catch(() => {});
  }, CATALOG_REFRESH_MS);
}

export function stopCatalogRefreshTimer(): void {
  if (catalogTimer) {
    clearInterval(catalogTimer);
    catalogTimer = undefined;
  }
}
