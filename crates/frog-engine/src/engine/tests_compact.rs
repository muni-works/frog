// Tests for compaction against a model whose context window can't hold the history: the
// provider here enforces a window (`scripted::Client::window`), as a real server does, so a
// summary request that doesn't fit is refused instead of quietly answered.

use super::compact::is_overflow;
use super::{Handle, start};
use crate::config::{Config, Profile, ProviderKind, ToolMode};
use crate::engine::Options;
use crate::message::{Block, Message, Role, Usage};
use crate::protocol::{EndReason, Event, Mode, Op};
use crate::provider::{HttpError, Provider, Response, Stop, StreamError, scripted};
use std::sync::{Arc, Mutex};

fn reply(t: &str) -> Response {
    Response {
        message: Message {
            role: Role::Assistant,
            content: vec![Block::Text { text: t.into() }],
        },
        usage: Usage {
            input: 100,
            output: 10,
            ..Default::default()
        },
        stop: Stop::End,
    }
}

/// An engine that takes its model's window to be `believed` tokens, on a provider that
/// refuses any request over `enforced` bytes. Also the requests the provider was sent.
fn engine(
    believed: u64,
    enforced: Option<usize>,
    fails: Vec<scripted::Fail>,
    script: Vec<Response>,
) -> (Handle, Arc<Mutex<Vec<String>>>) {
    let mut profile = Profile::new(ProviderKind::Ollama, "m");
    profile.tool_mode = ToolMode::Native;
    profile.context_window = Some(believed);
    let opts = Options {
        cfg: Config {
            hermetic: true,
            ..Config::default()
        },
        profile_name: "testprov/small".into(),
        profile,
        cwd: std::env::temp_dir(),
        mode: Mode::Default,
        can_ask: true,
        resume: None,
        store: None,
        sandbox: false,
        rich: false,
        subagent: false,
        chat: false,
    };
    let mut client = scripted::Client::new(script);
    client.window = enforced;
    *client.fails.lock().unwrap() = fails.into();
    let sent = client.sent.clone();
    (start(opts, Provider::Scripted(client)).unwrap(), sent)
}

/// Submit one prompt and collect every event through the next `Idle`.
async fn turn(h: &mut Handle, prompt: &str) -> Vec<Event> {
    h.ops
        .send(Op::Submit {
            text: prompt.into(),
            images: Vec::new(),
            more: Vec::new(),
        })
        .unwrap();
    let mut out = Vec::new();
    loop {
        let e = h.events.recv().await.unwrap().event;
        let idle = matches!(e, Event::Idle);
        out.push(e);
        if idle {
            return out;
        }
    }
}

async fn ready(h: &mut Handle) {
    while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
}

async fn stop(mut h: Handle) {
    h.ops.send(Op::Shutdown).unwrap();
    while h.events.recv().await.is_some() {}
}

fn end_error(evs: &[Event]) -> Option<String> {
    evs.iter().find_map(|e| match e {
        Event::TurnEnded {
            reason: EndReason::Error { error },
            ..
        } => Some(error.to_string()),
        _ => None,
    })
}

fn completed(evs: &[Event]) -> bool {
    evs.iter().any(|e| {
        matches!(
            e,
            Event::TurnEnded {
                reason: EndReason::Complete,
                ..
            }
        )
    })
}

fn count(evs: &[Event], f: impl Fn(&Event) -> bool) -> usize {
    evs.iter().filter(|e| f(e)).count()
}

/// A history several times the model's window (a session switched to a small model, as in
/// sessions 20261112-15*: "prompt is 138220 tokens; the context window is 32768") is
/// summarized in parts that each fit, then merged: no request is ever over the window, and
/// the turn completes on the summary.
#[tokio::test]
async fn a_history_larger_than_the_window_is_summarized_in_parts() {
    // 16k tokens ≈ 56k bytes of window; the provider refuses anything over that.
    let window = 56_000;
    let script = (0..40).map(|i| reply(&format!("SUMMARY-{i}"))).collect();
    let (mut h, sent) = engine(16_000, Some(window), Vec::new(), script);
    ready(&mut h).await;
    // ~200k bytes of history: three and a half windows.
    let long: String = (0..4_000)
        .map(|i| format!("step {i}: edited src/file_{i}.rs and ran the tests again.\n"))
        .collect();
    assert!(long.len() > 3 * window);
    let evs = turn(&mut h, &long).await;
    assert_eq!(end_error(&evs), None);
    assert!(completed(&evs));
    assert_eq!(count(&evs, |e| matches!(e, Event::Compacted { .. })), 1);
    assert_eq!(
        count(&evs, |e| matches!(e, Event::CompactionFailed { .. })),
        0
    );
    let sent = sent.lock().unwrap();
    // Nothing was sent that the window couldn't hold: the fit was decided before the call.
    for (i, r) in sent.iter().enumerate() {
        assert!(r.len() <= window, "request {i} is {} bytes", r.len());
    }
    // Map (several parts), reduce, then the turn's own call on the merged summary.
    let parts = sent.iter().filter(|r| r.contains("<transcript>")).count();
    assert!(parts >= 4, "{parts} parts");
    // Every line of the history went to exactly one part.
    for probe in ["step 0:", "step 1999:", "step 3999:"] {
        assert_eq!(
            sent.iter()
                .filter(|r| r.contains("<transcript>") && r.contains(probe))
                .count(),
            1,
            "{probe}"
        );
    }
    let merge = &sent[parts];
    assert!(merge.contains("SUMMARY-0") && merge.contains(&format!("SUMMARY-{}", parts - 1)));
    assert!(merge.contains("detailed summary"));
    let last = sent.last().unwrap();
    assert!(
        last.contains(&format!("SUMMARY-{parts}")),
        "the merged summary carries on"
    );
    assert!(!last.contains("step 1999:"));
    drop(sent);
    stop(h).await;
}

