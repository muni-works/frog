//! Follow a session another frog process is running: replay its log, then stream what it
//! appends, live, without taking it over. A client that opens a session a worker holds (the
//! app clicking a running `frog -p` session) sees the work happen instead of a blank one.
//!
//! Input can't reach the session while the other process holds it: a `Submit` gets a notice.
//! When that process lets go, a notice says so; reopening then resumes it normally.

use std::path::PathBuf;
use std::time::Duration;

use tokio::sync::mpsc;

use crate::engine::Handle;
use crate::protocol::{Envelope, Event, Level, Op};
use crate::session;

/// How often to look for new records in the log.
const POLL: Duration = Duration::from_millis(300);

pub fn follow(store: PathBuf, id: String) -> Handle {
    let (op_tx, mut op_rx) = mpsc::unbounded_channel::<Op>();
    let (ev_tx, ev_rx) = mpsc::unbounded_channel::<Envelope>();
    tokio::spawn(async move {
        let mut last = 0u64;
        let mut subscribed = false;
        let mut released = false;
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
                        for env in session::events_after(&store, &id, after).unwrap_or_default() {
                            last = last.max(env.seq);
                            if ev_tx.send(env).is_err() { return; }
                        }
                        let _ = ev_tx.send(Envelope {
                            seq: last,
                            session: id.clone(),
                            created: crate::engine::now_ms(),
                            event: Event::Synced { upto: last },
                        });
                        let _ = ev_tx.send(notice(last, Level::Info,
                            "following live: another frog process is running this session"));
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
                    for env in session::events_after(&store, &id, last).unwrap_or_default() {
                        last = last.max(env.seq);
                        if ev_tx.send(env).is_err() { return; }
                    }
                    if !session::Log::in_use(&store, &id) {
                        released = true;
                        let _ = ev_tx.send(notice(last, Level::Info,
                            "the worker finished; reopen this conversation to continue it"));
                    }
                }
            }
        }
    });
    Handle { ops: op_tx, events: ev_rx }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::{Header, Log, Record, VERSION};

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
    async fn replays_then_streams_what_the_owner_appends_then_notices_release() {
        let dir = std::env::temp_dir().join(format!("frog-follow-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let header = Header { version: VERSION, id: "s".into(), cwd: "/x".into(), model: "m".into(), created: 0, forked_from: None };
        let mut owner = Log::create(&dir, header).unwrap();
        owner.append(&env(1, "first")).unwrap();

        let mut h = follow(dir.clone(), "s".into());
        h.ops.send(Op::Subscribe { after: 0 }).unwrap();
        assert_eq!(next_text(&mut h).await, "first");
        assert!(next_text(&mut h).await.starts_with("following live"));

        owner.append(&env(2, "second, live")).unwrap();
        assert_eq!(next_text(&mut h).await, "second, live");

        h.ops.send(Op::Submit { text: "hi".into(), images: vec![] }).unwrap();
        assert!(next_text(&mut h).await.contains("can't reach it"));

        drop(owner);
        assert!(next_text(&mut h).await.contains("finished"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
