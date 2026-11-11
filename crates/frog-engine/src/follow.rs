//! Follow a session another frog process is running: replay its log, then stream what it
//! appends, live, without taking it over. A client that opens a session a worker holds (the
//! app clicking a running `frog -p` session) sees the work happen instead of a blank one.
//!
//! Input can't reach the session while the other process holds it: a `Submit` gets a notice.
//! When that process lets go, a notice says so; reopening then resumes it normally.

use std::path::PathBuf;
use std::time::Duration;

use tokio::sync::mpsc;

use crate::config::ToolMode;
use crate::engine::Handle;
use crate::harness::Tier;
use crate::protocol::{Envelope, Event, Level, Mode, Op, Status};
use crate::session;

/// How often to look for new records in the log.
const POLL: Duration = Duration::from_millis(300);

/// Whether an event opens (true) or closes (false) a turn.
fn turn_state(e: &Event) -> Option<bool> {
    match e {
        Event::TurnStarted { .. } => Some(true),
        Event::TurnEnded { .. } => Some(false),
        _ => None,
    }
}

/// What the session is running with, tracked as the log replays so a follower can say it
/// like a live engine does: the model (set at the header, changed by `set_model` along the
/// way) and the permission mode.
struct Running {
    model: String,
    mode: Mode,
    cwd: PathBuf,
}

impl Default for Running {
    fn default() -> Self {
        Self { model: String::new(), mode: Mode::Default, cwd: PathBuf::new() }
    }
}

impl Running {
    fn apply(&mut self, e: &Event) {
        match e {
            Event::ModelChanged { model } => self.model = model.clone(),
            Event::ModeChanged { mode } => self.mode = *mode,
            Event::FolderChanged { cwd } => self.cwd = cwd.clone(),
            _ => {}
        }
    }

    fn status(&self) -> Status {
        Status {
            model: self.model.clone(),
            mode: self.mode,
            cwd: self.cwd.clone(),
            messages: 0,
            context_tokens: None,
            context_window: 0,
            tool_mode: ToolMode::default(),
            tier: Tier::Strong,
            tokens_per_sec: None,
            todos: Vec::new(),
            vision: false,
            degraded: Vec::new(),
            ran_on: None,
        }
    }
}

