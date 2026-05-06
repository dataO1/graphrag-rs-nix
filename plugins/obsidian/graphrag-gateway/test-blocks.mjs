// Standalone smoke test for the block splitter — bundles the
// blocks.ts module with esbuild and runs it under node. No vitest
// dep needed. Run from the plugin dir: `node test-blocks.mjs`.

import { build } from "esbuild";
import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { pathToFileURL } from "url";

const tmp = mkdtempSync(join(tmpdir(), "graphrag-test-"));
const out = join(tmp, "blocks.bundle.mjs");

await build({
  entryPoints: ["src/blocks.ts"],
  bundle: true,
  format: "esm",
  platform: "node",
  outfile: out,
  target: "es2022",
  sourcemap: false,
});

const mod = await import(pathToFileURL(out).href);
const { splitBlocks, diffBlocks, blockIndexFromBlocks, hashFile } = mod;

let passed = 0;
let failed = 0;
function assertEq(actual, expected, label) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) {
    passed++;
    console.log(`✓ ${label}`);
  } else {
    failed++;
    console.error(`✗ ${label}`);
    console.error(`  expected: ${JSON.stringify(expected)}`);
    console.error(`  actual:   ${JSON.stringify(actual)}`);
  }
}
function assert(cond, label) {
  if (cond) {
    passed++;
    console.log(`✓ ${label}`);
  } else {
    failed++;
    console.error(`✗ ${label}`);
  }
}

// ── Test 1: empty doc → no blocks ──
{
  const blocks = await splitBlocks("");
  assertEq(blocks, [], "empty doc → no blocks");
}

// ── Test 2: single paragraph, no headings ──
{
  const blocks = await splitBlocks("Just one paragraph.");
  assertEq(blocks.length, 1, "single paragraph → 1 block (count)");
  assertEq(blocks[0].headingPath, [], "single paragraph → empty heading path");
  assertEq(blocks[0].lineStart, 1, "single paragraph → line_start = 1");
  assertEq(blocks[0].lineEnd, 1, "single paragraph → line_end = 1");
  assertEq(blocks[0].content, "Just one paragraph.", "single paragraph → content");
  assertEq(blocks[0].id, "(root)::0", "single paragraph → fallback id");
}

// ── Test 3: header + 2 paragraphs ──
{
  const text = `# Title\n\nFirst paragraph.\n\nSecond paragraph.\n`;
  const blocks = await splitBlocks(text);
  assertEq(blocks.length, 2, "header + 2 paragraphs → 2 blocks");
  assertEq(blocks[0].headingPath, ["Title"], "block 0 → heading path");
  assertEq(blocks[1].headingPath, ["Title"], "block 1 → same heading path");
  assertEq(blocks[0].lineStart, 3, "block 0 → line_start");
  assertEq(blocks[1].lineStart, 5, "block 1 → line_start");
  assertEq(blocks[0].id, "Title::0", "block 0 → id");
  assertEq(blocks[1].id, "Title::1", "block 1 → id");
}

// ── Test 4: nested headers ──
{
  const text = `# H1\n\nA1.\n\n## H2\n\nA2.\n\n### H3\n\nA3.\n`;
  const blocks = await splitBlocks(text);
  assertEq(blocks.length, 3, "3 sections → 3 blocks");
  assertEq(blocks[0].headingPath, ["H1"], "A1 path");
  assertEq(blocks[1].headingPath, ["H1", "H2"], "A2 path");
  assertEq(blocks[2].headingPath, ["H1", "H2", "H3"], "A3 path");
}

// ── Test 5: header pop on same/lower level ──
{
  const text = `# A\n\npa\n\n## B\n\npb\n\n# C\n\npc\n`;
  const blocks = await splitBlocks(text);
  assertEq(blocks[0].headingPath, ["A"], "pa under A");
  assertEq(blocks[1].headingPath, ["A", "B"], "pb under A>B");
  assertEq(blocks[2].headingPath, ["C"], "pc under C (B popped)");
}

// ── Test 6: ^block-id marker overrides positional id ──
{
  const text = `# Sec\n\nSomething important. ^my-block-1\n\nSomething else.\n`;
  const blocks = await splitBlocks(text);
  assertEq(blocks.length, 2, "block-id case → 2 blocks");
  assertEq(blocks[0].id, "my-block-1", "block 0 → ^block-id used");
  assertEq(blocks[1].id, "Sec::0", "block 1 → fresh sectionCounter starts at 0 for unmarked siblings");
}

// ── Test 7: fenced code block keeps internal blank lines ──
{
  const text = `# Code\n\n\`\`\`rust\nfn a() {}\n\nfn b() {}\n\`\`\`\n\nAfter.\n`;
  const blocks = await splitBlocks(text);
  assertEq(blocks.length, 2, "fenced code preserved as one block");
  assert(blocks[0].content.includes("fn a()"), "code block content kept");
  assert(blocks[0].content.includes("fn b()"), "second fn inside fence kept (blank line not split)");
  assertEq(blocks[1].content, "After.", "after-block not merged into code");
}

// ── Test 8: diffBlocks detects changes correctly ──
{
  const v1 = await splitBlocks("# A\n\nfoo\n\n## B\n\nbar\n");
  const prev = blockIndexFromBlocks(v1);
  const v2 = await splitBlocks("# A\n\nfoo edited\n\n## B\n\nbar\n");
  const { changed, removedBlockIds } = diffBlocks(prev, v2);
  assertEq(changed.length, 1, "edited paragraph → 1 changed block");
  assertEq(changed[0].headingPath, ["A"], "changed block under A");
  assertEq(removedBlockIds, [], "no removals");
}

// ── Test 9: removed block detected ──
{
  const v1 = await splitBlocks("# A\n\nfoo\n\nbar\n");
  const prev = blockIndexFromBlocks(v1);
  const v2 = await splitBlocks("# A\n\nfoo\n");
  const { changed, removedBlockIds } = diffBlocks(prev, v2);
  assertEq(changed, [], "remove-only → no changed");
  assertEq(removedBlockIds.length, 1, "1 removed");
}

// ── Test 10: unchanged file → empty diff ──
{
  const text = "# Same\n\npara1\n\npara2\n";
  const v1 = await splitBlocks(text);
  const prev = blockIndexFromBlocks(v1);
  const v2 = await splitBlocks(text);
  const { changed, removedBlockIds } = diffBlocks(prev, v2);
  assertEq(changed, [], "unchanged → no changes");
  assertEq(removedBlockIds, [], "unchanged → no removals");
}

// ── Test 11: hash is stable across whitespace-only edits ──
{
  const a = await hashFile("# X\n\nhello world\n");
  const b = await hashFile("# X\n\n\nhello world  \n\n\n");
  assertEq(a, b, "hashFile normalizes trailing whitespace + blank-line runs");
}

// ── Cleanup ──
rmSync(tmp, { recursive: true, force: true });

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
