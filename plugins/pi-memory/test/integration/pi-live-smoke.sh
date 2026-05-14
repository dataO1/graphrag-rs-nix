#!/usr/bin/env bash
# ── pi-memory live-pi integration smoke test ──────────────────────
#
# Runs the REAL pi binary (unwrapped, no pre-loaded extensions) in an
# isolated HOME so the user's ~/.pi/ is never touched. Loads ONLY our
# extension (--no-extensions --no-skills) and verifies:
#
#   1. pi starts and loads the extension without crashing
#   2. The isolated HOME stays self-contained (no pollution)
#   3. The user's ~/.pi is unchanged after the test
#
# Prerequisites:
#   • Run inside `nix develop` so pi-coding-agent is on PATH
#   • Plugin must be built:  node build.mjs  (or nix build .#pi-memory-plugin)
#
# Usage:  ./test/integration/pi-live-smoke.sh [--keep-tmp]
# ---------------------------------------------------------------------------

set -uo pipefail
cd "$(dirname "$0")/../.."
DIST_INDEX="$(pwd)/dist/index.js"
PASS=0
FAIL=0
KEEP_TMP=0

green()  { echo -e "\033[32m  ✓ $*\033[0m"; PASS=$((PASS + 1)); }
red()    { echo -e "\033[31m  ✗ $*\033[0m"; FAIL=$((FAIL + 1)); }
header() { echo -e "\n\033[1m── $* ──\033[0m"; }
warn()   { echo -e "\033[33m  ⚠ $*\033[0m"; }

[[ "${1-}" == "--keep-tmp" ]] && KEEP_TMP=1

cleanup() {
  if [[ -n "${PI_TEST_HOME-}" && -d "$PI_TEST_HOME" ]]; then
    if [[ $KEEP_TMP -eq 0 ]]; then
      rm -rf "$PI_TEST_HOME"
    else
      echo -e "\n  (kept temp HOME: $PI_TEST_HOME)"
    fi
  fi
}
trap cleanup EXIT

# ── Find pi ──────────────────────────────────────────────────────
header "Locating pi binary"

PI_BIN="${PI_BIN:-$(which pi 2>/dev/null || true)}"

if [[ -z "$PI_BIN" ]]; then
  red "pi not on PATH — run inside 'nix develop' or set PI_BIN="
  exit 1
fi

# Resolve symlinks so we can tell whether this is the HM wrapper
# (--extension flags baked in) or the unwrapped coding-agent.
PI_REAL="$(readlink -f "$PI_BIN")"
green "pi → $PI_BIN"

# Detect wrapper: the HM wrapper is a two-line bash script that adds
# --extension flags. The unwrapped coding-agent is a longer makeWrapper
# that sets PI_PACKAGE_DIR and NODE_PATH then execs node.
if head -5 "$PI_REAL" | grep -q -- '--extension'; then
  warn "pi appears to be the HM wrapper (has baked-in --extension flags)."
  warn "Extension isolation (--no-extensions) will disable discovery but"
  warn "baked-in extensions may still load. For cleanest results, set"
  warn "PI_BIN to the unwrapped pi-coding-agent binary."
  warn "Continuing anyway..."
fi

# ── Pre-flight ────────────────────────────────────────────────────
header "Pre-flight"

test -f "$DIST_INDEX" && green "dist/index.js exists" || {
  red "dist/index.js MISSING — run: node build.mjs"
  exit 1
}

command -v node >/dev/null 2>&1 && green "node available ($(node --version))" || {
  red "node not found"
  exit 1
}

"$PI_BIN" --help >/dev/null 2>&1 && green "pi --help works" || {
  red "pi --help failed"
  exit 1
}

# ── Capture real HOME before we override it ───────────────────────
REAL_HOME="$HOME"
REAL_PI_DIR="$REAL_HOME/.pi"

# ── Plugin loads without crashing ─────────────────────────────────
header "Plugin load (real pi, isolated HOME)"

PI_TEST_HOME="$(mktemp -d)"
export HOME="$PI_TEST_HOME"

# Capture the user's real ~/.pi mtime before we start, so we can verify
# nothing was written there.
USER_PI_DIR="$REAL_PI_DIR"
if [[ -d "$USER_PI_DIR" ]]; then
  USER_PI_MTIME_BEFORE="$(stat -c %Y "$USER_PI_DIR" 2>/dev/null || true)"
else
  USER_PI_MTIME_BEFORE=""
fi

