// Session-log writer for the memory-mcp server.
//
// Two MCP tools — `log_action` and `log_decision` — append rows to the
// active session's log file under the user's recorded journal area.
// Layout: two alternating table schemas in one chronological file. See
// the plugin's CLAUDE.md "Storage conventions" section for the rules
// this module enforces.
//
// The agent's responsibilities collapse to passing the row fields. This
// module owns:
//   - file path resolution (`<sessionLogRoot>/<YYYY-MM-DD>/<host>-<agent>-<project>-<HHMMSS>.md`)
//   - server-side timestamping (the Time column is stamped here, not
//     extracted from the hook's `Now:` block — see Q2.2 in the design)
//   - first-write-of-day file creation (with frontmatter template)
//   - schema-matching append (peek the latest table block; emit a new
//     header inline if the schema doesn't match the row type)
//   - frontmatter `topics:` union with each row's `related[]` links
//   - per-file serialization (global mutex; logging is infrequent and
//     concurrent parent+subagent writes need stable chronological
//     order)

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Local};
use serde::Deserialize;
use serde_json::Value;
use std::path::{Path, PathBuf};
use tokio::sync::Mutex;

/// Single global mutex for all log writes. Logging is rare enough
/// (handful of writes per session) that a global lock costs nothing,
/// and the alternative (per-path mutex map) adds bookkeeping for no
/// throughput gain.
pub static LOG_WRITE_MUTEX: Mutex<()> = Mutex::const_new(());

/// Captured-at-startup metadata the logger needs on every call.
/// Built once in `main()` from env + `std::env::current_dir()`; passed
/// by reference to each tool handler.
#[derive(Debug, Clone)]
pub struct LogContext {
    /// `<sessionLogRoot>` (e.g. `~/Notes/📔 Journal/agent-log`),
    /// expanded. The skill module on the home-manager side defaults
    /// this to the Obsidian journal area but it's settable per host.
    pub session_log_root: PathBuf,
    /// `gethostname()` at startup.
    pub host: String,
    /// Fixed `claude-code` for this server (Claude Code is the only
    /// client wiring this MCP server in today; if a second client
    /// ever shows up they get their own `agent` value).
    pub agent: String,
    /// `basename(cwd)` at startup. Inherits down to subagents that
    /// share the parent's spawned MCP server instance.
    pub project: String,
    /// Session-start `HH:MM:SS` (no colons in the filename). Captured
    /// once at startup; used as the filename suffix for a brand-new
    /// log file.
    pub session_start_hhmmss: String,
    /// `YYYY-MM-DD` snapshot of the date at startup. Used to derive the
    /// per-day directory. Sessions that cross midnight keep writing to
    /// their original date's directory (matches the existing skill's
    /// behavior — the file is keyed by SESSION-START date, not call
    /// date).
    pub session_date: String,
}

impl LogContext {
    /// Try to assemble a LogContext from env + cwd. Returns Ok(None) if
    /// `MEMORY_SESSION_LOG_ROOT` is unset — in that case the server
    /// still starts, but log_action / log_decision will refuse with a
    /// clear error. Returns Err only for unrecoverable filesystem
    /// errors (cwd unreadable, hostname missing AND that's somehow
    /// catastrophic — neither is, so practically Err is rare).
    pub fn from_env_and_cwd() -> Result<Option<Self>> {
        let raw = match std::env::var("MEMORY_SESSION_LOG_ROOT") {
            Ok(v) if !v.is_empty() => v,
            _ => return Ok(None),
        };
        let session_log_root = PathBuf::from(expand_tilde(&raw));

        let cwd = std::env::current_dir()
            .context("could not read startup cwd")?;
        let project = cwd
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| anyhow!("startup cwd has no basename: {cwd:?}"))?
            .to_string();

        let host = hostname().unwrap_or_else(|| "unknown".to_string());

        let now: DateTime<Local> = Local::now();
        let session_start_hhmmss = now.format("%H%M%S").to_string();
        let session_date = now.format("%Y-%m-%d").to_string();

