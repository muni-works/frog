//! How much prompt prefill the server's cache saved, per model call, and the calls where it
//! should have saved more ("cold" calls: a cache bust).
//!
//! The engine records, for every call, the prompt tokens the server reported cached and how the
//! request compares with the one sent before it to the same conversation (a call or a warm-up):
//! whether it only appended to it, and what share of it repeats that one's start. A request
//! that only appends should find nearly all of that share cached. When most of it was
//! prefilled anyway, the server lost the conversation's cache (evicted, or never kept it). A
//! request that doesn't extend the last one is frog rewriting the prefix (pruning, compaction,
//! a changed system prompt or tool list), which the `rewrites` count shows instead.

use frog_engine::protocol::CallTiming;
use serde::{Deserialize, Serialize};

/// The least a call should have found cached before it counts as cold: one of tang's KV
/// blocks, so a short prompt below block granularity isn't a bust.
pub const MIN_EXPECTED: u64 = 256;

/// One model call, as the bench records it.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct Call {
    /// Which conversation of the run (an index into `RunResult::sessions`), and which of the
    /// task's turns, both from 0.
    pub conversation: u32,
    pub turn: u32,
    pub prompt_tokens: u64,
    pub cached_tokens: u64,
    /// `prompt_tokens - cached_tokens`: what the server had to prefill.
    pub prefilled_tokens: u64,
    /// Request sent → first streamed token.
    pub prefill_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extends: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reusable: Option<f64>,
    /// The first call of a conversation opened after the run's first (a resume or a new one).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub reopened: bool,
    /// A compaction summary rather than a step.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub compact: bool,
    pub cold: bool,
    /// Output tokens and decode time, for throughput.
    #[serde(default)]
    pub output_tokens: u64,
    #[serde(default)]
    pub decode_ms: u64,
    /// The node it ran on, for a pooled model.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub node: Option<String>,
}

impl Call {
    pub fn new(conversation: u32, turn: u32, reopened: bool, t: &CallTiming) -> Self {
        let mut c = Self {
            conversation,
            turn,
            prompt_tokens: t.prompt_tokens,
            cached_tokens: t.cached_tokens,
            prefilled_tokens: t.prompt_tokens.saturating_sub(t.cached_tokens),
            prefill_ms: t.ttft_ms,
            extends: t.extends,
            reusable: t.reusable,
            reopened,
            compact: t.compact,
            cold: false,
            output_tokens: t.output_tokens,
            decode_ms: t.decode_ms,
            node: t.ran_on.clone(),
        };
        c.cold = c.is_cold();
        c
    }

    /// Prompt tokens the cache could have covered: the share that repeats the last request.
    pub fn expected_cached(&self) -> u64 {
        (self.prompt_tokens as f64 * self.reusable.unwrap_or(0.0)).round() as u64
    }

    /// The request only appended to the last one, yet most of what it repeats was prefilled.
    pub fn is_cold(&self) -> bool {
        let expected = self.expected_cached();
        self.extends == Some(true) && expected >= MIN_EXPECTED && self.cached_tokens * 2 < expected
    }

    /// frog sent something that doesn't extend the last request (not counting compaction
    /// calls, whose own prompt is a different one).
    pub fn is_rewrite(&self) -> bool {
        self.extends == Some(false) && !self.compact
    }
}

/// Totals over some calls.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Summary {
    pub calls: u64,
    pub prompt: u64,
    pub cached: u64,
    pub prefill_ms: u64,
    pub cold: u64,
    pub rewrites: u64,
    /// First calls of reopened conversations, and what they found cached.
    pub reopened: u64,
    pub reopened_prompt: u64,
    pub reopened_cached: u64,
}

impl Summary {
    pub fn of<'a>(calls: impl IntoIterator<Item = &'a Call>) -> Self {
        let mut s = Self::default();
        for c in calls {
            s.calls += 1;
            s.prompt += c.prompt_tokens;
            s.cached += c.cached_tokens;
            s.prefill_ms += c.prefill_ms;
            s.cold += c.cold as u64;
            s.rewrites += c.is_rewrite() as u64;
            if c.reopened {
                s.reopened += 1;
                s.reopened_prompt += c.prompt_tokens;
                s.reopened_cached += c.cached_tokens;
            }
        }
        s
    }

    pub fn hit_rate(&self) -> Option<f64> {
        (self.prompt > 0).then(|| self.cached as f64 / self.prompt as f64)
    }

    pub fn prefilled_per_call(&self) -> Option<f64> {
        (self.calls > 0).then(|| (self.prompt - self.cached) as f64 / self.calls as f64)
    }

    pub fn prefill_s_per_call(&self) -> Option<f64> {
        (self.calls > 0).then(|| self.prefill_ms as f64 / 1000.0 / self.calls as f64)
    }

    pub fn reopened_hit_rate(&self) -> Option<f64> {
        (self.reopened_prompt > 0)
            .then(|| self.reopened_cached as f64 / self.reopened_prompt as f64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn timing(prompt: u64, cached: u64, extends: Option<bool>, reusable: f64) -> CallTiming {
        CallTiming {
            prompt_tokens: prompt,
            cached_tokens: cached,
            extends,
            reusable: extends.map(|_| reusable),
            ttft_ms: 100,
            ..Default::default()
        }
    }

    #[test]
    fn a_call_that_extends_the_last_but_prefills_it_again_is_cold() {
        // 4000 tokens, 95% of them repeating the last request.
        let warm = Call::new(0, 1, false, &timing(4000, 3700, Some(true), 0.95));
        assert!(!warm.cold);
        assert_eq!(warm.prefilled_tokens, 300);
        let cold = Call::new(0, 1, false, &timing(4000, 512, Some(true), 0.95));
        assert!(cold.cold);
        // Frog rewrote the prefix: a miss, but not the server's.
        let rewrite = Call::new(0, 1, false, &timing(4000, 512, Some(false), 0.3));
        assert!(!rewrite.cold && rewrite.is_rewrite());
        // The conversation's first request: nothing to hold the cache to.
        let first = Call::new(0, 0, false, &timing(4000, 0, None, 0.0));
        assert!(!first.cold && !first.is_rewrite());
        // Too little repeated to need a cache.
        let short = Call::new(0, 0, false, &timing(300, 0, Some(true), 0.5));
        assert!(!short.cold);
    }

    #[test]
    fn summaries_count_hits_cold_calls_and_reopened_conversations() {
        let calls = [
            Call::new(0, 0, false, &timing(3000, 0, None, 0.0)),
            Call::new(0, 0, false, &timing(3500, 2900, Some(true), 0.85)),
            Call::new(0, 1, false, &timing(4000, 100, Some(true), 0.9)),
            Call::new(1, 2, true, &timing(4200, 3800, Some(true), 0.95)),
        ];
        let s = Summary::of(&calls);
        assert_eq!((s.calls, s.cold, s.rewrites, s.reopened), (4, 1, 0, 1));
        assert_eq!(s.prompt, 14_700);
        assert_eq!(s.cached, 6_800);
        assert!((s.hit_rate().unwrap() - 6_800.0 / 14_700.0).abs() < 1e-9);
        assert_eq!(s.prefilled_per_call(), Some(7_900.0 / 4.0));
        assert_eq!(s.reopened_hit_rate(), Some(3800.0 / 4200.0));
        assert_eq!(Summary::of(&[]).hit_rate(), None);
    }
}
