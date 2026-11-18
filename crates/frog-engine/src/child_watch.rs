//! A child that goes quiet becomes a question, not a parent that waits in silence.
//!
//! Both kinds of child an engine runs are watched the same way: a `Task` subagent (the parent's
//! turn is blocked on it) and a child session the engine owns (`kids`: headless runs wait for
//! it, and the apps show it running). A [`Watch`] sees every event the child emits. Any event
//! at all is life: a streamed token, tool output, a status line, a provider's "busy,
//! retrying…" progress. When none has come for `child_quiet_secs` while the child is
//! working, and it isn't sitting on a permission card (the card already reaches the person
//! through the parent, so the child isn't quiet, it's waiting on them), the parent asks its
//! person one question on the ordinary question path:
//!
//! > The subagent “find the parser” has produced nothing for 5 min. It was asked: “…”
//! > [Keep waiting] [Stop it and carry on]
//!
//! Keep waiting starts the quiet clock again (another stretch asks again). Stop interrupts
//! the child and the parent carries on with whatever it reported so far, saying why. The
//! question is withdrawn the moment the child emits anything, ends, or is stopped, so a child
//! that recovers never leaves a stale card behind, and a child that has ended never asks
//! (#117: nothing here wakes the parent's model or queues anything for it).
//!
//! **Nobody to ask** (headless `-p`, `frog bench`, a client that can't show questions): no
//! question. After `child_quiet_stop_secs` of silence (default 30 min, longer than a provider
//! request's own timeout and its retries, so a slow call gets its own chance first) the engine
//! stops the child itself, exactly as the Stop answer would. A run with nobody watching must
//! end, and it must end the same way every time.
//!
//! **Dead** is not quiet. A child engine whose work loop has gone (a panic) closes its event
//! stream (see `engine::Closer`), and the parent reports that as a death at once: there is no
//! "keep waiting" for an engine that no longer exists. A `Task` returns an error naming it, for
//! the parent's model to act on in the turn it is in; a child session's parent gets a note,
//! as it does when a child ends a turn.

use crate::config::Config;
use crate::engine::Asker;
use crate::protocol::{Answer, AskOption, Event};
use std::time::Duration;
use tokio::sync::oneshot;
use tokio::time::Instant;

pub const KEEP: &str = "Keep waiting";
pub const STOP: &str = "Stop it and carry on";

/// Why a watch says to stop the child.
#[derive(Clone, Debug, PartialEq)]
pub enum Stop {
    /// The person picked Stop after it had been quiet this long.
    Asked(Duration),
    /// Nobody could be asked, and it was quiet for `child_quiet_stop_secs`.
    Auto(Duration),
}

impl Stop {
    /// The words the parent carries on with.
    pub fn words(&self, what: &str) -> String {
        match self {
            Stop::Asked(d) => format!(
                "The user stopped {what} after it had produced nothing for {}.",
                span(*d)
            ),
            Stop::Auto(d) => format!(
                "frog stopped {what} after it had produced nothing for {} (nobody was there to ask).",
                span(*d)
            ),
        }
    }
}

/// "5 min", "90 s".
pub fn span(d: Duration) -> String {
    let s = d.as_secs();
    if s >= 120 {
        format!("{} min", s / 60)
    } else {
        format!("{s} s")
    }
}

fn secs(n: u64) -> Option<Duration> {
    (n > 0).then(|| Duration::from_secs(n))
}

/// One child's quiet clock and its open question, if any.
pub struct Watch {
    /// How the parent names it: `the subagent “find the parser”`.
    what: String,
    /// What it was asked, for the question.
    brief: String,
    /// Where the question anchors in the parent's transcript (the Task item, the child's id).
    item: String,
    quiet: Option<Duration>,
    stop: Option<Duration>,
    asker: Asker,
    last: Instant,
    /// Permission cards it has open on the parent.
    cards: usize,
    open: Option<(String, oneshot::Receiver<Answer>)>,
}

impl Watch {
    pub(crate) fn new(cfg: &Config, asker: Asker, what: String, brief: &str, item: String) -> Self {
        let brief = brief.split_whitespace().collect::<Vec<_>>().join(" ");
        let brief = if brief.chars().count() > 160 {
            format!("{}…", brief.chars().take(160).collect::<String>())
        } else {
            brief
        };
        Self {
            what,
            brief,
            item,
            quiet: secs(cfg.child_quiet_secs),
            stop: secs(cfg.child_quiet_stop_secs),
            asker,
            last: Instant::now(),
            cards: 0,
            open: None,
        }
    }

    /// The child emitted `event`: it's alive. Its quiet clock restarts and an open question is
    /// withdrawn.
    pub fn saw(&mut self, event: &Event) {
        match event {
            Event::PermissionRequest { .. } => self.cards += 1,
            Event::PermissionResolved { .. } => self.cards = self.cards.saturating_sub(1),
            _ => {}
        }
        self.last = Instant::now();
        self.withdraw();
    }

    /// Restart the clock without an event (a new turn handed to an idle child).
    pub fn reset(&mut self) {
        self.last = Instant::now();
        self.withdraw();
    }

    /// Close an open question with no answer: the child spoke, ended, or was stopped.
    pub fn withdraw(&mut self) {
        if let Some((id, _)) = self.open.take() {
            self.asker.close(&id, Answer::default());
        }
    }

    /// Whether a question is open now (for tests and the state line).
    pub fn asking(&self) -> bool {
        self.open.is_some()
    }

    /// Resolves when the child should be stopped; pends while it's fine. Cancel-safe (all
    /// state lives in `self`), so it goes in a `select!` beside the child's events, called
    /// afresh each time round.
    pub async fn next(&mut self) -> Stop {
        loop {
            if let Some((id, rx)) = &mut self.open {
                let answer = rx.await.unwrap_or_default();
                let id = id.clone();
                self.open = None;
                self.asker.close(&id, answer.clone());
                if answer.choices.iter().any(|c| c == STOP) {
                    return Stop::Asked(self.last.elapsed());
                }
                // Keep waiting, or a dismissal: another full stretch before asking again.
                self.last = Instant::now();
                continue;
            }
            // On a card the person already has: not quiet.
            if self.cards > 0 {
                std::future::pending::<()>().await;
            }
            if self.asker.ready() {
                let Some(quiet) = self.quiet else {
                    std::future::pending::<()>().await;
                    unreachable!()
                };
                tokio::time::sleep_until(self.last + quiet).await;
                let gone = self.last.elapsed();
                let question = format!(
                    "{} has produced nothing for {}. It was asked: “{}”",
                    capital(&self.what),
                    span(gone),
                    self.brief
                );
                let options = vec![
                    AskOption {
                        label: KEEP.into(),
                        detail: Some("Ask again if it stays quiet as long again".into()),
                    },
                    AskOption {
                        label: STOP.into(),
                        detail: Some(
                            "Interrupt it; the parent goes on with what it has so far".into(),
                        ),
                    },
                ];
                match self.asker.open(&self.item, question, options) {
                    Some(open) => self.open = Some(open),
                    // Another question is on screen: try again shortly.
                    None => tokio::time::sleep(Duration::from_secs(5)).await,
                }
            } else {
                let Some(stop) = self.stop else {
                    std::future::pending::<()>().await;
                    unreachable!()
                };
                tokio::time::sleep_until(self.last + stop).await;
                return Stop::Auto(self.last.elapsed());
            }
        }
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        self.withdraw();
    }
}

fn capital(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().chain(c).collect(),
        None => String::new(),
    }
}
