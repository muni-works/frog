//! Child sessions the engine owns itself, for when no client hosts sessions (headless, the
//! CLI, `frog serve`). The Mac answers `StartSession` and friends itself; everywhere else the
//! engine does it here, with the same contract:
//!
//! - a child is a real session: its own engine, its own log (its header names its `parent`,
//!   so `frog --sessions` draws the tree), and, when it can write, its own git worktree on a
//!   branch named from its title;
//! - when it ends a turn, its parent gets a short note (the child's last reply, capped) as an
//!   [`Op::Deliver`] from the child: it wakes an idle parent and queues behind a busy one;
//! - its permission prompts surface on the parent, labelled with the child's id (the
//!   "Needs you" of the tree), and the parent's answer goes back to the child;
//! - the parent can message it (`SendMessage`), stop it, and archive it.
//!
//! Children live as long as their parent's engine; their logs outlive both.

use crate::engine::{Handle, Options};
use crate::protocol::{Event, Item, Op};
use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::sync::mpsc;

/// How much of a child's last reply its parent's note carries.
pub const REPORT_CAP: usize = 2_000;

#[derive(Clone, Debug, Default, PartialEq)]
pub struct State {
    pub running: bool,
    /// Permission prompts waiting on the user.
    pub needs_you: usize,
    pub turns: u32,
    /// Its last reply.
    pub report: String,
    /// How its last turn ended (`complete`, `cancelled`, ...).
    pub ended: Option<String>,
}

struct Kid {
    name: String,
    cwd: PathBuf,
    branch: Option<String>,
    ops: mpsc::UnboundedSender<Op>,
    state: Arc<Mutex<State>>,
    archived: bool,
}

/// The children one engine owns.
#[derive(Default)]
pub struct Kids {
    kids: Mutex<BTreeMap<String, Kid>>,
    /// The parent's own op queue (weak, so children don't keep it alive).
    inbox: Mutex<Option<mpsc::WeakUnboundedSender<Op>>>,
    /// The parent's background registry: its event stream and permission relay.
    relay: Mutex<Option<Arc<crate::background::Registry>>>,
}

/// The tools the engine answers itself when no client hosts sessions.
pub fn handles(name: &str) -> bool {
    use crate::tools::sessions::*;
    matches!(name, LIST | SEND | START | ARCHIVE | STATUS | STOP)
}

/// The note a parent gets when a child ends a turn.
pub fn note(name: &str, state: &State) -> String {
    let report = cap(state.report.trim(), REPORT_CAP);
    let how = state.ended.as_deref().unwrap_or("complete");
    let head = if how == "complete" {
        format!("{name} finished a turn.")
    } else {
        format!("{name} stopped ({how}).")
    };
    if report.is_empty() {
        head
    } else {
        format!("{head} Its report:\n\n{report}")
    }
}

fn cap(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        return s.to_string();
    }
    let mut out: String = s.chars().take(n).collect();
    out.push_str(" …(cut; ReadSession or open the session for the rest)");
    out
}

/// A branch-safe slug of a title: `fix the login bug` → `fix-the-login-bug`.
pub fn slug(title: &str) -> String {
    let mut s = String::new();
    for c in title.trim().to_lowercase().chars() {
        let c = if c.is_ascii_alphanumeric() { c } else { '-' };
        if !(c == '-' && (s.is_empty() || s.ends_with('-'))) {
            s.push(c);
        }
    }
    let s: String = s.chars().take(40).collect();
    let s = s.trim_end_matches('-').to_string();
    if s.is_empty() { "task".into() } else { s }
}

/// Whether a `StartSession` call wants its own worktree: yes unless it's read-only, names a
/// folder, or says `worktree: false`.
pub fn wants_worktree(input: &Value) -> bool {
    if input["read_only"].as_bool() == Some(true) {
        return false;
    }
    match input["worktree"].as_bool() {
        Some(w) => w,
        None => input["cwd"].as_str().is_none_or(|c| c.trim().is_empty()),
    }
}

