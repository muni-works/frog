//! The turn's pace: output tokens over time, for the turn line's curve
//! (docs/design/transcript/spec.md, "What the log has, and what it needs"). Deltas aren't
//! persisted, so a finished turn keeps one small record on `turn_ended` ([`Pace`], in
//! `usage.pace`); while a call streams, the live count goes out on
//! [`crate::protocol::Event::OutputTokens`].
//!
//! Providers don't report token counts until a call ends, so while it streams the count is
//! approximate ([`CallPace::approx`]); when it ends, the provider's own figure replaces it, and
//! the call's share of the curve is scaled to match, so a turn's buckets add up to the output
//! tokens of the calls that streamed.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// At most this many buckets per turn; a longer turn gets wider buckets.
pub const MAX_BUCKETS: usize = 120;
/// The narrowest bucket. Widths are whole seconds.
pub const MIN_BUCKET_MS: u64 = 1000;
/// How finely a streaming call's pieces are timed before they're bucketed.
const BIN_MS: u64 = 100;

/// Output tokens per bucket over a turn, from its start: `tokens[i]` streamed in
/// `[i * bucket_ms, (i + 1) * bucket_ms)`. Tokens per second in a bucket is
/// `tokens[i] * 1000 / bucket_ms`. Trailing quiet buckets are dropped, so the last bucket is
/// the last one with output; the turn's length is `usage.timing.wall_ms`.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq, JsonSchema)]
pub struct Pace {
    pub bucket_ms: u32,
    pub tokens: Vec<u32>,
}

impl Pace {
    /// Tokens per second in each bucket.
    pub fn per_second(&self) -> Vec<f64> {
        let secs = self.bucket_ms as f64 / 1000.0;
        self.tokens.iter().map(|&t| t as f64 / secs).collect()
    }
}

/// One model call's stream as it arrives: pieces (streamed text, reasoning or tool arguments)
/// timed from when the request was sent.
#[derive(Clone, Debug, Default)]
pub struct CallPace {
    pieces: u64,
    chars: u64,
    /// `(bin start ms since sent, pieces, chars)`, one entry per [`BIN_MS`] bin that had any.
    bins: Vec<(u64, u64, u64)>,
}

impl CallPace {
    /// A streamed piece of `chars` characters, `ms` after the request was sent.
    pub fn piece(&mut self, ms: u64, chars: usize) {
        let chars = chars as u64;
        self.pieces += 1;
        self.chars += chars;
        let bin = ms / BIN_MS * BIN_MS;
        match self.bins.last_mut() {
            Some((b, p, c)) if *b == bin => {
                *p += 1;
                *c += chars;
            }
            _ => self.bins.push((bin, 1, chars)),
        }
    }

    /// The approximate output tokens so far: the number of pieces, or a quarter of the
    /// characters when pieces carry several tokens each (some providers batch them).
    pub fn approx(&self) -> u64 {
        weight(self.pieces, self.chars)
    }

    pub fn is_empty(&self) -> bool {
        self.pieces == 0
    }

    /// Whether the stream is slow at `now_ms` (since sent): it has streamed for at least
    /// [`SLOW_WINDOW_MS`] since its first piece, and over the last [`SLOW_WINDOW_MS`] it
    /// streamed under `floor` tokens per second.
    pub fn slow(&self, now_ms: u64, floor: f64) -> bool {
        let Some(&(first, _, _)) = self.bins.first() else {
            return false;
        };
        if now_ms < first + SLOW_WINDOW_MS {
            return false;
        }
        let from = now_ms - SLOW_WINDOW_MS;
        let (pieces, chars) = self
            .bins
            .iter()
            .filter(|(b, _, _)| *b + BIN_MS > from)
            .fold((0, 0), |(p, c), (_, bp, bc)| (p + bp, c + bc));
        (weight(pieces, chars) as f64) * 1000.0 / (SLOW_WINDOW_MS as f64) < floor
    }
}

/// How far back [`CallPace::slow`] looks (docs/design/transcript/spec.md, "The row": under a
/// quarter of the model's usual rate for 5 s).
pub const SLOW_WINDOW_MS: u64 = 5000;

