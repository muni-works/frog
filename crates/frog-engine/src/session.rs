//! Sessions as append-only event logs.
//!
//! One JSONL file per session. Line 1 is a [`Header`]; every following line is a [`Record`]:
//! - `event`: a durable protocol event (what clients replay), and
//! - `push` / `extend` / `reset`: changes to the model-facing message history, folded back
//!   into `Vec<Message>` on resume.
//!
//! Records are appended as they happen and the file is fsynced at turn boundaries. A torn
//! final line (crash mid-write) is ignored on load. One process writes a session at a time,
//! enforced with `flock`.

use crate::config::data_dir;
use crate::message::{Block, Message};
use crate::protocol::{EndReason, Envelope, Event};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Seek, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

pub const VERSION: u32 = 1;

pub fn default_dir() -> PathBuf {
    data_dir().join("sessions")
}

pub fn new_id() -> String {
    // The counter mixes the pid into the bits the salt keeps, so two processes started in the
    // same second (with the same sub-second clock reading) still mint different ids; the
    // counter then keeps ids unique within a process. A collision is still possible — handled
    // by `Log::create` taking over the file — just vanishingly rare.
    static NEXT: std::sync::OnceLock<std::sync::atomic::AtomicU32> = std::sync::OnceLock::new();
    let next = NEXT.get_or_init(|| {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .subsec_nanos();
        std::sync::atomic::AtomicU32::new(salt_base(nanos, std::process::id()))
    });
    let salt = salt_of(next.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
    format!(
        "{}-{salt:04x}",
        chrono::Local::now().format("%Y%m%d-%H%M%S")
    )
}

/// The counter a process mints salts from: its first salt (the clock's sub-second reading)
/// with the pid folded into the low bits the salt keeps.
fn salt_base(nanos: u32, pid: u32) -> u32 {
    nanos.rotate_left(8) ^ pid
}

/// The salt an already-counted value yields.
fn salt_of(n: u32) -> u32 {
    n & 0xffff
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Header {
    pub version: u32,
    pub id: String,
    pub cwd: PathBuf,
    pub model: String,
    /// Unix milliseconds.
    pub created: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub forked_from: Option<ForkPoint>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct ForkPoint {
    pub session: String,
    pub seq: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[allow(clippy::large_enum_variant)]
pub enum Record {
    Header(Header),
    Event {
        env: Envelope,
    },
    /// Append a message to the history.
    Push {
        message: Message,
    },
    /// Append blocks to the last message.
    Extend {
        blocks: Vec<Block>,
    },
    /// Rewrite one tool result's content (context pruning).
    Replace {
        id: String,
        content: String,
    },
    /// A file's content just before an Edit/Write in `turn` (`None` = it didn't exist).
    /// Rewind restores these.
    Snapshot {
        turn: u64,
        path: PathBuf,
        before: Option<String>,
    },
    /// The whole working tree just before `turn` began (git repos only): a commit pinned under
    /// `refs/frog/`. Preferred over per-file snapshots when rewinding, since it also covers
    /// changes made by shell commands.
    Checkpoint {
        turn: u64,
        root: PathBuf,
        commit: String,
    },
    /// Replace the whole history (compaction).
    Reset {
        messages: Vec<Message>,
    },
    /// The repo map the system prompt carries from here on, so a resumed session sends the
    /// prompt it left off with instead of one rebuilt from the files as they are now.
    RepoMap {
        map: crate::repomap::Map,
    },
    /// MCP tools that were loaded via `McpTools` and should be restored on resume.
    LoadedTools {
        tools: Vec<String>,
    },
}

fn path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("{id}.jsonl"))
}

/// The current turn's streaming events, for followers (not a session log: no `.jsonl`).
pub fn live_path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("{id}.live"))
}

/// Events in `id`'s live file after `after`, in order.
pub fn live_after(dir: &Path, id: &str, after: u64) -> Vec<Envelope> {
    let Ok(text) = std::fs::read_to_string(live_path(dir, id)) else { return vec![] };
    text.lines()
        .filter_map(|l| serde_json::from_str::<Envelope>(l).ok())
        .filter(|e| e.seq > after)
        .collect()
}

/// An open, locked session log.
pub struct Log {
    file: File,
}