/// A new worktree for `title` under `<repo>/.frog/worktrees`, on branch `frog/<slug>` from the
/// remote default branch (or HEAD). None when `root` isn't in a git repo.
pub fn make_worktree(root: &Path, title: &str) -> Result<Option<(PathBuf, String)>> {
    let git = |args: &[&str]| {
        std::process::Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .output()
    };
    let top = match git(&["rev-parse", "--show-toplevel"]) {
        Ok(o) if o.status.success() => PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()),
        _ => return Ok(None),
    };
    // The main checkout, even when `root` is itself a linked worktree.
    let main = crate::worktree::linked(&top).map(|(m, _)| m).unwrap_or(top);
    let base = git(&["rev-parse", "--verify", "--quiet", "origin/HEAD"])
        .ok()
        .filter(|o| o.status.success())
        .map(|_| "origin/HEAD")
        .unwrap_or("HEAD");
    let slug = slug(title);
    for n in 0..50 {
        let name = if n == 0 {
            slug.clone()
        } else {
            format!("{slug}-{n}")
        };
        let dir = main.join(".frog/worktrees").join(&name);
        let branch = format!("frog/{name}");
        if dir.exists() {
            continue;
        }
        let o = std::process::Command::new("git")
            .arg("-C")
            .arg(&main)
            .args(["worktree", "add", "-b", &branch])
            .arg(&dir)
            .arg(base)
            .output()?;
        if o.status.success() {
            return Ok(Some((dir, branch)));
        }
        let err = String::from_utf8_lossy(&o.stderr);
        if !err.contains("already exists") {
            bail!("git worktree add failed: {}", err.trim());
        }
    }
    bail!("no free worktree name for `{slug}`")
}

impl Kids {
    pub fn set_inbox(&self, tx: &mpsc::UnboundedSender<Op>) {
        *self.inbox.lock().unwrap() = Some(tx.downgrade());
    }

    fn deliver(&self, from: &str, name: &str, message: String) {
        let tx = self
            .inbox
            .lock()
            .unwrap()
            .as_ref()
            .and_then(|w| w.upgrade());
        if let Some(tx) = tx {
            let _ = tx.send(Op::Deliver {
                from: from.into(),
                from_name: name.into(),
                message,
            });
        }
    }

    pub fn live(&self) -> usize {
        self.kids
            .lock()
            .unwrap()
            .values()
            .filter(|k| !k.archived)
            .count()
    }

    pub fn state(&self, id: &str) -> Option<State> {
        let kids = self.kids.lock().unwrap();
        kids.get(id).map(|k| k.state.lock().unwrap().clone())
    }

    /// A child by id or name. `self`/`me`/`this` name the session asking, which here is the
    /// parent engine — not a child, so there's nothing to look up; say that instead of
    /// "no session `self`". An exact id or name match still wins, as on the Mac's broker.
    fn find(&self, who: &str) -> Result<String> {
        let kids = self.kids.lock().unwrap();
        if kids.contains_key(who) {
            return Ok(who.to_string());
        }
        if let Some(id) = kids
            .iter()
            .find(|(_, k)| k.name.eq_ignore_ascii_case(who))
            .map(|(id, _)| id.clone())
        {
            return Ok(id);
        }
        if crate::tools::sessions::is_self(who) {
            bail!(
                "That's this session: the sessions here are the children it started, so there's no separate one to name. ListSessions shows them."
            );
        }
        let known: Vec<String> = kids
            .iter()
            .map(|(id, k)| format!("{} ({id})", k.name))
            .collect();
        bail!(
            "no session `{who}` started from this one. Known: {}",
            if known.is_empty() {
                "none".into()
            } else {
                known.join(", ")
            }
        )
    }

    /// Adopt a spawned child engine: watch its events, relay its permission prompts through
    /// `relay` (the parent's), and note its finished turns to the parent.
    pub async fn adopt(
        self: &Arc<Self>,
        mut handle: Handle,
        name: String,
        cwd: PathBuf,
        branch: Option<String>,
        prompt: String,
        relay: Arc<crate::background::Registry>,
    ) -> Result<String> {
        // The first envelope names the child's session.
        let first = handle
            .events
            .recv()
            .await
            .ok_or_else(|| anyhow!("the new session's engine exited at once"))?;
        let id = first.session.clone();
        *self.relay.lock().unwrap() = Some(relay.clone());
        // Its first turn is on the way.
        let state = Arc::new(Mutex::new(State {
            running: true,
            ..Default::default()
        }));
        self.kids.lock().unwrap().insert(
            id.clone(),
            Kid {
                name: name.clone(),
                cwd,
                branch,
                ops: handle.ops.clone(),
                state: state.clone(),
                archived: false,
            },
        );
        handle.ops.send(Op::Submit {
            text: prompt,
            images: Vec::new(),
            more: Vec::new(),
        })?;
        let (kids, id2) = (self.clone(), id.clone());
        kids.announce(&id, &relay);
        tokio::spawn(async move {
            let ops = handle.ops.clone();
            while let Some(env) = handle.events.recv().await {
                match env.event {
                    Event::TurnStarted { .. } => {
                        let mut s = state.lock().unwrap();
                        s.running = true;
                        s.ended = None;
                        drop(s);
                        kids.announce(&id2, &relay);
                    }
                    Event::ItemCompleted {
                        item: Item::Message { text },
                        ..
                    } if !text.trim().is_empty() => state.lock().unwrap().report = text,
                    Event::TurnEnded { reason, .. } => {
                        let how = serde_json::to_value(&reason)
                            .ok()
                            .and_then(|v| v["type"].as_str().map(String::from))
                            .unwrap_or_else(|| "complete".into());
                        let snap = {
                            let mut s = state.lock().unwrap();
                            s.running = false;
                            s.turns += 1;
                            s.ended = Some(how);
                            s.clone()
                        };
                        let archived = kids
                            .kids
                            .lock()
                            .unwrap()
                            .get(&id2)
                            .is_none_or(|k| k.archived);
                        kids.announce(&id2, &relay);
                        if !archived {
                            kids.deliver(&id2, &name, note(&name, &snap));
                        }
                    }
                    Event::PermissionRequest {
                        id,
                        item: _,
                        name: tool,
                        arg,
                        always,
                        preview,
                        reason,
                        subagent: _,
                        card,
                    } => {
                        state.lock().unwrap().needs_you += 1;
                        kids.announce(&id2, &relay);
                        relay.relay_to(&id, &ops);
                        relay.emit(Event::PermissionRequest {
                            id,
                            item: id2.clone(),
                            name: tool,
                            arg,
                            always,
                            preview,
                            reason,
                            subagent: Some(id2.clone()),
                            card,
                        });
                    }
                    Event::PermissionResolved { id, decision } => {
                        let mut s = state.lock().unwrap();
                        s.needs_you = s.needs_you.saturating_sub(1);
                        drop(s);
                        relay.unrelay(&id);
                        relay.emit(Event::PermissionResolved { id, decision });
                        kids.announce(&id2, &relay);
                    }
                    _ => {}
                }
            }
        });
        Ok(id)
    }