        Ok(Some(Self {
            session_log_root,
            host,
            agent: "claude-code".to_string(),
            project,
            session_start_hhmmss,
            session_date,
        }))
    }
}

fn expand_tilde(p: &str) -> String {
    if let Some(rest) = p.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{home}/{rest}");
        }
    }
    p.to_string()
}

fn hostname() -> Option<String> {
    // Linux: /proc/sys/kernel/hostname is authoritative and cheap to
    // read; avoids pulling in a `hostname` crate just for this.
    std::fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// Caller-provided fields for a log_action row.
#[derive(Debug, Deserialize)]
pub struct LogActionArgs {
    pub actions: String,
    #[serde(default)]
    pub mutations: Option<String>,
    pub why: String,
    pub outcome: String,
    #[serde(default)]
    pub related: Vec<String>,
}

/// Caller-provided fields for a log_decision row.
#[derive(Debug, Deserialize)]
pub struct LogDecisionArgs {
    pub context: String,
    pub options: String,
    pub decision: String,
    #[serde(default)]
    pub rollout: Option<String>,
    #[serde(default)]
    pub rollback: Option<String>,
    #[serde(default)]
    pub related: Vec<String>,
}

/// Row schema — determines whether the latest table in the file
/// matches.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Schema {
    LogAction,
    LogDecision,
}

impl Schema {
    fn header(self) -> &'static str {
        match self {
            Self::LogAction =>
                "| Time | Actions | Mutations | Why | Outcome | Related |\n\
                 |------|---------|-----------|-----|---------|---------|",
            Self::LogDecision =>
                "| Time | Context | Options | Decision | Rollout | Rollback | Related |\n\
                 |------|---------|---------|----------|---------|----------|---------|",
        }
    }

    /// Match the *header line* of an existing table block against this
    /// schema. The body's separator line is similar enough across
    /// schemas that header alone is the reliable discriminator.
    fn matches_header(self, line: &str) -> bool {
        let normalized = line.trim();
        match self {
            Self::LogAction =>
                normalized.contains("Actions")
                && normalized.contains("Mutations")
                && normalized.contains("Outcome"),
            Self::LogDecision =>
                normalized.contains("Context")
                && normalized.contains("Options")
                && normalized.contains("Decision")
                && normalized.contains("Rollback"),
        }
    }
}

/// Public entry — log_action MCP call.
pub async fn handle_log_action(ctx: Option<&LogContext>, args: LogActionArgs) -> Result<Value> {
    let ctx = ctx.ok_or_else(|| anyhow!(
        "logging_disabled: MEMORY_SESSION_LOG_ROOT was not set when this memory-mcp server started — log_action / log_decision cannot resolve a log file. Set the env var in the MCP client config (home-manager modules.claude-code-memory / services.graphrag-rs already wire it from `sessionLogRoot`) and restart the MCP server."
    ))?;
    let _guard = LOG_WRITE_MUTEX.lock().await;
    validate_non_empty("actions", &args.actions)?;
    validate_non_empty("why", &args.why)?;
    validate_non_empty("outcome", &args.outcome)?;

    let now: DateTime<Local> = Local::now();
    let row = format!(
        "| {time} | {actions} | {mutations} | {why} | {outcome} | {related} |",
        time = now.format("%Y-%m-%d %H:%M:%S"),
        actions = escape_cell(&args.actions),
        mutations = escape_cell(args.mutations.as_deref().unwrap_or("")),
        why = escape_cell(&args.why),
        outcome = escape_cell(&args.outcome),
        related = related_cell(&args.related),
    );

    let path = resolve_or_create_log_file(ctx).await?;
    append_row(&path, Schema::LogAction, &row).await?;
    if !args.related.is_empty() {
        union_frontmatter_topics(&path, &args.related).await?;
    }

    Ok(serde_json::json!({
        "content": [{ "type": "text", "text": "" }],
        "isError": false,
    }))
}