impl Log {
    pub fn create(dir: &Path, header: Header) -> Result<Self> {
        std::fs::create_dir_all(dir)?;
        let path = path(dir, &header.id);
        let file = match OpenOptions::new().append(true).create_new(true).open(&path) {
            Ok(f) => f,
            // Two engines minted the same id (the same second and salt) or the previous holder
            // died without cleaning up. Try to take the file over: the flock in `locked`
            // arbitrates — acquiring it means the previous holder is gone and this process may
            // continue the log; failing it means the session genuinely is in use.
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => OpenOptions::new()
                .append(true)
                .open(&path)
                .with_context(|| format!("creating session {}", header.id))?,
            Err(e) => return Err(e).with_context(|| format!("creating session {}", header.id)),
        };
        let mut log = Self::locked(file, &header.id)?;
        // A taken-over log already has its header; a fresh one — including a truncated file
        // left by a crash before the header landed — starts with it. An offset of 0 on a
        // non-empty file would mean someone truncated it under us; appending nevertheless
        // keeps `fold` happy (its first record must be the header, and it has one).
        if log.file.seek(std::io::SeekFrom::End(0))? == 0 {
            log.append(&Record::Header(header))?;
        }
        Ok(log)
    }

    /// Whether another frog process has this session open.
    pub fn in_use(dir: &Path, id: &str) -> bool {
        let Ok(file) = OpenOptions::new().append(true).open(path(dir, id)) else {
            return false;
        };
        // SAFETY: flock on a valid fd we own; the probe lock is released when `file` drops.
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) != 0 }
    }

    /// Wait up to `timeout` for whoever holds this session to let it go. flock is released
    /// when its holder dies, so a lock still held at the deadline belongs to a live process
    /// (an engine from before a fast relaunch that hasn't exited yet, say). True when free.
    pub fn wait_free(dir: &Path, id: &str, timeout: std::time::Duration) -> bool {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            if !Self::in_use(dir, id) {
                return true;
            }
            if std::time::Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }

    pub fn open(dir: &Path, id: &str) -> Result<Self> {
        let file = OpenOptions::new()
            .append(true)
            .open(path(dir, id))
            .with_context(|| format!("no session {id}"))?;
        Self::locked(file, id)
    }

    fn locked(file: File, id: &str) -> Result<Self> {
        // A lock just released can linger for a moment: a process forked while it was held
        // shares it until it execs. Wait that out before calling the session taken.
        for _ in 0..20 {
            // SAFETY: flock on a valid fd we own; released when the file closes.
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                return Ok(Self { file });
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        bail!("session {id} is open in another frog process")
    }

    pub fn append(&mut self, rec: &Record) -> Result<()> {
        let mut line = serde_json::to_vec(rec)?;
        line.push(b'\n');
        // One write per record keeps lines whole unless the process dies mid-write.
        self.file.write_all(&line)?;
        Ok(())
    }

    /// Replace the header (the file's first line), e.g. when the session moves to another
    /// folder. The file is rewritten beside the old one and renamed over it, then reopened and
    /// locked again; the old handle's lock goes with it.
    pub fn rewrite_header(&mut self, dir: &Path, header: &Header) -> Result<()> {
        let target = path(dir, &header.id);
        let text = std::fs::read_to_string(&target)?;
        let rest = text.split_once('\n').map(|(_, rest)| rest).unwrap_or("");
        let mut line = serde_json::to_string(&Record::Header(header.clone()))?;
        line.push('\n');
        let tmp = target.with_extension("jsonl.tmp");
        std::fs::write(&tmp, line + rest)?;
        std::fs::rename(&tmp, &target)?;
        let file = OpenOptions::new().append(true).open(&target)?;
        *self = Self::locked(file, &header.id)?;
        Ok(())
    }

    pub fn sync(&self) -> Result<()> {
        self.file.sync_data()?;
        Ok(())
    }
}

/// Everything recovered from a session file.
pub struct Loaded {
    pub header: Header,
    pub messages: Vec<Message>,
    pub events: Vec<Envelope>,
    /// File snapshots in the order they were taken.
    pub snapshots: Vec<(u64, PathBuf, Option<String>)>,
    /// Working-tree checkpoints: (turn, repo root, commit).
    pub checkpoints: Vec<(u64, PathBuf, String)>,
    /// The repo map last sent, if one was logged.
    pub repo_map: Option<crate::repomap::Map>,
    /// MCP tools that were loaded via `McpTools` and should be restored on resume.
    pub loaded: Vec<String>,
}

