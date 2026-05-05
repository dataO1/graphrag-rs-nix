// knowledge-watcher — filesystem sidecar that keeps the local
// knowledge graph in sync with a set of root directories.
//
// Two phases on startup:
//   1. Initial walk — recursive `WalkBuilder` (BurntSushi's `ignore`
//      crate, same engine ripgrep uses). Respects `.gitignore` chain
//      + `~/.gitignore_global` + hidden-file rules. Filters to an
//      allow-listed extension set. Posts each match to
//      `/api/documents` as `{path, id: <abs>}`. Bounded in-flight
//      so we don't hammer the embedding service.
//   2. Live inotify — `notify-debouncer-full` (file-id-aware so atomic
//      renames from Vim/VSCode/Obsidian don't slip through as pure
//      delete+create). On every debounced event under a watched root,
//      filter through the same gitignore + extension rules; POST
//      add or DELETE depending on whether the path still exists.
//
// Stable doc id = absolute path. The server's upsert-by-user_id flow
// then handles the "I edited my markdown" case correctly:
// content-hash dedup is automatic; on real changes the new chunks
// land at version+1 with `is_current = true` and the prior version's
// chunks get marked superseded.
//
// Config is env-driven (the home-manager module plumbs nix options
// through to these vars):
//   WATCHER_ROOTS               — colon-separated absolute roots
//                                 (mirrors INGEST_ALLOWED_ROOTS by default)
//   WATCHER_BASE_URL            — graphrag-server (default 127.0.0.1:8080)
//   WATCHER_DEBOUNCE_MS         — inotify debounce window (default 300)
//   WATCHER_MAX_IN_FLIGHT       — concurrent ingests cap (default 4)
//   WATCHER_INITIAL_INDEX       — "1" (default) runs the full walk on boot
//   WATCHER_ALLOWED_EXTENSIONS  — comma-separated; mirrors server's
//                                 INGEST_ALLOWED_EXTENSIONS by default
//   WATCHER_LOG                 — RUST_LOG-style filter

use anyhow::{Context, Result};
use ignore::{gitignore::GitignoreBuilder, WalkBuilder};
use notify_debouncer_full::{
    new_debouncer,
    notify::{EventKind, RecursiveMode},
    DebounceEventResult, DebouncedEvent,
};
use reqwest::Client;
use serde_json::json;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Semaphore;

#[derive(Debug, Clone)]
struct Config {
    base_url: String,
    roots: Vec<PathBuf>,
    debounce: Duration,
    max_in_flight: usize,
    initial_index: bool,
    allowed_extensions: HashSet<String>,
}

const DEFAULT_ALLOWED_EXTENSIONS: &[&str] = &[
    "md", "markdown", "mdx", "txt", "text", "rst", "org", "adoc", "asciidoc", "tex",
    "json", "yaml", "yml", "toml", "ini", "csv", "tsv", "log",
    "rs", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx",
    "go", "c", "h", "cpp", "cc", "hpp", "hh", "java", "kt", "kts",
    "rb", "php", "swift", "scala", "clj", "ex", "exs", "erl", "hs",
    "sql", "sh", "bash", "zsh", "fish", "ps1",
    "nix", "dhall",
    "html", "htm", "xml", "svg", "css", "scss", "less",
    "graphql", "gql", "proto", "thrift",
];