/// A model's usual output rate this session: the median tokens per second of its last
/// [`RATES_KEPT`] finished calls that decoded for at least a second and wrote at least
/// [`RATE_MIN_TOKENS`] tokens. `None` until there is one.
#[derive(Clone, Debug, Default)]
pub struct Rates(Vec<f64>);

pub const RATES_KEPT: usize = 20;
pub const RATE_MIN_TOKENS: u64 = 32;

impl Rates {
    /// A finished call wrote `tokens` in `decode_ms` of decoding.
    pub fn add(&mut self, tokens: u64, decode_ms: u64) {
        if tokens < RATE_MIN_TOKENS || decode_ms < 1000 {
            return;
        }
        if self.0.len() == RATES_KEPT {
            self.0.remove(0);
        }
        self.0.push(tokens as f64 * 1000.0 / decode_ms as f64);
    }

    pub fn usual(&self) -> Option<f64> {
        if self.0.is_empty() {
            return None;
        }
        let mut v = self.0.clone();
        v.sort_by(f64::total_cmp);
        let n = v.len();
        Some(if n % 2 == 1 {
            v[n / 2]
        } else {
            (v[n / 2 - 1] + v[n / 2]) / 2.0
        })
    }
}

fn weight(pieces: u64, chars: u64) -> u64 {
    pieces.max(chars.div_ceil(4))
}

/// A turn's pace as its calls finish.
#[derive(Clone, Debug, Default)]
pub struct TurnPace {
    /// `(ms since the turn started, tokens)`.
    samples: Vec<(u64, f64)>,
}

impl TurnPace {
    /// A finished call that was sent `offset_ms` into the turn and streamed `call`; the
    /// provider says it produced `output` tokens, which are spread over its pieces by weight.
    /// A call that streamed nothing has no timing to record.
    pub fn add_call(&mut self, offset_ms: u64, call: &CallPace, output: u64) {
        let total = call.approx();
        if total == 0 || output == 0 {
            return;
        }
        let scale = output as f64 / total as f64;
        for &(bin, p, c) in &call.bins {
            self.samples
                .push((offset_ms + bin, weight(p, c) as f64 * scale));
        }
    }

    /// The record for a turn of `wall_ms`, or `None` when nothing streamed.
    pub fn finish(&self, wall_ms: u64) -> Option<Pace> {
        if self.samples.is_empty() {
            return None;
        }
        let span = wall_ms.max(self.samples.iter().map(|s| s.0 + 1).max().unwrap_or(1));
        let bucket_ms = bucket_ms(span);
        let n = (span.div_ceil(bucket_ms) as usize).clamp(1, MAX_BUCKETS);
        let mut sums = vec![0.0; n];
        for &(at, tokens) in &self.samples {
            sums[((at / bucket_ms) as usize).min(n - 1)] += tokens;
        }
        // Rounded so the buckets keep the exact total: each is the change in the rounded
        // running sum.
        let mut tokens = Vec::with_capacity(n);
        let (mut cum, mut prev) = (0.0, 0u64);
        for s in sums {
            cum += s;
            let now = cum.round() as u64;
            tokens.push((now - prev) as u32);
            prev = now;
        }
        while tokens.len() > 1 && tokens.last() == Some(&0) {
            tokens.pop();
        }
        Some(Pace {
            bucket_ms: bucket_ms as u32,
            tokens,
        })
    }
}