impl Loaded {
    pub fn last_seq(&self) -> u64 {
        self.events.last().map(|e| e.seq).unwrap_or(0)
    }

    pub fn last_turn(&self) -> u64 {
        self.events
            .iter()
            .filter_map(|e| match e.event {
                Event::TurnStarted { turn, .. } => Some(turn),
                _ => None,
            })
            .max()
            .unwrap_or(0)
    }
}

fn read_records(dir: &Path, id: &str) -> Result<Vec<Record>> {
    let file = File::open(path(dir, id)).with_context(|| format!("no session {id}"))?;
    let mut lines = BufReader::new(file).lines().peekable();
    let mut out = Vec::new();
    while let Some(line) = lines.next() {
        let line = line?;
        match serde_json::from_str::<Record>(&line) {
            Ok(r) => out.push(r),
            // A torn last line from a crash; everything before it is intact.
            Err(_) if lines.peek().is_none() => break,
            Err(e) => bail!("session {id} is corrupt: {e}"),
        }
    }
    Ok(out)
}

/// Fold a record stream into a session.
fn fold(id: &str, records: impl IntoIterator<Item = Record>) -> Result<Loaded> {
    let mut records = records.into_iter();
    let Some(Record::Header(header)) = records.next() else {
        bail!("session {id} has no header");
    };
    if header.version > VERSION {
        bail!(
            "session {id} was written by a newer frog (format v{})",
            header.version
        );
    }
    let mut messages: Vec<Message> = Vec::new();
    let mut events = Vec::new();
    let mut snapshots = Vec::new();
    let mut checkpoints = Vec::new();
    let mut repo_map = None;
    let mut loaded: Vec<String> = Vec::new();
    for r in records {
        match r {
            Record::Header(_) => bail!("session {id} has a second header"),
            Record::Event { env } => events.push(env),
            Record::Push { message } => messages.push(message),
            Record::Extend { blocks } => match messages.last_mut() {
                Some(m) => m.content.extend(blocks),
                None => bail!("session {id}: extend with no message"),
            },
            Record::Replace { id, content } => crate::context::apply(&mut messages, &id, &content),
            Record::Snapshot { turn, path, before } => snapshots.push((turn, path, before)),
            Record::Checkpoint { turn, root, commit } => checkpoints.push((turn, root, commit)),
            Record::Reset { messages: m } => messages = m,
            Record::RepoMap { map } => repo_map = Some(map),
            Record::LoadedTools { tools } => loaded = tools,
        }
    }
    Ok(Loaded {
        header,
        messages,
        events,
        snapshots,
        checkpoints,
        repo_map,
        loaded,
    })
}

pub fn load(dir: &Path, id: &str) -> Result<Loaded> {
    fold(id, read_records(dir, id)?)
}

/// The log's header (line 1): the session's folder and model, for anything that needs to
/// describe a session without opening it.
pub fn header(dir: &Path, id: &str) -> Result<Header> {
    let file = File::open(path(dir, id)).with_context(|| format!("no session {id}"))?;
    let mut lines = BufReader::new(file).lines();
    match lines.next() {
        Some(Ok(line)) => match serde_json::from_str::<Record>(&line) {
            Ok(Record::Header(h)) => Ok(h),
            _ => bail!("session {id} has no header"),
        },
        // An empty or unreadable first line is as good as none.
        _ => bail!("session {id} has no header"),
    }
}

