// Markdown block splitter — runs in the plugin so line numbers come
// straight from the source file (Obsidian's editor is the
// authoritative line view; we never rely on the agent or the server
// to compute them).
//
// Two-layer model (matches Phase B design):
//   1. BLOCKS = invalidation units. We split by ATX headers and
//      paragraph (blank-line) boundaries, plus respect ^block-id
//      markers when present.
//   2. CHUNKS = embedding units. Server-side concern; this module
//      only emits blocks. The server packs blocks into ~512-token
//      chunks with a contextual prefix.

import type { Block } from "./types";

/**
 * sha256 of normalized text — we strip trailing whitespace per line
 * and collapse multiple blank lines to a single one before hashing
 * so cosmetic edits (Obsidian re-flowing whitespace) don't bust the
 * cache.
 */
async function sha256Normalized(text: string): Promise<string> {
  const norm = text
    .split(/\r?\n/)
    .map((l) => l.replace(/[\t ]+$/u, ""))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  const enc = new TextEncoder().encode(norm);
  const digest = await crypto.subtle.digest("SHA-256", enc);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

const HEADING_RE = /^(#{1,6})\s+(.+?)\s*$/;
const BLOCKID_RE = /\^([A-Za-z0-9-]+)\s*$/;

/** Hash the full file content for cheap "did anything change" check. */
export async function hashFile(text: string): Promise<string> {
  return sha256Normalized(text);
}

/**
 * Split a markdown note into invalidation-blocks. Each block has:
 *   - a stable id (heading-path::idx, or `^block-id` when present)
 *   - line_start / line_end (1-indexed, from the source as-given)
 *   - heading_path (ancestor headings root → leaf)
 *   - content (raw markdown of this block; multi-line preserved)
 *   - hash (sha256 of normalized content)
 *
 * Boundary rules:
 *   - An ATX heading (`^#+\s`) starts a new block AND pushes/pops the
 *     heading_path stack based on level.
 *   - Within a section, blank lines separate paragraph blocks.
 *   - A line ending in `^<id>` is a Obsidian block-id marker; the id
 *     becomes that paragraph's stable id (instead of positional).
 *   - Empty leading/trailing whitespace lines are ignored for boundary
 *     detection but preserved inside multi-line blocks.
 */
export async function splitBlocks(text: string): Promise<Block[]> {
  const lines = text.split(/\r?\n/);
  const blocks: Block[] = [];
  const headingStack: { level: number; title: string }[] = [];
  let buf: string[] = [];
  let bufStart = -1;
  let inFencedCode = false;
  let fenceMarker = "";

  // Per-section monotonic counter so two unmarked paragraphs under the
  // same heading get distinct ids.
  const sectionCounters: Record<string, number> = {};

  const sectionKey = () =>
    headingStack.map((h) => h.title).join(" > ") || "(root)";

  const flushBuf = async (endLine: number) => {
    if (buf.length === 0) return;
    const content = buf.join("\n").trim();
    if (!content) {
      buf = [];
      bufStart = -1;
      return;
    }
    // Detect ^block-id on the LAST non-empty line.
    let blockId: string | undefined;
    const lastIdx = (() => {
      for (let i = buf.length - 1; i >= 0; i--) if (buf[i].trim()) return i;
      return -1;
    })();
    if (lastIdx >= 0) {
      const m = buf[lastIdx].match(BLOCKID_RE);
      if (m) blockId = m[1];
    }
    const key = sectionKey();
    if (!blockId) {
      const idx = (sectionCounters[key] = (sectionCounters[key] ?? -1) + 1);
      blockId = `${key}::${idx}`;
    }
    const headingPath = headingStack.map((h) => h.title);
    blocks.push({
      id: blockId,
      content,
      hash: await sha256Normalized(content),
      lineStart: bufStart + 1,
      lineEnd: endLine,
      headingPath,
    });
    buf = [];
    bufStart = -1;
  };

  for (let i = 0; i < lines.length; i++) {
    const ln = lines[i];

    // Fenced code: don't interpret headings/blanks inside.
    const fenced = ln.match(/^(```+|~~~+)/);
    if (fenced) {
      if (!inFencedCode) {
        inFencedCode = true;
        fenceMarker = fenced[1][0];
      } else if (ln.trimStart().startsWith(fenceMarker)) {
        inFencedCode = false;
      }
      if (bufStart === -1) bufStart = i;
      buf.push(ln);
      continue;
    }
    if (inFencedCode) {
      if (bufStart === -1) bufStart = i;
      buf.push(ln);
      continue;
    }

    const heading = ln.match(HEADING_RE);
    if (heading) {
      // Flush any in-flight paragraph BEFORE pushing the heading change.
      await flushBuf(i); // end at line BEFORE the heading
      const level = heading[1].length;
      const title = heading[2];
      // Pop stack down to (level - 1) before pushing.
      while (
        headingStack.length > 0 &&
        headingStack[headingStack.length - 1].level >= level
      ) {
        headingStack.pop();
      }
      headingStack.push({ level, title });
      // The heading itself is not its own block; subsequent paragraph
      // content belongs to the section it labels.
      continue;
    }

    if (ln.trim() === "") {
      // Blank line: paragraph boundary.
      await flushBuf(i); // current paragraph ends at PREVIOUS line
      continue;
    }

    if (bufStart === -1) bufStart = i;
    buf.push(ln);
  }
  await flushBuf(lines.length);

  return blocks;
}

/**
 * Diff prev block-hash map vs current block list:
 *   - changed = blocks present in current with new/different hash
 *   - removed = ids that were in prev but missing from current
 */
export function diffBlocks(
  prev: Record<string, string>,
  current: Block[],
): { changed: Block[]; removedBlockIds: string[] } {
  const changed: Block[] = [];
  const seen = new Set<string>();
  for (const b of current) {
    seen.add(b.id);
    if (prev[b.id] !== b.hash) changed.push(b);
  }
  const removedBlockIds: string[] = [];
  for (const id of Object.keys(prev)) {
    if (!seen.has(id)) removedBlockIds.push(id);
  }
  return { changed, removedBlockIds };
}

/** Build the {block_id: hash} map for storing as the new "last-known". */
export function blockIndexFromBlocks(
  blocks: Block[],
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const b of blocks) out[b.id] = b.hash;
  return out;
}
