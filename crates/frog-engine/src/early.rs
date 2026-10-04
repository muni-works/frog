//! Streaming tool execution: read-only tool calls start as soon as their arguments arrive,
//! while the model is still writing the rest of its reply. The batch that runs once the reply
//! ends takes their results instead of running them again, so nothing the model, the user or
//! the session log sees changes; the turn just waits less.
//!
//! Only calls that change nothing start early, and only while every call before them in the
//! reply could too: a Read after an Edit must see the edit. A started call is used only if the
//! finished reply has exactly that call at that place, after calls that all matched as well;
//! anything else (a stream that breaks off, an interrupted turn, a reply that parses
//! differently in the end) drops it, which aborts it.

use crate::prompt;
use crate::tools::{self, Ctx, Output};
use anyhow::Result;
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Instant, SystemTime};
use tokio::task::JoinHandle;

/// Tools that may start early: they read files and change nothing (Read only records what it
/// read, which is replayed when its result is used), and they never ask permission.
pub const TOOLS: [&str; 3] = ["Read", "Grep", "Glob"];

const CLOSE: &str = "</tool_call>";

/// What an early call did.
pub struct Ran {
    pub out: Result<Output>,
    /// Files it read, as `Ctx::mark_read` recorded them.
    pub read_files: HashMap<PathBuf, Option<SystemTime>>,
    pub started: Instant,
    pub done: Instant,
}

/// A call running early. Dropping it aborts it.
pub struct Call {
    name: String,
    input: Value,
    task: JoinHandle<Ran>,
}

impl Drop for Call {
    fn drop(&mut self) {
        self.task.abort();
    }
}

impl Call {
    /// Wait for it to finish; `None` if it panicked (then run it again the ordinary way).
    pub async fn finish(mut self) -> Option<Ran> {
        (&mut self.task).await.ok()
    }
}

/// The calls one reply started early, by their place among its tool calls.
#[derive(Default)]
pub struct Early {
    calls: Vec<Option<Call>>,
    /// A call that can't start early was seen; later ones may depend on it, so they wait too.
    closed: bool,
    /// The reply as it ended stopped matching what started, from this call on.
    diverged: bool,
    /// The streamed text, for calls written as `<tool_call>` text (text mode).
    text: String,
    /// The provider streams native tool calls, so calls written as text don't count.
    native: bool,
}

impl Early {
    /// The reply's `index`th tool call is complete. It starts if `ctx` (a context to run it in)
    /// says it can and everything before it started too.
    pub fn ready(&mut self, index: usize, name: String, input: Value, ctx: Option<Ctx>) {
        self.native = true;
        self.start(index, name, input, ctx);
    }

    fn start(&mut self, index: usize, name: String, input: Value, ctx: Option<Ctx>) {
        if self.closed || index < self.calls.len() {
            return;
        }
        let (true, Some(mut ctx)) = (index == self.calls.len(), ctx) else {
            self.closed = true;
            return;
        };
        let task = tokio::spawn({
            let (name, input) = (name.clone(), input.clone());
            async move {
                let started = Instant::now();
                let out = tools::run(&name, &input, &mut ctx).await;
                Ran {
                    out,
                    read_files: ctx.read_files,
                    started,
                    done: Instant::now(),
                }
            }
        });
        self.calls.push(Some(Call { name, input, task }));
    }

    /// More of the reply's text. Each `<tool_call>` block that closes is a complete call;
    /// `ctx` gives the context to run one in, if it can start early.
    pub fn text(&mut self, s: &str, mut ctx: impl FnMut(&str, &Value) -> Option<Ctx>) {
        if self.native || self.closed {
            return;
        }
        let from = self.text.len().saturating_sub(CLOSE.len() - 1);
        self.text.push_str(s);
        let fresh = &self.text.as_bytes()[from..];
        if !fresh.windows(CLOSE.len()).any(|w| w == CLOSE.as_bytes()) {
            return;
        }
        let Some(cut) = self.text.rfind(CLOSE).map(|i| i + CLOSE.len()) else {
            return;
        };
        // As `normalize` will read the whole reply, up to the last closed call.
        let upto = prompt::strip_answer_tags(&self.text[..cut]);
        let Some((_, calls)) = prompt::extract_tool_calls(&upto) else {
            return;
        };
        let have = self.calls.len();
        for (i, (name, input)) in calls.into_iter().enumerate().skip(have) {
            let c = ctx(&name, &input);
            self.start(i, name, input, c);
        }
    }

    /// Whether anything started early.
    pub fn is_empty(&self) -> bool {
        self.calls.is_empty()
    }