    /// Tell the parent's clients how child `id` stands now.
    fn announce(&self, id: &str, relay: &crate::background::Registry) {
        let ev = {
            let kids = self.kids.lock().unwrap();
            let Some(k) = kids.get(id) else { return };
            Event::ChildSession {
                id: id.to_string(),
                name: k.name.clone(),
                state: state_word(k).into(),
                branch: k.branch.clone(),
                cwd: k.cwd.display().to_string(),
            }
        };
        relay.emit(ev);
    }

    /// Children with a turn running or a prompt waiting.
    pub fn busy(&self) -> usize {
        self.kids
            .lock()
            .unwrap()
            .values()
            .filter(|k| !k.archived && state_word(k) != "idle")
            .count()
    }

    /// `ListSessions`, `SendMessage`, `ArchiveSession`, `SessionStatus`, `StopSession`.
    pub fn answer(&self, tool: &str, input: &Value) -> Result<String> {
        use crate::tools::sessions::*;
        match tool {
            LIST => {
                let kids = self.kids.lock().unwrap();
                let rows: Vec<Value> = kids
                    .iter()
                    .filter(|(_, k)| !k.archived)
                    .map(|(id, k)| row(id, k))
                    .collect();
                if rows.is_empty() {
                    return Ok("No sessions started from this one.".into());
                }
                Ok(serde_json::to_string_pretty(&rows)?)
            }
            STATUS => {
                let id = self.find(input["id"].as_str().unwrap_or(""))?;
                let kids = self.kids.lock().unwrap();
                Ok(serde_json::to_string_pretty(&row(&id, &kids[&id]))?)
            }
            SEND => {
                let id = self.find(input["to"].as_str().unwrap_or(""))?;
                let kids = self.kids.lock().unwrap();
                let k = &kids[&id];
                if k.archived {
                    bail!("{} is archived", k.name);
                }
                let message = input["message"].as_str().unwrap_or("").to_string();
                let op = if input["informational"].as_bool() == Some(true) {
                    Op::Inform {
                        from: "parent".into(),
                        from_name: "parent".into(),
                        message,
                    }
                } else {
                    Op::Deliver {
                        from: "parent".into(),
                        from_name: "parent".into(),
                        message,
                    }
                };
                k.ops
                    .send(op)
                    .map_err(|_| anyhow!("{} has exited", k.name))?;
                Ok(format!("Queued for {} ({id}).", k.name))
            }
            STOP => {
                let id = self.find(input["id"].as_str().unwrap_or(""))?;
                let kids = self.kids.lock().unwrap();
                let k = &kids[&id];
                if input["clear_queue"].as_bool() == Some(true) {
                    let _ = k.ops.send(Op::ClearInbox);
                }
                let _ = k.ops.send(Op::Interrupt);
                Ok(format!("Stopped {} ({id}).", k.name))
            }
            ARCHIVE => {
                let id = self.find(input["id"].as_str().unwrap_or(""))?;
                let mut kids = self.kids.lock().unwrap();
                let k = kids.get_mut(&id).expect("found");
                k.archived = true;
                let _ = k.ops.send(Op::ClearInbox);
                let _ = k.ops.send(Op::Interrupt);
                let _ = k.ops.send(Op::Shutdown);
                let text = format!(
                    "Archived {} ({id}). Its log is kept{}.",
                    k.name,
                    k.branch
                        .as_ref()
                        .map(|b| format!(", and its branch {b} and worktree {}", k.cwd.display()))
                        .unwrap_or_default()
                );
                drop(kids);
                if let Some(r) = self.relay.lock().unwrap().clone() {
                    self.announce(&id, &r);
                }
                Ok(text)
            }
            _ => bail!("`{tool}` needs the app"),
        }
    }