# Run pi with ONLY our extension. --no-extensions disables discovery
# of ~/.pi/agent/extensions/; --no-skills does the same for skills.
# The -p flag runs in non-interactive print-and-exit mode.
# We expect pi to load the extension, try to call the LLM, and either
# succeed or fail with an API error. What we DON'T want is a crash
# with an extension-loading error (syntax error, missing export, etc.).
PI_OUTPUT="$(timeout 15 "$PI_BIN" \
  --extension "$DIST_INDEX" \
  --no-extensions \
  --no-skills \
  --session-dir "$PI_TEST_HOME/.pi/sessions" \
  -p "hello" 2>&1)" || PI_EXIT=$?

# pi may exit non-zero for API errors (401, 429, etc.) — that's fine.
# We check the output for extension-loading failure patterns.
if echo "$PI_OUTPUT" | grep -qi "cannot.*extension\|failed.*load.*extension\|error.*loading.*plugin\|unexpected.*export\|syntax.*error\|MODULE_NOT_FOUND"; then
  red "pi crashed while loading extension:"
  echo "$PI_OUTPUT" | tail -20
else
  green "pi loaded extension without crashing (exit=${PI_EXIT:-0})"
fi

# ── Isolation: isolated HOME has its own .pi ──────────────────────
header "HOME isolation"

if [[ -d "$PI_TEST_HOME/.pi" ]]; then
  green "isolated .pi/ created at $PI_TEST_HOME/.pi"
else
  warn "no .pi/ in isolated HOME — pi may not have initialized (exit=${PI_EXIT:-0})"
fi

# ── Isolation: user's ~/.pi is untouched ──────────────────────────
header "User ~/.pi pollution check"

if [[ -n "$USER_PI_MTIME_BEFORE" ]]; then
  USER_PI_MTIME_AFTER="$(stat -c %Y "$USER_PI_DIR" 2>/dev/null || true)"
  if [[ "$USER_PI_MTIME_BEFORE" == "$USER_PI_MTIME_AFTER" ]]; then
    green "user ~/.pi/ unchanged (mtime preserved)"
  else
    red "user ~/.pi/ MODIFIED during test — ISOLATION BROKEN"
    red "  before: $USER_PI_MTIME_BEFORE  after: $USER_PI_MTIME_AFTER"
  fi
else
  warn "no pre-existing ~/.pi/ — cannot verify isolation (non-issue on first run)"
fi

# ── Tool registration: check via pi's stderr/log ─────────────────
header "Tool registration"

# pi doesn't print registered tools to stdout in print mode, but we
# can verify our extension was loaded by checking the isolated .pi
# settings for any auto-registration.
if [[ -f "$PI_TEST_HOME/.pi/agent/settings.json" ]]; then
  green "settings.json created in isolated HOME"
else
  warn "no settings.json — pi may not have persisted config (non-fatal)"
fi

# ── Fast structural checks (no pi needed) ─────────────────────────
header "Structural checks (Node.js import)"

STRUCT_OK=0
STRUCT_OUT="$(node 2>&1 <<NODESCRIPT
import('$DIST_INDEX').then(mod => {
  if (typeof mod.default !== 'function') {
    console.log('FAIL: default export is', typeof mod.default);
    process.exit(1);
  }
  if (mod.default.length !== 1) {
    console.log('FAIL: arity', mod.default.length, '(expected 1)');
    process.exit(1);
  }
  // Quick registration check
  const tools = [];
  const mock = {
    registerTool(def) { tools.push(def.name); },
    registerCommand() {},
    registerMessageRenderer() {},
    on() {},
    sendMessage() {},
    setThinkingLevel() {},
    getThinkingLevel() { return "high"; },
    setStatus() {},
  };
  mod.default(mock);
  const expected = ['memory_recall','memory_remember','memory_catalog','memory_forget','memory_status','memory_log_action','memory_log_decision'];
  const missing = expected.filter(n => !tools.includes(n));
  if (missing.length) {
    console.log('FAIL: missing tools:', missing.join(', '));
    process.exit(1);
  }
  if (tools.length !== 7) {
    console.log('FAIL: expected 7 tools, got', tools.length);
    process.exit(1);
  }
  console.log('OK: 7 tools registered');
  process.exit(0);
}).catch(e => {
  console.log('FAIL:', e.message);
  process.exit(1);
});
NODESCRIPT
)"

if echo "$STRUCT_OUT" | grep -q "OK"; then
  green "structural checks passed (7 tools, function export)"
else
  red "structural checks FAILED:"
  echo "$STRUCT_OUT"
fi

# ── Summary ───────────────────────────────────────────────────────
header "Results"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo -e "\n\033[31mSOME CHECKS FAILED\033[0m"
  exit 1
else
  echo -e "\n\033[32mALL CHECKS PASSED\033[0m"
  exit 0
fi
