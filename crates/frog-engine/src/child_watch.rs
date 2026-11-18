//! A child that goes quiet becomes a question, not a parent that waits in silence.
//!
//! Both kinds of child an engine runs are watched the same way: a `Task` subagent (the parent's
//! turn is blocked on it) and a child session the engine owns (`kids`: headless runs wait for
//! it, and the apps show it running). A [`Watch`] sees every event the child emits. Any event
//! that shows progress is life: a streamed token, tool output, a card, counted progress, a
//! provider saying it's busy. A status line, a notice, or a model call starting again after a
//! timed-out stream is not (see [`alive`]): a stall that times out and retries would otherwise
//! look alive every ten minutes for an hour. When none has come for `child_quiet_secs` while
//! the child is working, and it isn't sitting on a permission card (the card already reaches the person
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
//! (#117: going quiet never wakes the parent's model or queues anything for it; only a stop
//! or a death sends the one note a child's turn end always sends).
//!
//! **Nobody to ask** (headless `-p`, `frog bench`, a client that can't show questions): no
//! question. After `child_quiet_stop_secs` of silence (default 30 min: three of a provider
//! request's own 10 min timeouts, so a slow call gets a couple of chances first) the engine
//! stops the child itself, exactly as the Stop answer would. A run with nobody watching must
//! end, and it must end the same way every time.
//!
//! **Dead** is not quiet. A child engine whose work loop has gone (a panic) closes its event
//! stream (see `engine::Closer`), and the parent reports that as a death at once: there is no
//! "keep waiting" for an engine that no longer exists. A `Task` returns an error naming it, for
//! the parent's model to act on in the turn it is in; a child session's parent gets a note,
//! as it does when a child ends a turn.
//!
//! **The turn's own model call** is watched the same way ([`Watch::call`]): the spec's live row
//! says "No output for 12s" by itself, and at `call_quiet_secs` (default 30 s) of nothing
//! streamed the person is asked:
//!
//! > The model has sent nothing for 30 s.
//! > [Keep waiting] [Stop the turn]
//!
//! Stop is the Stop button (`Op::Interrupt`). Keep waiting asks again after twice as long, so
//! a slow provider isn't nagged every 30 s. Any streamed piece withdraws it and starts the
//! clock again from the first stretch. Nobody to ask: nothing (the provider's own request
//! timeout and retries govern). Never for a subagent (its parent's watch covers it) or a
//! call that streams nothing to the person (compaction, side jobs).

use crate::config::Config;
use crate::engine::Asker;
use crate::protocol::{Answer, AskOption, Event};
use std::time::Duration;
use tokio::sync::oneshot;
use tokio::time::Instant;

pub const KEEP: &str = "Keep waiting";
pub const STOP: &str = "Stop it and carry on";
pub const STOP_TURN: &str = "Stop the turn";

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
    /// What it was asked, for the question. `None`: the turn's own model call.
    brief: Option<String>,
    /// Where the question anchors in the parent's transcript (the Task item, the child's id).
    item: String,
    quiet: Option<Duration>,
    /// The first stretch, which `quiet` returns to when there's life again; Keep waiting
    /// doubles `quiet` from it when `backoff`.
    base: Option<Duration>,
    backoff: bool,
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
        let quiet = secs(cfg.child_quiet_secs);
        Self {
            what,
            brief: Some(brief),
            item,
            quiet,
            base: quiet,
            backoff: false,
            stop: secs(cfg.child_quiet_stop_secs),
            asker,
            last: Instant::now(),
            cards: 0,
            open: None,
        }
    }

    /// The turn's own model call: asks after `quiet` of nothing streamed, then after twice as
    /// long each time the person keeps waiting; never stops it unasked.
    pub(crate) fn call(asker: Asker, quiet: Duration) -> Self {
        Self {
            what: "the model".into(),
            brief: None,
            item: String::new(),
            quiet: Some(quiet),
            base: Some(quiet),
            backoff: true,
            stop: None,
            asker,
            last: Instant::now(),
            cards: 0,
            open: None,
        }
    }

    /// Where the question anchors: the reasoning or message item the call is streaming, once
    /// there is one.
    pub fn anchor(&mut self, item: &str) {
        if self.item.is_empty() {
            self.item = item.into();
        }
    }

    /// The child emitted `event`: it's alive. Its quiet clock restarts and an open question is
    /// withdrawn.
    pub fn saw(&mut self, event: &Event) {
        if !alive(event) {
            return;
        }
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
        self.quiet = self.base;
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
                if answer.choices.iter().any(|c| c == STOP || c == STOP_TURN) {
                    return Stop::Asked(self.last.elapsed());
                }
                // Keep waiting, or a dismissal: another full stretch before asking again
                // (twice as long, for a call).
                self.last = Instant::now();
                if self.backoff {
                    self.quiet = self.quiet.map(|q| q * 2);
                }
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
                let (question, options) = match &self.brief {
                    Some(brief) => (
                        format!(
                            "{} has produced nothing for {}. It was asked: “{brief}”",
                            capital(&self.what),
                            span(gone),
                        ),
                        vec![
                            AskOption {
                                label: KEEP.into(),
                                detail: Some("Ask again if it stays quiet as long again".into()),
                            },
                            AskOption {
                                label: STOP.into(),
                                detail: Some(
                                    "Interrupt it; the parent goes on with what it has so far"
                                        .into(),
                                ),
                            },
                        ],
                    ),
                    None => (
                        format!("The model has sent nothing for {}.", span(gone)),
                        vec![
                            AskOption {
                                label: KEEP.into(),
                                detail: Some("Ask again if it stays quiet twice as long".into()),
                            },
                            AskOption {
                                label: STOP_TURN.into(),
                                detail: Some("End this turn; what came so far stays".into()),
                            },
                        ],
                    ),
                };
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

/// Whether `event` shows the child making progress. A status line or a notice isn't progress,
/// and neither is a model call starting or being retried after a stall: a stream that hangs
/// until the request timeout and is retried emits those every few minutes forever. Progress
/// with a count is, and so is a provider saying it's busy (a machine reporting it is busy).
fn alive(event: &Event) -> bool {
    match event {
        Event::Status(_) | Event::Notice { .. } => false,
        Event::Progress {
            label, completed, ..
        } => completed.is_some() || label == crate::model_policy::BUSY_LABEL,
        _ => true,
    }
}