pub fn follow(store: PathBuf, id: String) -> Handle {
    let (op_tx, mut op_rx) = mpsc::unbounded_channel::<Op>();
    let (ev_tx, ev_rx) = mpsc::unbounded_channel::<Envelope>();
    tokio::spawn(async move {
        let mut last = 0u64;
        let mut subscribed = false;
        let mut released = false;
        let mut running = session::header(&store, &id).map(|h| Running {
            model: h.model,
            mode: Mode::Default,
            cwd: h.cwd,
        }).unwrap_or_default();
        let notice = |seq: u64, level: Level, message: &str| Envelope {
            seq,
            session: id.clone(),
            created: crate::engine::now_ms(),
            event: Event::Notice { level, message: message.into() },
        };
        let mut tick = tokio::time::interval(POLL);
        loop {
            tokio::select! {
                op = op_rx.recv() => match op {
                    None => break,
                    Some(Op::Subscribe { after }) => {
                        // A turn the history ends in the middle of: the worker is running it
                        // now, so the follower shows it as working (like a live session).
                        // Judged from the whole log: a client that already has the history
                        // up to `after` (it read the log itself) asks only for what's newer,
                        // and the open turn or the model may be older than that.
                        let mut open = false;
                        for env in session::events_after(&store, &id, 0).unwrap_or_default() {
                            last = last.max(env.seq);
                            open = turn_state(&env.event).unwrap_or(open);
                            running.apply(&env.event);
                            if env.seq <= after { continue; }
                            if ev_tx.send(env).is_err() { return; }
                        }
                        // Name the session like a starting engine would: a follower that
                        // replays a running turn looks busy, so the composer names the worker's
                        // model, not the app's default.
                        let _ = ev_tx.send(Envelope {
                            seq: last,
                            session: id.clone(),
                            created: crate::engine::now_ms(),
                            event: Event::Status(running.status()),
                        });
                        let _ = ev_tx.send(Envelope {
                            seq: last,
                            session: id.clone(),
                            created: crate::engine::now_ms(),
                            event: Event::Synced { upto: last },
                        });
                        // Nothing is running: settle like an engine that finished starting up.
                        if !open {
                            let _ = ev_tx.send(Envelope {
                                seq: last,
                                session: id.clone(),
                                created: crate::engine::now_ms(),
                                event: Event::Idle,
                            });
                        }
                        subscribed = true;
                    }
                    Some(Op::Submit { .. } | Op::Shell { .. }) => {
                        let msg = if released {
                            "the worker has finished; reopen this conversation to continue it"
                        } else {
                            "this session is running in another frog process; messages can't reach it until it finishes"
                        };
                        let _ = ev_tx.send(notice(last, Level::Warn, msg));
                    }
                    Some(_) => {}
                },
                _ = tick.tick(), if subscribed && !released => {
                    // Finished steps from the log, and what's streaming now from the live file.
                    let mut new = session::events_after(&store, &id, last).unwrap_or_default();
                    new.extend(session::live_after(&store, &id, last));
                    new.sort_by_key(|e| e.seq);
                    new.dedup_by_key(|e| e.seq);
                    let mut closed = false;
                    for env in new {
                        last = last.max(env.seq);
                        closed |= turn_state(&env.event) == Some(false);
                        running.apply(&env.event);
                        if ev_tx.send(env).is_err() { return; }
                    }
                    // The worker finished its turn: end it here too, like an engine would with
                    // `Idle`, so the client stops showing the session as working.
                    if closed {
                        let _ = ev_tx.send(Envelope {
                            seq: last,
                            session: id.clone(),
                            created: crate::engine::now_ms(),
                            event: Event::Idle,
                        });
                    }
                    if !session::Log::in_use(&store, &id) {
                        released = true;
                    }
                }
            }
        }
    });
    // A follower only watches; it never bridges the bus.
    Handle { ops: op_tx, events: ev_rx, bus: crate::irc::slot() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{Header, Log, Record, VERSION};
    use crate::protocol::{EndReason, TurnUsage};

    fn env(seq: u64, text: &str) -> Record {
        Record::Event {
            env: Envelope {
                seq,
                session: "s".into(),
                created: 0,
                event: Event::Notice { level: Level::Info, message: text.into() },
            },
        }
    }

    async fn next_text(h: &mut Handle) -> String {
        loop {
            let e = tokio::time::timeout(Duration::from_secs(5), h.events.recv()).await.unwrap().unwrap();
            match e.event {
                Event::Notice { message, .. } => return message,
                Event::Synced { .. } => continue,
                _ => continue,
            }
        }
    }

    #[tokio::test]
    async fn replays_then_streams_log_and_live_events_like_a_live_session() {
        let dir = std::env::temp_dir().join(format!("frog-follow-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let header = Header { version: VERSION, id: "s".into(), cwd: "/x".into(), model: "m".into(), created: 0, forked_from: None, worker: false };
        let mut owner = Log::create(&dir, header).unwrap();
        owner.append(&env(1, "first")).unwrap();

        let mut h = follow(dir.clone(), "s".into());
        h.ops.send(Op::Subscribe { after: 0 }).unwrap();
        assert_eq!(next_text(&mut h).await, "first");

        // A streaming event (only in the live file) and a finished step (in the log).
        let live = Envelope { seq: 2, session: "s".into(), created: 0,
            event: Event::Notice { level: Level::Info, message: "streaming".into() } };
        std::fs::write(session::live_path(&dir, "s"), format!("{}\n", serde_json::to_string(&live).unwrap())).unwrap();
        owner.append(&env(3, "second, logged")).unwrap();
        assert_eq!(next_text(&mut h).await, "streaming");
        assert_eq!(next_text(&mut h).await, "second, logged");

        h.ops.send(Op::Submit { text: "hi".into(), images: vec![], more: vec![] }).unwrap();
        assert!(next_text(&mut h).await.contains("can't reach it"));
        drop(owner);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn names_the_workers_model_and_open_turn_on_subscribe() {
        let dir = std::env::temp_dir().join(format!("frog-follow-status-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let header = Header { version: VERSION, id: "s".into(), cwd: "/x".into(), model: "cloud/qwen3-coder-next".into(), created: 0, forked_from: None, worker: false };
        let mut owner = Log::create(&dir, header).unwrap();
        owner.append(&Record::Event {
            env: Envelope {
                seq: 1,
                session: "s".into(),
                created: 0,
                event: Event::TurnStarted { turn: 1, input: "go".into(), images: Vec::new(), more: Vec::new() },
            },
        }).unwrap();
        // The worker switched models mid-session: the follower says the one running now.
        owner.append(&Record::Event {
            env: Envelope {
                seq: 2,
                session: "s".into(),
                created: 0,
                event: Event::ModelChanged { model: "zai/glm-5.3".into() },
            },
        }).unwrap();

        let mut h = follow(dir.clone(), "s".into());
        h.ops.send(Op::Subscribe { after: 0 }).unwrap();

        // Status with the worker's model, then the open turn, then synced.
        let mut status_model = None;
        let mut open_turn = false;
        loop {
            let e = tokio::time::timeout(Duration::from_secs(5), h.events.recv()).await.unwrap().unwrap();
            match e.event {
                Event::Status(s) => status_model = Some(s.model),
                Event::TurnStarted { .. } => open_turn = true,
                Event::Synced { .. } => break,
                _ => {}
            }
        }
        assert_eq!(status_model.as_deref(), Some("zai/glm-5.3"));
        assert!(open_turn, "a turn the owner started replays as running");

        // The worker ends the turn: the follower says `idle`, so the client stops
        // showing the session as working.
        owner.append(&Record::Event {
            env: Envelope {
                seq: 3,
                session: "s".into(),
                created: 0,
                event: Event::TurnEnded {
                    turn: 1,
                    reason: EndReason::Complete,
                    usage: TurnUsage::default(),
                },
            },
        }).unwrap();
        tokio::time::timeout(Duration::from_secs(5), async {
            while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
        }).await.expect("the ended turn settles the follower with idle");

        drop(owner);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