    /// Stop every child (the parent's engine is going away).
    pub fn shutdown(&self) {
        for k in self.kids.lock().unwrap().values() {
            let _ = k.ops.send(Op::Interrupt);
            let _ = k.ops.send(Op::Shutdown);
        }
    }
}

fn state_word(k: &Kid) -> &'static str {
    let s = k.state.lock().unwrap();
    if k.archived {
        "archived"
    } else if s.needs_you > 0 {
        "waiting"
    } else if s.running {
        "running"
    } else {
        "idle"
    }
}

fn row(id: &str, k: &Kid) -> Value {
    let state = state_word(k);
    let s = k.state.lock().unwrap();
    json!({
        "id": id,
        "name": k.name,
        "state": state,
        "needs_you": s.needs_you,
        "turns": s.turns,
        "last_turn": s.ended,
        "cwd": k.cwd,
        "branch": k.branch,
    })
}

/// The options a child engine starts with: the parent's config and store, its model unless
/// the call names one, its mode capped at the parent's, read-only children as subagents.
pub fn child_options(
    parent: &Options,
    parent_id: &str,
    cwd: PathBuf,
    read_only: bool,
    mode: crate::protocol::Mode,
) -> Options {
    let mut cfg = parent.cfg.clone();
    cfg.parent_session = Some(parent_id.to_string());
    Options {
        cfg,
        profile_name: parent.profile_name.clone(),
        profile: parent.profile.clone(),
        cwd,
        mode: if read_only {
            crate::protocol::Mode::Default
        } else {
            mode
        },
        can_ask: parent.can_ask && !read_only,
        resume: None,
        store: parent.store.clone(),
        sandbox: parent.sandbox || read_only,
        rich: false,
        subagent: read_only,
        chat: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs_and_worktree_defaults() {
        assert_eq!(slug("Fix the login bug!"), "fix-the-login-bug");
        assert_eq!(slug("  "), "task");
        assert!(wants_worktree(&json!({"title": "t"})));
        assert!(!wants_worktree(&json!({"read_only": true})));
        assert!(!wants_worktree(&json!({"cwd": "/x"})));
        assert!(wants_worktree(&json!({"cwd": "/x", "worktree": true})));
        assert!(!wants_worktree(&json!({"worktree": false})));
    }

    #[test]
    fn self_aliases_name_the_asking_session() {
        // The alias set both resolvers share: `self`, `me`, `this`, in any case.
        use crate::tools::sessions::is_self;
        for alias in ["self", "me", "this", "Self", " ME ", "This"] {
            assert!(is_self(alias), "{alias:?} is the caller");
        }
        for other in ["chief-0001", "sel", "", "myself"] {
            assert!(!is_self(other), "{other:?} is not the caller");
        }
    }

    #[test]
    fn find_prefers_an_exact_id_or_name_over_the_self_alias() {
        let kids = Kids::default();
        let mut map = kids.kids.lock().unwrap();
        map.insert(
            "child-0001".into(),
            Kid {
                name: "self".into(),
                cwd: PathBuf::from("/tmp/x"),
                branch: None,
                ops: mpsc::unbounded_channel().0,
                state: Arc::new(Mutex::new(State::default())),
                archived: false,
            },
        );
        drop(map);
        // A child actually named "self" wins, so nothing that resolved before changed.
        assert_eq!(kids.find("self").unwrap(), "child-0001");
        // The parent asking for itself gets an honest refusal, not "no session".
        let err = kids.find("me").unwrap_err().to_string();
        assert!(err.contains("That's this session"), "{err}");
        // Anything else is still the old miss, listing what there is.
        let err = kids.find("nobody").unwrap_err().to_string();
        assert!(err.contains("Known: self (child-0001)"), "{err}");
    }

    #[test]
    fn note_caps_the_report() {
        let s = State {
            report: "x".repeat(5_000),
            ended: Some("complete".into()),
            ..Default::default()
        };
        let n = note("fixer", &s);
        assert!(n.starts_with("fixer finished a turn."));
        assert!(n.len() < REPORT_CAP + 200);
        let s = State {
            ended: Some("cancelled".into()),
            ..Default::default()
        };
        assert_eq!(note("fixer", &s), "fixer stopped (cancelled).");
    }
}