impl Config {
    fn from_env() -> Result<Self> {
        let base_url = std::env::var("WATCHER_BASE_URL")
            .unwrap_or_else(|_| "http://127.0.0.1:8080".to_string());

        let roots_raw = std::env::var("WATCHER_ROOTS").unwrap_or_default();
        let roots: Vec<PathBuf> = roots_raw
            .split(':')
            .filter(|s| !s.is_empty())
            .filter_map(|p| match std::fs::canonicalize(p) {
                Ok(c) => Some(c),
                Err(e) => {
                    tracing::warn!(root = %p, error = %e, "WATCHER_ROOTS: dropping unresolvable root");
                    None
                },
            })
            .collect();
        if roots.is_empty() {
            anyhow::bail!(
                "no usable roots in WATCHER_ROOTS (set it to colon-separated absolute paths)"
            );
        }

        let debounce_ms = std::env::var("WATCHER_DEBOUNCE_MS")
            .ok()
            .and_then(|s| s.parse::<u64>().ok())
            .unwrap_or(300);
        let max_in_flight = std::env::var("WATCHER_MAX_IN_FLIGHT")
            .ok()
            .and_then(|s| s.parse::<usize>().ok())
            .filter(|n| *n > 0)
            .unwrap_or(4);
        let initial_index = std::env::var("WATCHER_INITIAL_INDEX")
            .map(|s| matches!(s.as_str(), "1" | "true" | "TRUE" | "yes" | "YES"))
            .unwrap_or(true);

        let allowed_extensions = std::env::var("WATCHER_ALLOWED_EXTENSIONS")
            .ok()
            .map(|s| {
                s.split(',')
                    .map(|e| e.trim().trim_start_matches('.').to_ascii_lowercase())
                    .filter(|e| !e.is_empty())
                    .collect::<HashSet<_>>()
            })
            .unwrap_or_else(|| {
                DEFAULT_ALLOWED_EXTENSIONS
                    .iter()
                    .map(|s| s.to_string())
                    .collect()
            });

        Ok(Self {
            base_url,
            roots,
            debounce: Duration::from_millis(debounce_ms),
            max_in_flight,
            initial_index,
            allowed_extensions,
        })
    }
}

/// Whether the path passes the watcher's eligibility filter:
///   * inside one of the watched roots
///   * not a directory
///   * extension is in the allow-list
///   * not a known editor backup pattern
///
/// gitignore handling is layered on top via `WalkBuilder` (initial
/// walk) and a `Gitignore` matcher (live events).
fn is_eligible(path: &Path, allowed_extensions: &HashSet<String>) -> bool {
    if !path.is_file() {
        return false;
    }
    // Reject paths where ANY component is a hidden dir (.git/,
    // .obsidian/, .venv/, .cache/, .direnv/, ...). The initial
    // `WalkBuilder::standard_filters` skips these naturally; the live
    // inotify path doesn't, so we re-implement that filter here.
    // Allows leading "/" and "." / ".." which are root markers.
    if path
        .components()
        .filter_map(|c| c.as_os_str().to_str())
        .any(|s| s.starts_with('.') && s != "." && s != "..")
    {
        return false;
    }
    let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
        return false;
    };
    // Editor backups + common noise even gitignore won't catch.
    if name.ends_with('~') {
        return false;
    }
    if name == "4913" /* vim probe */ || name.ends_with(".swp") || name.ends_with(".swo") {
        return false;
    }
    if name.starts_with('#') && name.ends_with('#') {
        return false;
    }
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .unwrap_or_default();
    allowed_extensions.contains(&ext)
}

/// Same hidden-component check, exposed for the DELETE path where
/// `is_eligible` can't be used (the file is gone, so `is_file()` is
/// false). Both `is_eligible` and live DELETE need to skip
/// .obsidian/.git/etc.
fn path_has_hidden_component(path: &Path) -> bool {
    path.components()
        .filter_map(|c| c.as_os_str().to_str())
        .any(|s| s.starts_with('.') && s != "." && s != "..")
}

/// Build a unified gitignore matcher across all watched roots so live
/// inotify events can be filtered identically to the initial walk.
/// `WalkBuilder` already does this internally; for live events we
/// reproduce it via a single `Gitignore` rooted at "/" with `add(...)`
/// for each per-root .gitignore the walker would have honored.
///
/// Imperfect — if a file is under multiple .gitignore scopes, only the
/// nearest .gitignore is consulted here. For accurate filtering we'd
/// need to walk the parent chain on every event, which is what the
/// `ignore` crate's WalkBuilder does for batch scans. Good enough for
/// the live path; the initial walk is exact.
fn build_global_gitignore(roots: &[PathBuf]) -> ignore::gitignore::Gitignore {
    let mut builder = GitignoreBuilder::new("/");
    // Per-root .gitignore. Walk up so a deeply-nested root still gets
    // its parent .gitignore (e.g. ~/code/.gitignore covers
    // ~/code/proj-a/notes/).
    for r in roots {
        let mut p = r.clone();
        loop {
            let gi = p.join(".gitignore");
            if gi.is_file() {
                let _ = builder.add(gi);
            }
            if !p.pop() {
                break;
            }
        }
    }
    // ~/.config/git/ignore (XDG) and ~/.gitignore_global where present.
    if let Some(home) = dirs_home() {
        let xdg = home.join(".config/git/ignore");
        if xdg.is_file() {
            let _ = builder.add(xdg);
        }
        let global = home.join(".gitignore_global");
        if global.is_file() {
            let _ = builder.add(global);
        }
    }
    builder.build().unwrap_or_else(|_| {
        // Empty matcher fallback: no files ignored beyond our manual filters.
        GitignoreBuilder::new("/").build().unwrap()
    })
}

fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

#[derive(Debug)]
enum IngestAction {
    Upsert(PathBuf),
    Delete(PathBuf),
}

async fn post_upsert(client: &Client, base_url: &str, path: &Path) -> Result<()> {
    let abs = path.to_string_lossy().into_owned();
    let body = json!({ "path": abs, "id": abs });
    let resp = client
        .post(format!("{base_url}/api/documents"))
        .json(&body)
        .send()
        .await
        .with_context(|| format!("POST /api/documents for {abs}"))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        anyhow::bail!("upsert {abs} → {status}: {text}");
    }
    Ok(())
}

async fn post_delete(client: &Client, base_url: &str, path: &Path) -> Result<()> {
    let abs = path.to_string_lossy().into_owned();
    let url = format!(
        "{base_url}/api/documents/{}",
        urlencoding(&abs)
    );
    let resp = client
        .delete(url)
        .send()
        .await
        .with_context(|| format!("DELETE /api/documents/{abs}"))?;
    if !resp.status().is_success() && resp.status().as_u16() != 404 {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        anyhow::bail!("delete {abs} → {status}: {text}");
    }
    Ok(())
}

/// Minimal percent-encoder for path segments — `urlencoding` crate
/// would do the same in 2 lines but we don't want the extra dep.
fn urlencoding(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char);
            },
            _ => {
                out.push('%');
                out.push_str(&format!("{:02X}", b));
            },
        }
    }
    out
}

