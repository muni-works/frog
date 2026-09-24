//! Smart thinking budgets: whether a reasoning model should think before a given call.
//!
//! On small local reasoning models (Qwen3 4B/8B) reasoning is most of the generated tokens and
//! a large share of wall time. Frog's session logs show where it pays: the first call of a
//! turn (planning), after reading (the step before an edit carries the longest reasoning), and
//! after an error. After a successful edit, write or command, the next step is usually routine
//! (run the check, make the next planned change, report), and reasoning there mostly restates
//! the plan. So `auto` thinks by default and turns it off only for those follow-ups, and never
//! for more than [`MAX_QUIET`] calls in a row.
//!
//! Where it does think, a budget caps how long: servers that take one (tang-llm) close the
//! reasoning after that many tokens and make the model answer. On Qwen3-8B in frog-bench the
//! median call reasoned ~560 tokens and 90% under ~1.1-2k, with the longest on a turn's first
//! call; [`DEFAULT_BUDGET`] trims the tail and leaves typical calls alone, and planning a new
//! request gets twice as much.

use crate::config::Thinking;
use crate::message::{Block, Message, Role};

/// Calls in a row without thinking before one gets to think again (to re-plan).
pub const MAX_QUIET: u32 = 3;

/// Reasoning tokens per call, where the model thinks (see [`budget`]).
pub const DEFAULT_BUDGET: u32 = 1024;

/// Tools whose successful result rarely needs reasoning about.
const ROUTINE: &[&str] = &["Edit", "Write", "Bash", "TodoWrite"];

/// Whether the next call (continuing from `messages`) should think, under `auto`. `quiet` is
/// how many calls in a row have already gone without.
pub fn wanted(messages: &[Message], quiet: u32) -> bool {
    if quiet >= MAX_QUIET {
        return true;
    }
    let Some(last) = messages.last().filter(|m| m.role == Role::User) else {
        return true;
    };
    let mut results = last
        .content
        .iter()
        .filter_map(|b| match b {
            Block::ToolResult {
                name,
                content,
                is_error,
                ..
            } => Some((name.as_str(), content.as_str(), *is_error)),
            _ => None,
        })
        .peekable();
    // A new request, or a history just compacted: plan.
    if results.peek().is_none() {
        return true;
    }
    !results.all(|(name, content, is_error)| {
        !is_error && ROUTINE.contains(&name) && !(name == "Bash" && failed(content))
    })
}

/// The cap on reasoning tokens for the next call: none when thinking is off for it
/// (`switch == Some(false)`) or `base` is 0 (unlimited), else `base`, doubled when the call
/// plans a new request (no tool results to act on yet).
pub fn budget(base: u32, switch: Option<bool>, messages: &[Message]) -> Option<u32> {
    if base == 0 || switch == Some(false) {
        return None;
    }
    let planning = messages.last().is_none_or(|m| {
        m.role == Role::User
            && !m
                .content
                .iter()
                .any(|b| matches!(b, Block::ToolResult { .. }))
    });
    Some(if planning {
        base.saturating_mul(2)
    } else {
        base
    })
}

/// Bash reports a non-zero exit as a normal result ending in `[exit code N]`.
fn failed(output: &str) -> bool {
    output.contains("[exit code ")
}

/// What to ask the provider for: `None` leaves the model's default, `Some(false)` turns
/// thinking off. `can_switch` is whether the model honors that (probed): `Some(false)` for
/// models that always reason, `None` when unknown.
pub fn switch(mode: Thinking, can_switch: Option<bool>, want: bool) -> Option<bool> {
    match mode {
        Thinking::Always => None,
        // Asked for explicitly: try unless the model is known to reason regardless.
        Thinking::Never => (can_switch != Some(false)).then_some(false),
        Thinking::Auto => (can_switch == Some(true) && !want).then_some(false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn results(rs: &[(&str, &str, bool)]) -> Vec<Message> {
        vec![
            Message::user("fix the bug"),
            Message {
                role: Role::User,
                content: rs
                    .iter()
                    .enumerate()
                    .map(|(i, (name, content, is_error))| Block::ToolResult {
                        id: format!("t{i}"),
                        name: name.to_string(),
                        content: content.to_string(),
                        is_error: *is_error,
                    })
                    .collect(),
            },
        ]
    }

    #[test]
    fn plans_on_a_new_request() {
        assert!(wanted(&[Message::user("add a flag")], 0));
        assert!(wanted(&[], 0));
    }

    #[test]
    fn skips_after_routine_successes() {
        assert!(!wanted(&results(&[("Edit", "ok", false)]), 0));
        assert!(!wanted(
            &results(&[
                ("Bash", "test result: ok", false),
                ("TodoWrite", "ok", false)
            ]),
            1
        ));
    }

    #[test]
    fn thinks_after_errors_and_failed_commands() {
        assert!(wanted(
            &results(&[("Edit", "old_string not found", true)]),
            0
        ));
        assert!(wanted(
            &results(&[("Bash", "FAILED tests\n[exit code 1]", false)]),
            0
        ));
    }

    #[test]
    fn thinks_after_reading() {
        assert!(wanted(&results(&[("Read", "fn main() {}", false)]), 0));
        assert!(wanted(
            &results(&[("Edit", "ok", false), ("Grep", "src/a.rs:1", false)]),
            0
        ));
        assert!(wanted(&results(&[("mcp__x__y", "{}", false)]), 0));
    }

    #[test]
    fn re_plans_after_a_quiet_streak() {
        assert!(wanted(&results(&[("Edit", "ok", false)]), MAX_QUIET));
    }

    #[test]
    fn budget_doubles_for_planning_and_is_off_without_thinking() {
        let plan = [Message::user("add a flag")];
        let act = results(&[("Read", "fn main() {}", false)]);
        assert_eq!(budget(1024, None, &plan), Some(2048));
        assert_eq!(budget(1024, None, &act), Some(1024));
        assert_eq!(budget(1024, Some(true), &act), Some(1024));
        assert_eq!(budget(1024, Some(false), &act), None);
        assert_eq!(budget(0, None, &plan), None);
    }

    #[test]
    fn switch_respects_mode_and_capability() {
        assert_eq!(switch(Thinking::Auto, Some(true), false), Some(false));
        assert_eq!(switch(Thinking::Auto, Some(true), true), None);
        assert_eq!(switch(Thinking::Auto, None, false), None);
        assert_eq!(switch(Thinking::Auto, Some(false), false), None);
        assert_eq!(switch(Thinking::Always, Some(true), false), None);
        assert_eq!(switch(Thinking::Never, None, true), Some(false));
        assert_eq!(switch(Thinking::Never, Some(false), true), None);
    }
}