/// Public entry — log_decision MCP call.
pub async fn handle_log_decision(ctx: Option<&LogContext>, args: LogDecisionArgs) -> Result<Value> {
    let ctx = ctx.ok_or_else(|| anyhow!(
        "logging_disabled: MEMORY_SESSION_LOG_ROOT was not set when this memory-mcp server started — log_action / log_decision cannot resolve a log file. Set the env var in the MCP client config and restart the MCP server."
    ))?;
    let _guard = LOG_WRITE_MUTEX.lock().await;
    validate_non_empty("context", &args.context)?;
    validate_non_empty("options", &args.options)?;
    validate_non_empty("decision", &args.decision)?;

    let now: DateTime<Local> = Local::now();
    let row = format!(
        "| {time} | {context} | {options} | {decision} | {rollout} | {rollback} | {related} |",
        time = now.format("%Y-%m-%d %H:%M:%S"),
        context = escape_cell(&args.context),
        options = escape_cell(&args.options),
        decision = escape_cell(&args.decision),
        rollout = escape_cell(args.rollout.as_deref().unwrap_or("N/A")),
        rollback = escape_cell(args.rollback.as_deref().unwrap_or("N/A")),
        related = related_cell(&args.related),
    );

    let path = resolve_or_create_log_file(ctx).await?;
    append_row(&path, Schema::LogDecision, &row).await?;
    if !args.related.is_empty() {
        union_frontmatter_topics(&path, &args.related).await?;
    }

    Ok(serde_json::json!({
        "content": [{ "type": "text", "text": "" }],
        "isError": false,
    }))
}

fn validate_non_empty(name: &str, v: &str) -> Result<()> {
    if v.trim().is_empty() {
        Err(anyhow!("invalid_field: `{name}` is required and cannot be empty or whitespace-only"))
    } else {
        Ok(())
    }
}

/// Escape characters that would break a markdown table cell.
///
/// - `|` is the cell delimiter — escape with `\|`
/// - Newlines (`\n`) break the row — replace with `<br>`
fn escape_cell(s: &str) -> String {
    s.replace('|', "\\|").replace('\n', "<br>")
}

fn related_cell(items: &[String]) -> String {
    if items.is_empty() {
        return String::new();
    }
    items
        .iter()
        .map(|s| escape_cell(s.trim()))
        .collect::<Vec<_>>()
        .join(", ")
}

/// Resolve the log file path for this session. Looks for an existing
/// file matching `<host>-<agent>-<project>-*.md` in the date dir
/// (continues an earlier same-day session in the same project if one
/// exists) — otherwise creates a new file with the session-start
/// HHMMSS suffix and writes the frontmatter template.
async fn resolve_or_create_log_file(ctx: &LogContext) -> Result<PathBuf> {
    let dir = ctx.session_log_root.join(&ctx.session_date);
    tokio::fs::create_dir_all(&dir)
        .await
        .with_context(|| format!("could not create log dir {dir:?}"))?;

    let prefix = format!("{}-{}-{}-", ctx.host, ctx.agent, ctx.project);

    // Glob for an existing file (same-day, same project, any HHMMSS).
    let mut existing: Option<PathBuf> = None;
    if let Ok(mut rd) = tokio::fs::read_dir(&dir).await {
        while let Some(entry) = rd.next_entry().await? {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str.starts_with(&prefix) && name_str.ends_with(".md") {
                existing = Some(entry.path());
                break;
            }
        }
    }

    if let Some(p) = existing {
        return Ok(p);
    }

    // First write of this session in this project today — create the file.
    let path = dir.join(format!("{prefix}{}.md", ctx.session_start_hhmmss));
    let frontmatter = format!(
        "---\n\
         date: {date}\n\
         session_start: {session_start}\n\
         host: {host}\n\
         agent: {agent}\n\
         topics: \n\
         ---\n\n\
         # Agent log — {date} — {host} / {agent}\n\n",
        date = ctx.session_date,
        session_start = Local::now().to_rfc3339(),
        host = ctx.host,
        agent = ctx.agent,
    );
    tokio::fs::write(&path, frontmatter)
        .await
        .with_context(|| format!("could not create log file {path:?}"))?;
    Ok(path)
}