    /// The early run of the finished reply's `index`th call, if exactly this call started
    /// early there and every call before it matched too. Ask once per call, in order.
    pub fn take(&mut self, index: usize, name: &str, input: &Value) -> Option<Call> {
        if self.diverged {
            return None;
        }
        let matches = self
            .calls
            .get(index)
            .and_then(Option::as_ref)
            .is_some_and(|c| c.name == name && c.input == *input);
        if !matches {
            // Abort the rest now rather than when the batch ends.
            self.diverged = true;
            self.calls.clear();
            return None;
        }
        self.calls[index].take()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn ctx() -> Option<Ctx> {
        Some(Ctx::new(std::env::temp_dir()))
    }

    #[tokio::test]
    async fn only_a_prefix_of_startable_calls_starts() {
        let mut e = Early::default();
        e.ready(0, "Glob".into(), json!({ "pattern": "*.nope" }), ctx());
        e.ready(1, "Edit".into(), json!({}), None);
        e.ready(2, "Glob".into(), json!({ "pattern": "*.nope" }), ctx());
        assert_eq!(e.calls.len(), 1);
        assert!(e.take(0, "Glob", &json!({ "pattern": "*.nope" })).is_some());
        assert!(e.take(1, "Edit", &json!({})).is_none());
        assert!(e.take(2, "Glob", &json!({ "pattern": "*.nope" })).is_none());
    }

    #[tokio::test]
    async fn a_mismatch_drops_everything_after_it() {
        let mut e = Early::default();
        for i in 0..3 {
            e.ready(
                i,
                "Glob".into(),
                json!({ "pattern": format!("{i}") }),
                ctx(),
            );
        }
        assert!(e.take(0, "Glob", &json!({ "pattern": "0" })).is_some());
        assert!(e.take(1, "Glob", &json!({ "pattern": "other" })).is_none());
        // Call 2 matches, but call 1 didn't: it may not have been what the model meant.
        assert!(e.take(2, "Glob", &json!({ "pattern": "2" })).is_none());
        assert!(e.is_empty());
    }

    #[tokio::test]
    async fn a_skipped_index_closes() {
        let mut e = Early::default();
        e.ready(1, "Glob".into(), json!({}), ctx());
        e.ready(0, "Glob".into(), json!({}), ctx());
        assert!(e.is_empty());
    }

    #[tokio::test]
    async fn text_calls_start_as_their_blocks_close() {
        let mut e = Early::default();
        let call = r#"<tool_call>{"name": "Glob", "arguments": {"pattern": "*.x"}}</tool_call>"#;
        let (head, tail) = call.split_at(40);
        e.text("Looking.\n", |_, _| ctx());
        e.text(head, |_, _| ctx());
        assert!(e.is_empty());
        // The closing tag itself split across chunks.
        let (t1, t2) = tail.split_at(tail.len() - 4);
        e.text(t1, |_, _| ctx());
        assert!(e.is_empty());
        e.text(t2, |_, _| ctx());
        assert_eq!(e.calls.len(), 1);
        e.text(
            "\n<tool_call>{\"name\": \"Bash\", \"arguments\": {}}</tool_call>",
            |n, _| (n != "Bash").then(ctx).flatten(),
        );
        assert_eq!(e.calls.len(), 1);
        assert!(e.closed);
        let ran = e
            .take(0, "Glob", &json!({ "pattern": "*.x" }))
            .unwrap()
            .finish()
            .await
            .unwrap();
        assert!(ran.out.is_ok());
    }

    #[tokio::test]
    async fn native_calls_win_over_text() {
        let mut e = Early::default();
        e.ready(0, "Glob".into(), json!({ "pattern": "a" }), ctx());
        e.text(
            r#"<tool_call>{"name": "Glob", "arguments": {"pattern": "b"}}</tool_call>"#,
            |_, _| ctx(),
        );
        assert!(e.take(0, "Glob", &json!({ "pattern": "a" })).is_some());
    }

    #[tokio::test]
    async fn read_records_what_it_read() {
        let dir = std::env::temp_dir().join(format!("frog-early-{}", crate::provider::new_id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.txt"), "hi\n").unwrap();
        let mut e = Early::default();
        let input = json!({ "file_path": "a.txt" });
        e.ready(0, "Read".into(), input.clone(), Some(Ctx::new(dir.clone())));
        let ran = e.take(0, "Read", &input).unwrap().finish().await.unwrap();
        assert!(ran.out.unwrap().content.contains("hi"));
        assert!(ran.read_files.contains_key(&dir.join("a.txt")));
    }
}
