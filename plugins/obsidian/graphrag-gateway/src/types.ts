// Shared types between plugin modules.

export interface PluginSettings {
  /** Base URL of the graphrag-rs server (e.g. http://127.0.0.1:17180). */
  graphragBaseUrl: string;
  /** Port the local gateway HTTP server binds to. 127.0.0.1 only. */
  gatewayPort: number;
  /** Debounce window after the last vault.modify event before we ingest. */
  debounceMs: number;
  /** Glob-ish patterns (substring + `*` only) to exclude from ingest. */
  excludeGlobs: string[];
  /** Frontmatter key whose presence with value `false` excludes a note. */
  excludeFrontmatterKey: string;
  /** Token target per chunk (server packs blocks into this size). */
  chunkingTargetTokens: number;
  /** Max tokens per chunk before recursive split. */
  chunkingMaxTokens: number;
  /** Min tokens before merging undersized chunks. */
  chunkingMinTokens: number;
  /** Verbose console logs. */
  debug: boolean;
}

export const DEFAULT_SETTINGS: PluginSettings = {
  graphragBaseUrl: "http://127.0.0.1:17180",
  gatewayPort: 27180,
  debounceMs: 10_000,
  excludeGlobs: [".obsidian/*", ".trash/*", "_attachments/*"],
  excludeFrontmatterKey: "knowledge",
  chunkingTargetTokens: 512,
  chunkingMaxTokens: 1024,
  chunkingMinTokens: 128,
  debug: false,
};

export interface Block {
  /** Stable id within a doc: `<heading-path>::<idx>` or `^block-id` if user-marked. */
  id: string;
  content: string;
  hash: string;
  lineStart: number;
  lineEnd: number;
  /** Heading hierarchy ancestors, root → leaf. */
  headingPath: string[];
}

/**
 * On-disk per-file index of last-known block hashes, scoped to the
 * vault. Used to compute the diff to send on each modify event so the
 * server only re-embeds what actually changed.
 */
export interface FileBlockIndex {
  /** Vault-relative path. */
  path: string;
  /** sha256 of the full normalized content; cheap "did anything change" gate. */
  fileHash: string;
  /** block_id → hash. */
  blocks: Record<string, string>;
  /** Last successful ingest timestamp (RFC 3339). */
  lastIngestedAt: string;
}

export interface IndexState {
  /** vault-relative path → FileBlockIndex */
  files: Record<string, FileBlockIndex>;
}

export interface IngestRequest {
  /** Stable doc-level id. We use the source URI. */
  source: string;
  /** Display title (note name). */
  title: string;
  /** Vault-relative path inside Obsidian. Used to derive source. */
  vaultPath: string;
  /** Blocks added or whose hash changed since the last ingest. */
  changedBlocks: Block[];
  /** Block ids that were present last time but are no longer in the file. */
  removedBlockIds: string[];
  /** Hash of the entire current content (acts as content_hash for the doc as a whole). */
  fileHash: string;
}