/// Read the file, find the LAST table block (header + separator +
/// rows), check whether its schema matches `target`. If yes, append
/// `row` directly. If no (or no table exists yet), append a fresh
/// header block then the row.
async fn append_row(path: &Path, target: Schema, row: &str) -> Result<()> {
    let content = tokio::fs::read_to_string(path)
        .await
        .with_context(|| format!("could not read log file {path:?}"))?;

    // Find the most recent header line by walking backwards.
    let mut latest_header: Option<&str> = None;
    for line in content.lines().rev() {
        if line.starts_with('|') && line.contains("Time") && !line.contains("---") {
            // Sanity: must be a header (not a data row). Data-row
            // first cell starts with a timestamp digit, header's
            // first cell is "Time".
            let first_cell = line
                .trim_start_matches('|')
                .split('|')
                .next()
                .unwrap_or("")
                .trim();
            if first_cell == "Time" {
                latest_header = Some(line);
                break;
            }
        }
    }

    let need_new_header = match latest_header {
        Some(h) => !target.matches_header(h),
        None => true,
    };

    let mut to_append = String::new();
    // Ensure file ends in a newline before we add.
    if !content.ends_with('\n') {
        to_append.push('\n');
    }
    if need_new_header {
        to_append.push('\n');
        to_append.push_str(target.header());
        to_append.push('\n');
    }
    to_append.push_str(row);
    to_append.push('\n');

    let mut file = tokio::fs::OpenOptions::new()
        .append(true)
        .open(path)
        .await
        .with_context(|| format!("could not open log file for append {path:?}"))?;
    use tokio::io::AsyncWriteExt;
    file.write_all(to_append.as_bytes()).await?;
    file.flush().await?;
    Ok(())
}

/// Union the row's `related[]` items into the frontmatter `topics:`
/// list. Read-modify-write the whole file; safe under the global
/// log-write mutex.
async fn union_frontmatter_topics(path: &Path, related: &[String]) -> Result<()> {
    let content = tokio::fs::read_to_string(path).await?;

    // Front-matter block is the first `---\n...---\n` pair.
    let after_open = match content.strip_prefix("---\n") {
        Some(s) => s,
        None => return Ok(()), // no frontmatter — skip silently
    };
    let close_idx = match after_open.find("\n---\n") {
        Some(i) => i,
        None => return Ok(()),
    };
    let fm = &after_open[..close_idx];
    let rest_start = "---\n".len() + close_idx + "\n---\n".len();
    let rest = &content[rest_start..];

    // Find the `topics:` line.
    let mut lines: Vec<String> = fm.lines().map(|l| l.to_string()).collect();
    let topics_idx = lines.iter().position(|l| l.starts_with("topics:"));

    let mut existing: Vec<String> = Vec::new();
    if let Some(i) = topics_idx {
        // Parse `topics: [[a]], [[b]], ...`.
        let after_colon = lines[i].splitn(2, ':').nth(1).unwrap_or("").trim();
        for piece in after_colon.split(',') {
            let p = piece.trim().to_string();
            if !p.is_empty() {
                existing.push(p);
            }
        }
    }

    // Add new related items if not already present (string compare on
    // wiki-link form, e.g. `[[Foo Bar]]`).
    let mut changed = false;
    for r in related {
        let wikified = if r.starts_with("[[") {
            r.trim().to_string()
        } else {
            format!("[[{}]]", r.trim())
        };
        if wikified.is_empty() || wikified == "[[]]" {
            continue;
        }
        if !existing.contains(&wikified) {
            existing.push(wikified);
            changed = true;
        }
    }

    if !changed {
        return Ok(());
    }

    let new_topics_line = format!("topics: {}", existing.join(", "));
    if let Some(i) = topics_idx {
        lines[i] = new_topics_line;
    } else {
        lines.push(new_topics_line);
    }

    let new_fm = lines.join("\n");
    let new_content = format!("---\n{new_fm}\n---\n{rest}");

    // Atomic-ish write — write tmp + rename.
    let tmp = path.with_extension("md.tmp");
    tokio::fs::write(&tmp, new_content).await?;
    tokio::fs::rename(&tmp, path).await?;
    Ok(())
}