/// The window was taken to be bigger than the server's (the catalog said one thing, the
/// server enforces another): the summary request that should have fit is refused as too
/// long, and compaction goes again in parts half the size instead of ending the turn.
#[tokio::test]
async fn a_too_long_summary_request_is_retried_smaller() {
    let window = 60_000;
    let script = (0..10).map(|i| reply(&format!("SUMMARY-{i}"))).collect();
    let (mut h, sent) = engine(200_000, Some(window), Vec::new(), script);
    ready(&mut h).await;
    let long: String = (0..1_200)
        .map(|i| format!("step {i}: edited src/file_{i}.rs and ran the tests again.\n"))
        .collect();
    assert!(long.len() > window && long.len() < 2 * window - 40_000);
    let evs = turn(&mut h, &long).await;
    assert_eq!(end_error(&evs), None);
    assert!(completed(&evs));
    assert_eq!(count(&evs, |e| matches!(e, Event::Compacted { .. })), 1);
    assert_eq!(
        count(&evs, |e| matches!(e, Event::CompactionFailed { .. })),
        0
    );
    let sent = sent.lock().unwrap();
    // Refused: the turn's call, then the whole-history summary. Then two halves, the merge,
    // and the turn's call again.
    let refused = sent.iter().filter(|r| r.len() > window).count();
    assert_eq!(
        refused,
        2,
        "{:?}",
        sent.iter().map(String::len).collect::<Vec<_>>()
    );
    assert_eq!(
        sent.iter().filter(|r| r.contains("<transcript>")).count(),
        2
    );
    assert!(sent.last().unwrap().contains("SUMMARY-2"));
    drop(sent);
    stop(h).await;
}

/// When nothing gets through, the turn ends with one line that says what to do, and the
/// session is still there: the next message runs.
#[tokio::test]
async fn a_failed_compaction_says_what_to_do_and_the_session_stays_usable() {
    let overflow = || {
        scripted::Fail::http(
            413,
            "{\"error\":{\"message\":\"context_length_exceeded: this request is at least 69966 \
             tokens and the model's context window is 65536 tokens\"}}",
        )
    };
    // The turn's call, the whole summary, the parts, the smaller parts: all refused.
    let fails = vec![overflow(), overflow(), overflow(), overflow()];
    let (mut h, sent) = engine(200_000, None, fails, vec![reply("Back at work.")]);
    ready(&mut h).await;
    let evs = turn(&mut h, "keep going").await;
    let error = end_error(&evs).expect("the turn ends in an error");
    assert!(error.contains("testprov/small's context window"), "{error}");
    assert!(
        error.contains("switch to a model with a bigger window"),
        "{error}"
    );
    assert!(
        error.contains("start a new session from this one's summary"),
        "{error}"
    );
    assert!(error.contains("Nothing was lost"), "{error}");
    // One line: none of the provider's payload.
    assert!(!error.contains("69966"), "{error}");
    assert_eq!(
        count(&evs, |e| matches!(e, Event::CompactionFailed { .. })),
        1
    );
    assert_eq!(sent.lock().unwrap().len(), 4);
    // The session goes on: the next message is a normal turn, with the first still in it.
    let evs = turn(&mut h, "try again").await;
    assert_eq!(end_error(&evs), None);
    assert!(completed(&evs));
    let sent = sent.lock().unwrap();
    assert!(sent[4].contains("keep going") && sent[4].contains("try again"));
    drop(sent);
    stop(h).await;
}

/// A summarizer that's down is not a window problem, and the line doesn't say it is.
#[tokio::test]
async fn a_compaction_that_fails_for_another_reason_does_not_blame_the_window() {
    let overflow = scripted::Fail::http(400, "prompt is too long");
    let down = scripted::Fail::http(401, "{\"error\":{\"message\":\"invalid api key\"}}");
    let (mut h, _) = engine(200_000, None, vec![overflow, down], vec![reply("unused")]);
    ready(&mut h).await;
    let evs = turn(&mut h, "keep going").await;
    let error = end_error(&evs).expect("the turn ends in an error");
    assert!(!error.contains("context window"), "{error}");
    assert!(
        error.contains("the call to testprov/small failed"),
        "{error}"
    );
    stop(h).await;
}

/// A local server reports an overflow as an error event inside a 2xx stream, not as a 4xx.
#[test]
fn an_overflow_is_recognized_in_a_stream_error_too() {
    let stream = |m: &str| anyhow::Error::from(StreamError { message: m.into() });
    assert!(is_overflow(&stream(
        "{\"message\":\"prompt is 138220 tokens; the context window is 32768\"}"
    )));
    assert!(!is_overflow(&stream("upstream timed out")));
    let http = |status, body: &str| {
        anyhow::Error::from(HttpError {
            status,
            body: body.into(),
            billing: None,
            retry_after: None,
        })
    };
    assert!(is_overflow(&http(
        413,
        "context_length_exceeded: this request is at least 66388 tokens (531099 bytes) and the \
         model's context window is 65536 tokens"
    )));
    assert!(!is_overflow(&http(503, "model worker stopped")));
}