/// Walk every root once, posting each eligible file to /api/documents.
/// Bounded in-flight via a tokio semaphore so we don't open thousands
/// of HTTP connections at once.
async fn run_initial_walk(cfg: Arc<Config>, client: Arc<Client>) {
    tracing::info!(roots = ?cfg.roots, "initial walk starting");
    let sem = Arc::new(Semaphore::new(cfg.max_in_flight));
    let mut handles = Vec::new();
    let mut counted = 0usize;

    for root in cfg.roots.iter() {
        let walker = WalkBuilder::new(root)
            .standard_filters(true)   // .gitignore + .ignore + hidden
            .git_global(true)
            .git_ignore(true)
            .git_exclude(true)
            .hidden(true)
            .parents(true)
            .build();
        for entry in walker.flatten() {
            let path = entry.path().to_path_buf();
            if !is_eligible(&path, &cfg.allowed_extensions) {
                continue;
            }
            counted += 1;
            let permit = sem.clone().acquire_owned().await.unwrap();
            let client = client.clone();
            let cfg = cfg.clone();
            handles.push(tokio::spawn(async move {
                let _permit = permit;
                if let Err(e) = post_upsert(&client, &cfg.base_url, &path).await {
                    tracing::warn!(path = %path.display(), error = %e, "initial-walk upsert failed");
                }
            }));
            if counted % 50 == 0 {
                tracing::info!(scanned = counted, "initial walk progress");
            }
        }
    }
    for h in handles {
        let _ = h.await;
    }
    tracing::info!(total = counted, "initial walk complete");
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("WATCHER_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let cfg = Arc::new(Config::from_env()?);
    tracing::info!(
        base_url = %cfg.base_url,
        roots = ?cfg.roots,
        debounce_ms = cfg.debounce.as_millis() as u64,
        max_in_flight = cfg.max_in_flight,
        initial_index = cfg.initial_index,
        ext_count = cfg.allowed_extensions.len(),
        "knowledge-watcher starting"
    );

    let client = Arc::new(
        Client::builder()
            .timeout(Duration::from_secs(120))
            .build()?,
    );

    if cfg.initial_index {
        // Run the initial walk in the same task; it returns when done.
        // Errors-per-file are logged, not propagated.
        run_initial_walk(cfg.clone(), client.clone()).await;
    } else {
        tracing::info!("initial walk disabled by WATCHER_INITIAL_INDEX=0");
    }

    // Bridge the synchronous notify callback onto a tokio mpsc.
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Vec<DebouncedEvent>>();
    let tx_for_notify = tx.clone();
    let mut debouncer = new_debouncer(
        cfg.debounce,
        None,
        move |res: DebounceEventResult| match res {
            Ok(events) => {
                let _ = tx_for_notify.send(events);
            },
            Err(errs) => {
                for e in errs {
                    tracing::warn!(error = %e, "notify error");
                }
            },
        },
    )
    .context("init debouncer")?;

    for root in cfg.roots.iter() {
        debouncer
            .watch(root, RecursiveMode::Recursive)
            .with_context(|| format!("watch {}", root.display()))?;
    }
    tracing::info!("inotify watchers armed");

    let live_gi = build_global_gitignore(&cfg.roots);
    let sem = Arc::new(Semaphore::new(cfg.max_in_flight));

    while let Some(batch) = rx.recv().await {
        for evt in batch {
            for path in evt.paths.iter() {
                let action = classify_event(&evt.event.kind, path);
                let Some(action) = action else { continue };

                // Path-eligibility check applies to both Upsert and
                // Delete (so a deleted .swp / .git/index doesn't
                // trigger a bogus DELETE call).
                let skip = match &action {
                    IngestAction::Delete(p) => {
                        // File is gone; can't stat or check extension
                        // robustly. Reject anything under a hidden
                        // dir (.git/, .obsidian/, ...) and anything
                        // matching the editor-backup name patterns.
                        if path_has_hidden_component(p) {
                            true
                        } else if let Some(name) = p.file_name().and_then(|n| n.to_str()) {
                            name.ends_with('~')
                                || name.ends_with(".swp")
                                || name.ends_with(".swo")
                                || name == "4913"
                                || (name.starts_with('#') && name.ends_with('#'))
                        } else {
                            true
                        }
                    },
                    IngestAction::Upsert(p) => !is_eligible(p, &cfg.allowed_extensions),
                };
                if skip {
                    continue;
                }

                // gitignore check (live path only — initial walk handled it inline).
                let abs = match &action {
                    IngestAction::Upsert(p) | IngestAction::Delete(p) => p.clone(),
                };
                if live_gi
                    .matched_path_or_any_parents(&abs, /* is_dir */ false)
                    .is_ignore()
                {
                    continue;
                }

                let permit = sem.clone().acquire_owned().await.unwrap();
                let client = client.clone();
                let base_url = cfg.base_url.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    let res = match action {
                        IngestAction::Upsert(p) => {
                            tracing::info!(path = %p.display(), "upsert");
                            post_upsert(&client, &base_url, &p).await
                        },
                        IngestAction::Delete(p) => {
                            tracing::info!(path = %p.display(), "delete");
                            post_delete(&client, &base_url, &p).await
                        },
                    };
                    if let Err(e) = res {
                        tracing::warn!(error = %e, "live ingest failed");
                    }
                });
            }
        }
    }

    Ok(())
}

/// Map a debounced filesystem event to an IngestAction. Atomic-rename
/// editors fire MOVED_TO + REMOVE pairs; we treat MOVED_TO as upsert
/// of the destination and let the REMOVE path handler deal with the
/// short window where the old name briefly disappears (the server's
/// `find_current_by_user_id` will see the new id without the old one,
/// so the next upsert call recreates the doc cleanly).
fn classify_event(kind: &EventKind, path: &Path) -> Option<IngestAction> {
    match kind {
        EventKind::Create(_) => Some(IngestAction::Upsert(path.to_path_buf())),
        EventKind::Modify(notify::event::ModifyKind::Data(_)) => {
            Some(IngestAction::Upsert(path.to_path_buf()))
        },
        EventKind::Modify(notify::event::ModifyKind::Name(notify::event::RenameMode::To)) => {
            Some(IngestAction::Upsert(path.to_path_buf()))
        },
        EventKind::Modify(notify::event::ModifyKind::Name(notify::event::RenameMode::From)) => {
            Some(IngestAction::Delete(path.to_path_buf()))
        },
        EventKind::Modify(notify::event::ModifyKind::Name(notify::event::RenameMode::Both)) => {
            // Rename within watched root: notify-debouncer-full reports
            // both legs; we'll pick them up via the To/From branches
            // above for non-`Both` events. Treat the path as upsert if
            // it currently exists.
            if path.is_file() {
                Some(IngestAction::Upsert(path.to_path_buf()))
            } else {
                Some(IngestAction::Delete(path.to_path_buf()))
            }
        },
        EventKind::Remove(_) => Some(IngestAction::Delete(path.to_path_buf())),
        _ => None,
    }
}