/// Durable events with `seq > after`, read without parsing the rest of the log: a long
/// session's log is mostly the model's messages (screenshots in tool results among them), and
/// a client replaying its transcript needs none of them. Records lead with their tag, so a line
/// that isn't an event is skipped unparsed, and an event's seq is its first field, so with
/// `after` set the ones already seen are too. A torn last line is ignored, as on load.
pub fn events_after(dir: &Path, id: &str, after: u64) -> Result<Vec<Envelope>> {
    const RECORD: &[u8] = br#"{"type":""#;
    const EVENT: &[u8] = br#"{"type":"event""#;
    const SEQ: &[u8] = br#"{"type":"event","env":{"seq":"#;
    let file = File::open(path(dir, id)).with_context(|| format!("no session {id}"))?;
    let mut lines = BufReader::new(file).split(b'\n').peekable();
    let mut out = Vec::new();
    while let Some(line) = lines.next() {
        let line = line?;
        if line.starts_with(RECORD) && !line.starts_with(EVENT) {
            continue;
        }
        if after > 0 && line.starts_with(SEQ) {
            let digits = &line[SEQ.len()..];
            let n = digits.iter().take_while(|b| b.is_ascii_digit()).count();
            let seq = std::str::from_utf8(&digits[..n]).ok().and_then(|d| d.parse::<u64>().ok());
            if seq.is_some_and(|seq| seq <= after) {
                continue;
            }
        }
        match serde_json::from_slice::<Record>(&line) {
            Ok(Record::Event { env }) if env.seq > after => out.push(env),
            Ok(_) => {}
            Err(_) if lines.peek().is_none() => break,
            Err(e) => bail!("session {id} is corrupt: {e}"),
        }
    }
    Ok(out)
}

/// How a session's last turn ended, for listings: is it still going, and if not, how did it
/// stop? Derived from the last `TurnStarted`/`TurnEnded` pair; `None` means the session never
/// finished a turn (idle, or one that only ever crashed).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EndState {
    /// The last turn is still open (or ended mid-run: torn tail, crash) — live readers should
    /// consult the `.live` file for what's happening now.
    Open,
    /// The model finished its answer.
    Complete,
    /// It ended cleanly but wants the user: `Denied`, `MaxTokens`, `StepLimit` or `Looping`.
    Stopped,
    /// It ended with an error (provider, connection, internal).
    Failed,
}

impl EndState {
    /// `None` for `Cancelled` and sessions that never ran a turn: nothing worth a glyph.
    fn new(reason: &EndReason) -> Option<Self> {
        Some(match reason {
            EndReason::Complete => Self::Complete,
            EndReason::Error { .. } => Self::Failed,
            EndReason::Denied
            | EndReason::BlockedOnApproval { .. }
            | EndReason::MaxTokens
            | EndReason::StepLimit
            | EndReason::Looping => {
                Self::Stopped
            }
            // Suspended for an app update: the session carries on at restart, so it isn't
            // "stopped" — but it isn't complete either; no glyph until it resumes.
            EndReason::Suspended => return None,
            EndReason::Cancelled => return None,
        })
    }
}

/// Summary for listings.
pub struct Info {
    pub id: String,
    /// Last conversation activity (a turn starting or ending), or when the session was created.
    pub modified: std::time::SystemTime,
    pub header: Header,
    pub first_input: Option<String>,
    pub title: Option<String>,
    /// The last turn's end, once one has finished (see `EndState`).
    pub end: Option<EndState>,
}

/// Sessions started in `cwd` (every folder's, with `None`), most recently active first.
pub fn list(dir: &Path, cwd: Option<&Path>) -> Result<Vec<Info>> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Ok(Vec::new());
    };
    let mut out = Vec::new();
    for e in entries.filter_map(|e| e.ok()) {
        let p = e.path();
        if p.extension().is_none_or(|x| x != "jsonl") {
            continue;
        }
        let Some(id) = p.file_stem().and_then(|s| s.to_str()) else {
            continue;
        };
        let Ok(file) = File::open(&p) else { continue };
        let mut lines = BufReader::new(file).lines().map_while(|l| l.ok());
        let Some(Ok(Record::Header(header))) = lines.next().map(|l| serde_json::from_str(&l))
        else {
            continue;
        };
        if cwd.is_some_and(|c| header.cwd != c) {
            continue;
        }
        let (mut first_input, mut title) = (None, None);
        // The end of the newest turn that closed, and whether a later one is still open.
        let mut end: Option<EndState> = None;
        let mut open = false;
        // Last conversation activity: when a turn last started or ended. Not the file's mtime,
        // since merely resuming a session appends bookkeeping records, which would reorder the
        // list every time you open one.
        let mut active = header.created;
        for l in lines {
            match serde_json::from_str(&l) {
                Ok(Record::Event {
                    env:
                        Envelope {
                            event: Event::TurnStarted { input, .. },
                            created,
                            ..
                        },
                }) => {
                    active = active.max(created);
                    open = true;
                    if first_input.is_none() {
                        first_input = Some(input);
                    }
                }
                Ok(Record::Event {
                    env:
                        Envelope {
                            event: Event::TurnEnded { reason, .. },
                            created,
                            ..
                        },
                }) => {
                    active = active.max(created);
                    open = false;
                    end = EndState::new(&reason);
                }
                Ok(Record::Event {
                    env:
                        Envelope {
                            event: Event::Titled { title: t },
                            ..
                        },
                }) => title = Some(t),
                _ => {}
            }
        }
        let modified =
            std::time::UNIX_EPOCH + std::time::Duration::from_millis(active.max(0) as u64);
        out.push(Info {
            id: id.to_string(),
            modified,
            header,
            first_input,
            title,
            // A turn still open with nobody holding the log died mid-run (the engine is
            // gone): that's a failure, not work in progress. A newer open turn wins over an
            // older turn's end.
            end: if open {
                Some(if Log::in_use(dir, id) { EndState::Open } else { EndState::Failed })
            } else {
                end
            },
        });
    }
    out.sort_by_key(|i| std::cmp::Reverse(i.modified));
    Ok(out)
}

