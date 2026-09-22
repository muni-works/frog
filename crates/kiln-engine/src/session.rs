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
use crate::protocol::{Envelope, Event};
use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

pub const VERSION: u32 = 1;

pub fn default_dir() -> PathBuf {
    data_dir().join("sessions")
}

pub fn new_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    let salt = (nanos ^ std::process::id().rotate_left(16)) & 0xffff;
    format!(
        "{}-{salt:04x}",
        chrono::Local::now().format("%Y%m%d-%H%M%S")
    )
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
    /// Replace the whole history (compaction).
    Reset {
        messages: Vec<Message>,
    },
}

fn path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("{id}.jsonl"))
}

/// An open, locked session log.
pub struct Log {
    file: File,
}

impl Log {
    pub fn create(dir: &Path, header: Header) -> Result<Self> {
        std::fs::create_dir_all(dir)?;
        let file = OpenOptions::new()
            .append(true)
            .create_new(true)
            .open(path(dir, &header.id))
            .with_context(|| format!("creating session {}", header.id))?;
        let mut log = Self::locked(file, &header.id)?;
        log.append(&Record::Header(header))?;
        Ok(log)
    }

    pub fn open(dir: &Path, id: &str) -> Result<Self> {
        let file = OpenOptions::new()
            .append(true)
            .open(path(dir, id))
            .with_context(|| format!("no session {id}"))?;
        Self::locked(file, id)
    }

    fn locked(file: File, id: &str) -> Result<Self> {
        // SAFETY: flock on a valid fd we own; released when the file closes.
        let r = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if r != 0 {
            bail!("session {id} is open in another kiln process");
        }
        Ok(Self { file })
    }

    pub fn append(&mut self, rec: &Record) -> Result<()> {
        let mut line = serde_json::to_vec(rec)?;
        line.push(b'\n');
        // One write per record keeps lines whole unless the process dies mid-write.
        self.file.write_all(&line)?;
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
            "session {id} was written by a newer kiln (format v{})",
            header.version
        );
    }
    let mut messages: Vec<Message> = Vec::new();
    let mut events = Vec::new();
    for r in records {
        match r {
            Record::Header(_) => bail!("session {id} has a second header"),
            Record::Event { env } => events.push(env),
            Record::Push { message } => messages.push(message),
            Record::Extend { blocks } => match messages.last_mut() {
                Some(m) => m.content.extend(blocks),
                None => bail!("session {id}: extend with no message"),
            },
            Record::Reset { messages: m } => messages = m,
        }
    }
    Ok(Loaded {
        header,
        messages,
        events,
    })
}

pub fn load(dir: &Path, id: &str) -> Result<Loaded> {
    fold(id, read_records(dir, id)?)
}

/// Durable events with `seq > after`.
pub fn events_after(dir: &Path, id: &str, after: u64) -> Result<Vec<Envelope>> {
    Ok(read_records(dir, id)?
        .into_iter()
        .filter_map(|r| match r {
            Record::Event { env } if env.seq > after => Some(env),
            _ => None,
        })
        .collect())
}

/// Summary for listings.
pub struct Info {
    pub id: String,
    pub modified: std::time::SystemTime,
    pub header: Header,
    pub first_input: Option<String>,
}

/// Sessions started in `cwd`, newest first.
pub fn list(dir: &Path, cwd: &Path) -> Result<Vec<Info>> {
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
        if header.cwd != cwd {
            continue;
        }
        let first_input = lines.find_map(|l| match serde_json::from_str(&l) {
            Ok(Record::Event {
                env:
                    Envelope {
                        event: Event::TurnStarted { input, .. },
                        ..
                    },
            }) => Some(input),
            _ => None,
        });
        let modified = e.metadata()?.modified()?;
        out.push(Info {
            id: id.to_string(),
            modified,
            header,
            first_input,
        });
    }
    out.sort_by_key(|i| std::cmp::Reverse(i.modified));
    Ok(out)
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

pub fn latest_for(dir: &Path, cwd: &Path) -> Result<String> {
    list(dir, cwd)?
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
        let d = std::env::temp_dir().join(format!("kiln-test-{}", new_id()));
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
    fn second_writer_is_refused() {
        let dir = tmp();
        let _log = Log::create(&dir, header("a")).unwrap();
        assert!(Log::open(&dir, "a").is_err());
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