/// The bucket width for a turn of `span_ms`: one second, or as many whole seconds as keep it
/// to [`MAX_BUCKETS`].
pub fn bucket_ms(span_ms: u64) -> u64 {
    let per = span_ms.div_ceil(MAX_BUCKETS as u64);
    per.div_ceil(MIN_BUCKET_MS).max(1) * MIN_BUCKET_MS
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(pieces: &[(u64, usize)]) -> CallPace {
        let mut c = CallPace::default();
        for &(ms, chars) in pieces {
            c.piece(ms, chars);
        }
        c
    }

    #[test]
    fn buckets_widen_past_two_minutes() {
        assert_eq!(bucket_ms(1), 1000);
        assert_eq!(bucket_ms(120_000), 1000);
        assert_eq!(bucket_ms(120_001), 2000);
        assert_eq!(bucket_ms(600_000), 5000);
        // A day-long turn still fits.
        assert!(86_400_000u64.div_ceil(bucket_ms(86_400_000)) <= MAX_BUCKETS as u64);
    }

    #[test]
    fn the_approximate_count_is_pieces_or_a_quarter_of_the_characters() {
        // One token per piece (most OpenAI-compatible servers).
        assert_eq!(call(&[(0, 3), (10, 4), (20, 5)]).approx(), 3);
        // Pieces of many tokens (a provider that batches).
        assert_eq!(call(&[(0, 400)]).approx(), 100);
    }

    /// The provider's figure replaces the count: the buckets add up to it exactly.
    #[test]
    fn buckets_add_up_to_the_providers_count() {
        let mut t = TurnPace::default();
        // 30 pieces over 3 s, then the provider says 47 tokens.
        let c = call(&(0..30).map(|i| (i * 100, 4)).collect::<Vec<_>>());
        t.add_call(500, &c, 47);
        let p = t.finish(4000).unwrap();
        assert_eq!(p.bucket_ms, 1000);
        assert_eq!(p.tokens.iter().sum::<u32>(), 47);
        assert_eq!(p.tokens[0], 8); // 500..1000 ms: 5 of 30 pieces
        assert_eq!(p.tokens.len(), 4);
    }

    #[test]
    fn a_long_turn_has_at_most_120_buckets() {
        let mut t = TurnPace::default();
        for k in 0..600u64 {
            t.add_call(k * 1000, &call(&[(0, 4), (500, 4)]), 2);
        }
        let p = t.finish(600_000).unwrap();
        assert_eq!(p.bucket_ms, 5000);
        assert_eq!(p.tokens.len(), 120);
        assert_eq!(p.tokens.iter().sum::<u32>(), 1200);
        assert_eq!(p.per_second()[0], 2.0);
    }

    #[test]
    fn nothing_streamed_is_no_record() {
        let mut t = TurnPace::default();
        t.add_call(0, &CallPace::default(), 100);
        assert_eq!(t.finish(1000), None);
    }

    /// The worst case on the wire stays small: 120 buckets of six-digit counts.
    #[test]
    fn worst_case_size() {
        let p = Pace {
            bucket_ms: 720_000,
            tokens: vec![999_999; MAX_BUCKETS],
        };
        let json = serde_json::to_string(&p).unwrap();
        assert!(json.len() <= 900, "{} bytes", json.len());
        let max = Pace {
            bucket_ms: u32::MAX,
            tokens: vec![u32::MAX; MAX_BUCKETS],
        };
        assert!(serde_json::to_string(&max).unwrap().len() <= 1400);
    }

    /// Slow is a whole 5 s window under the floor: never before 5 s of streaming, and a burst
    /// inside the window lifts it.
    #[test]
    fn slow_needs_five_seconds_under_the_floor() {
        let mut c = CallPace::default();
        // 40 tok/s for 3 s from 2 s after sending, then 2 tok/s.
        for i in 0..120 {
            c.piece(2000 + i * 25, 4);
        }
        assert!(!c.slow(4900, 20.0), "not 5 s of streaming yet");
        for i in 0..20 {
            c.piece(5000 + i * 500, 4);
        }
        assert!(
            !c.slow(7000, 20.0),
            "the fast stretch is still in the window"
        );
        assert!(
            c.slow(10_500, 20.0),
            "5 s at 2 tok/s under a 20 tok/s floor"
        );
        assert!(!c.slow(10_500, 1.0), "over a lower floor");
        assert!(
            !CallPace::default().slow(60_000, 20.0),
            "nothing streamed: not slow (quiet)"
        );
    }

    #[test]
    fn usual_rate_is_the_median_of_real_calls() {
        let mut r = Rates::default();
        assert_eq!(r.usual(), None, "no finished call: never slow");
        r.add(10, 5000); // too few tokens to say
        r.add(500, 500); // under a second of decoding
        assert_eq!(r.usual(), None);
        r.add(100, 2000); // 50
        r.add(300, 3000); // 100
        r.add(80, 4000); // 20
        assert_eq!(r.usual(), Some(50.0));
        r.add(400, 2000); // 200
        assert_eq!(r.usual(), Some(75.0));
        for _ in 0..RATES_KEPT {
            r.add(1000, 1000);
        }
        assert_eq!(r.usual(), Some(1000.0), "only the last calls count");
    }
}