/// Name a session that isn't open (an open one takes `Op::SetTitle`).
pub fn retitle(dir: &Path, id: &str, title: &str) -> Result<()> {
    let title: String = title.trim().chars().take(80).collect();
    if title.is_empty() {
        anyhow::bail!("the title is empty");
    }
    let seq = load(dir, id)?.last_seq() + 1;
    let mut log = Log::open(dir, id)?;
    log.append(&Record::Event {
        env: Envelope {
            seq,
            session: id.to_string(),
            created: chrono::Utc::now().timestamp_millis(),
            event: Event::Titled { title },
        },
    })
}

/// The seq of the `TurnEnded` for `turn`, for forking "after turn N".
pub fn turn_end_seq(dir: &Path, id: &str, turn: u64) -> Result<u64> {
    load(dir, id)?
        .events
        .iter()
        .find_map(|e| match e.event {
            Event::TurnEnded { turn: t, .. } if t == turn => Some(e.seq),
            _ => None,
        })
        .with_context(|| format!("session {id} has no completed turn {turn}"))
}

/// What a rewind did.
#[derive(Debug, Serialize)]
pub struct Rewound {
    /// The new session, holding the conversation up to just before the turn.
    pub session: String,
    /// Files put back to how they were before the turn.
    pub restored: Vec<PathBuf>,
}

/// Undo turn `turn` and everything after it: restore files frog edited in those turns (newest
/// first), then fork the conversation at the point just before the turn. The original session
/// is left intact, so a rewind can itself be undone by resuming it.
///
/// In a git repo, the working tree goes back to the checkpoint taken when the turn started
/// (covering shell commands too). Elsewhere, only Edit/Write snapshots are restored.
pub fn rewind(dir: &Path, id: &str, turn: u64) -> Result<Rewound> {
    let loaded = load(dir, id)?;
    let start = loaded
        .events
        .iter()
        .find_map(|e| match e.event {
            Event::TurnStarted { turn: t, .. } if t == turn => Some(e.seq),
            _ => None,
        })
        .with_context(|| format!("session {id} has no turn {turn}"))?;
    let mut restored = Vec::new();
    // A whole-tree checkpoint from the start of the turn also covers shell commands.
    if let Some((_, root, commit)) = loaded.checkpoints.iter().find(|(t, _, _)| *t == turn) {
        let paths = crate::checkpoint::restore(root, commit)?;
        let restored = paths.into_iter().map(|p| root.join(p)).collect();
        let session = fork(dir, id, Some(start.saturating_sub(1)))?;
        return Ok(Rewound { session, restored });
    }
    for (t, path, before) in loaded.snapshots.iter().rev() {
        if *t < turn {
            continue;
        }
        match before {
            Some(content) => std::fs::write(path, content)?,
            None => {
                let _ = std::fs::remove_file(path);
            }
        }
        if !restored.contains(path) {
            restored.push(path.clone());
        }
    }
    let session = fork(dir, id, Some(start.saturating_sub(1)))?;
    Ok(Rewound { session, restored })
}

