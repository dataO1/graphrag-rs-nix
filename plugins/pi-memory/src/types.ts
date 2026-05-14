// Shared type definitions for the pi-memory extension.
// ---------------------------------------------------------------------------

import type { ExtensionContext } from "@mariozechner/pi-coding-agent";
import type { Text } from "@mariozechner/pi-tui";

// ── Memory backend types ──────────────────────────────────────────

export interface MemoryState {
  sessionId: string;
  lastEventId: number;
}

export interface CatalogEntry {
  id: string;
  title: string;
}

export interface MemoryHit {
  title: string;
  source: string;
  excerpt: string;
  similarity: number;
  absolutePath?: string;
  lineStart?: number;
  lineEnd?: number;
  headingPath?: string[];
  lastModified?: string;
}

export interface RecallResult {
  answer?: string;
  mode: string;
  confidence?: number;
  keyEntities?: string[];
  reasoningSteps?: ReasoningStep[];
  sources?: Source[];
  results: MemoryHit[];
  processingTimeMs: number;
}

export interface ReasoningStep {
  step: number;
  description: string;
  confidence: number;
  evidence?: string;
}

export interface Source {
  kind: string;
  id: string;
  relevance: number;
  excerpt: string;
}

export interface StaleEvent {
  source: string;
  headingPath?: string[];
  delta?: {
    oldExcerpt?: string;
    newExcerpt?: string;
  };
}

// ── UI types ──────────────────────────────────────────────────────

export type Theme = {
  fg(color: string, text: string): string;
  bold(text: string): string;
};

export type PiUi = NonNullable<ExtensionContext["ui"]>;