pub fn latest_for(dir: &Path, cwd: &Path) -> Result<String> {
    list(dir, Some(cwd))?
        .into_iter()
        .next()
        .map(|i| i.id)
        .with_context(|| format!("no previous session in {}", cwd.display()))
}

/// Copy a session up to and including event `upto` (default: all of it) into a new session.
/// History records are kept in file order, so the copy's history matches the source at that point.
pub fn fork(dir: &Path, id: &str, upto: Option<u64>) -> Result<String> {
    let records = read_records(dir, id)?;
    let Some(Record::Header(src)) = records.first() else {
        bail!("session {id} has no header")
    };
    let max_seq = records
        .iter()
        .filter_map(|r| match r {
            Record::Event { env } => Some(env.seq),
            _ => None,
        })
        .max()
        .unwrap_or(0);
    let upto = upto.unwrap_or(max_seq);
    if upto > max_seq {
        bail!("session {id} has no event {upto} (last is {max_seq})");
    }
    let kept: Vec<Record> = records
        .iter()
        .skip(1)
        .take_while(|r| !matches!(r, Record::Event { env } if env.seq > upto))
        .cloned()
        .collect();
    let last_seq = upto;
    let new = new_id();
    let header = Header {
        version: VERSION,
        id: new.clone(),
        cwd: src.cwd.clone(),
        model: src.model.clone(),
        created: chrono::Utc::now().timestamp_millis(),
        forked_from: Some(ForkPoint {
            session: id.to_string(),
            seq: last_seq,
        }),
    };
    let mut log = Log::create(dir, header)?;
    for r in kept {
        // Re-home events under the new session id; seqs are preserved.
        let r = match r {
            Record::Event { mut env } => {
                env.session = new.clone();
                Record::Event { env }
            }
            r => r,
        };
        log.append(&r)?;
    }
    log.sync()?;
    Ok(new)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::Role;

    pub fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!("frog-test-{}", new_id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn header(id: &str) -> Header {
        Header {
            version: VERSION,
            id: id.into(),
            cwd: "/x".into(),
            model: "m".into(),
            created: 0,
            forked_from: None,
        }
    }

    fn ev(seq: u64, event: Event) -> Record {
        Record::Event {
            env: Envelope {
                seq,
                session: "a".into(),
                created: 0,
                event,
            },
        }
    }

    #[test]
    fn folds_history_and_tolerates_torn_tail() {
        let dir = tmp();
        let mut log = Log::create(&dir, header("a")).unwrap();
        log.append(&ev(
            1,
            Event::TurnStarted {
                turn: 1,
                input: "hi".into(),
                images: Vec::new(),
                more: Vec::new(),
            },
        ))
        .unwrap();
        log.append(&Record::Push {
            message: Message::user("hi"),
        })
        .unwrap();
        log.append(&Record::Extend {
            blocks: vec![Block::Text {
                text: "more".into(),
            }],
        })
        .unwrap();
        log.append(&Record::Push {
            message: Message {
                role: Role::Assistant,
                content: vec![],
            },
        })
        .unwrap();
        drop(log);
        // Simulate a crash mid-write.
        let mut f = OpenOptions::new()
            .append(true)
            .open(path(&dir, "a"))
            .unwrap();
        f.write_all(b"{\"type\":\"push\",\"mess").unwrap();

        let l = load(&dir, "a").unwrap();
        assert_eq!(l.messages.len(), 2);
        assert_eq!(l.messages[0].content.len(), 2);
        assert_eq!(l.last_seq(), 1);
        assert_eq!(l.last_turn(), 1);
    }

    #[test]
    fn events_after_reads_appended_cli_events_incrementally() {
        let dir = tmp();
        let mut log = Log::create(&dir, header("a")).unwrap();
        log.append(&ev(
            1,
            Event::TurnStarted {
                turn: 1,
                input: "hi".into(),
                images: Vec::new(),
                more: Vec::new(),
            },
        ))
        .unwrap();
        log.sync().unwrap();
        let first = events_after(&dir, "a", 0).unwrap();
        assert_eq!(first.len(), 1);
        assert_eq!(events_after(&dir, "a", first[0].seq).unwrap().len(), 0);
        log.append(&ev(
            2,
            Event::TurnEnded {
                turn: 1,
                reason: crate::protocol::EndReason::Complete,
                usage: crate::protocol::TurnUsage::default(),
            },
        ))
        .unwrap();
        log.sync().unwrap();
        let appended = events_after(&dir, "a", first[0].seq).unwrap();
        assert_eq!(appended.len(), 1);
        assert_eq!(appended[0].seq, 2);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn events_after_skips_messages_and_seen_events_unparsed() {
        let dir = tmp();
        let mut log = Log::create(&dir, header("a")).unwrap();
        for seq in 1..=3 {
            log.append(&ev(seq, Event::Titled { title: format!("t{seq}") })).unwrap();
            log.append(&Record::Push { message: Message::user("hi") }).unwrap();
        }
        log.sync().unwrap();
        drop(log);
        // A message line that wouldn't parse is never read; a torn event at the end is dropped.
        let mut f = OpenOptions::new().append(true).open(path(&dir, "a")).unwrap();
        writeln!(f, r#"{{"type":"push","message":{{not json"#).unwrap();
        write!(f, r#"{{"type":"event","env":{{"seq":4,"#).unwrap();
        drop(f);
        let all = events_after(&dir, "a", 0).unwrap();
        assert_eq!(all.iter().map(|e| e.seq).collect::<Vec<_>>(), vec![1, 2, 3]);
        let newer = events_after(&dir, "a", 2).unwrap();
        assert_eq!(newer.iter().map(|e| e.seq).collect::<Vec<_>>(), vec![3]);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn list_reports_the_last_turns_end() {
        let dir = tmp();
        let mut log = Log::create(&dir, header("a")).unwrap();
        log.append(&Record::Push {
            message: Message::user("hi"),
        })
        .unwrap();
        // An open turn: started, never ended.
        log.append(&ev(
            1,
            Event::TurnStarted {
                turn: 1,
                input: "hi".into(),
                images: Vec::new(),
                more: Vec::new(),
            },
        ))
        .unwrap();
        // Open while an engine holds the log...
        let listed = list(&dir, None).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].end, Some(EndState::Open));
        assert_eq!(listed[0].id, "a");
        // ...and dead once nobody does: the engine died mid-turn.
        drop(log);
        assert_eq!(list(&dir, None).unwrap()[0].end, Some(EndState::Failed));

        // A turn that finished completes it; a later open turn reopens it.
        let mut log = Log::open(&dir, "a").unwrap();
        log.append(&ev(
            2,
            Event::TurnEnded {
                turn: 1,
                reason: crate::protocol::EndReason::Complete,
                usage: crate::protocol::TurnUsage::default(),
            },
        ))
        .unwrap();
        drop(log);
        assert_eq!(list(&dir, None).unwrap()[0].end, Some(EndState::Complete));

        for reason in [
            crate::protocol::EndReason::Denied,
            crate::protocol::EndReason::MaxTokens,
            crate::protocol::EndReason::StepLimit,
            crate::protocol::EndReason::Looping,
        ] {
            let mut log = Log::open(&dir, "a").unwrap();
            log.append(&ev(
                3,
                Event::TurnEnded {
                    turn: 1,
                    reason,
                    usage: crate::protocol::TurnUsage::default(),
                },
            ))
            .unwrap();
            drop(log);
            assert_eq!(list(&dir, None).unwrap()[0].end, Some(EndState::Stopped));
        }

        let mut log = Log::open(&dir, "a").unwrap();
        log.append(&ev(
            4,
            Event::TurnEnded {
                turn: 1,
                reason: crate::protocol::EndReason::Cancelled,
                usage: crate::protocol::TurnUsage::default(),
            },
        ))
        .unwrap();
        drop(log);
        assert_eq!(list(&dir, None).unwrap()[0].end, None);

        // A session that never ran a turn has no end state.
        let _log = Log::create(&dir, header("quiet")).unwrap();
        assert_eq!(
            list(&dir, None).unwrap().iter().find(|i| i.id == "quiet").unwrap().end,
            None
        );
    }

    #[test]
    fn second_writer_is_refused() {
        let dir = tmp();
        let _log = Log::create(&dir, header("a")).unwrap();
        assert!(Log::open(&dir, "a").is_err());
    }

    #[test]
    fn wait_free_waits_for_the_holder_to_let_go() {
        let dir = tmp();
        let log = Log::create(&dir, header("w")).unwrap();
        let short = std::time::Duration::from_millis(100);
        assert!(!Log::wait_free(&dir, "w", short), "a held lock is not free");
        let release = std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(200));
            drop(log);
        });
        let t = std::time::Instant::now();
        assert!(Log::wait_free(&dir, "w", std::time::Duration::from_secs(5)));
        assert!(t.elapsed() >= std::time::Duration::from_millis(150));
        release.join().unwrap();
        assert!(Log::open(&dir, "w").is_ok());
    }

    #[test]
    fn creates_with_the_same_id_take_over_a_released_log() {
        let dir = tmp();
        // Two engines minted the same id: the second `create` finds the file there, but the
        // first holder is gone, so the flock lets it continue the log — no second header.
        let mut first = Log::create(&dir, header("a")).unwrap();
        first.append(&ev(1, Event::Titled { title: "one".into() })).unwrap();
        first.sync().unwrap();
        drop(first);
        let mut second = Log::create(&dir, header("a")).unwrap();
        second.append(&ev(2, Event::Titled { title: "two".into() })).unwrap();
        second.sync().unwrap();
        drop(second);
        let l = load(&dir, "a").unwrap();
        assert_eq!(
            l.events.iter().map(|e| e.seq).collect::<Vec<_>>(),
            vec![1, 2]
        );

        // But a live holder means the session genuinely is in use: one clean error, no
        // take-over, and the file is left as the holder had it.
        let held = Log::open(&dir, "a").unwrap();
        let err = match Log::create(&dir, header("a")) {
            Err(e) => e,
            Ok(_) => panic!("a held log was taken over"),
        };
        assert!(err.to_string().contains("open in another frog process"), "{err:#}");
        drop(held);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn an_empty_file_left_behind_gets_a_header_on_create() {
        let dir = tmp();
        // A crash between creating the file and writing the header: the takeover appends one.
        std::fs::write(path(&dir, "a"), "").unwrap();
        let mut log = Log::create(&dir, header("a")).unwrap();
        log.append(&ev(1, Event::Titled { title: "one".into() })).unwrap();
        drop(log);
        let l = load(&dir, "a").unwrap();
        assert_eq!(l.events.len(), 1);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn ids_mix_the_pid_into_the_salt_and_stay_well_formed() {
        let before = [
            salt_of(salt_base(1, 100)),
            salt_of(salt_base(1, 101)),
            salt_of(salt_base(1, 100 << 16 | 100)),
        ];
        // The pid must reach the bits the salt keeps: different pids, same clock, different
        // salts — in either half of the counter.
        assert_ne!(before[0], before[1]);
        assert_ne!(before[0], before[2]);
        // And the id keeps its shape: YYYYMMDD-HHMMSS-xxxx.
        let (a, b) = (new_id(), new_id());
        assert_ne!(a, b);
        let salt = a.rsplit('-').next().unwrap();
        assert_eq!(salt.len(), 4);
        assert!(salt.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(a.len(), b.len());
        let dashes = a.matches('-').count();
        assert_eq!(dashes, 2, "{a}");
    }

    #[test]
    fn fork_cuts_at_seq_and_rehomes_events() {
        let dir = tmp();
        let mut log = Log::create(&dir, header("a")).unwrap();
        log.append(&ev(
            1,
            Event::TurnStarted {
                turn: 1,
                input: "one".into(),
                images: Vec::new(),
                more: Vec::new(),
            },
        ))
        .unwrap();
        log.append(&Record::Push {
            message: Message::user("one"),
        })
        .unwrap();
        log.append(&ev(
            2,
            Event::TurnStarted {
                turn: 2,
                input: "two".into(),
                images: Vec::new(),
                more: Vec::new(),
            },
        ))
        .unwrap();
        log.append(&Record::Push {
            message: Message::user("two"),
        })
        .unwrap();
        drop(log);

        let b = fork(&dir, "a", Some(1)).unwrap();
        let l = load(&dir, &b).unwrap();
        assert_eq!(
            l.header.forked_from,
            Some(ForkPoint {
                session: "a".into(),
                seq: 1
            })
        );
        assert_eq!(l.messages.len(), 1);
        assert_eq!(l.events.len(), 1);
        assert_eq!(l.events[0].session, b);
        assert!(fork(&dir, "a", Some(9)).is_err());
    }
}
