// Tests for the composer's queue ingesting at tool-call boundaries: a follow-up sent while a
// turn runs goes in at the next boundary as a user message of the running turn — in order,
// exactly once, and the turn continues instead of ending.

use super::super::*;
use crate::config::{Config, Profile, ProviderKind};
use crate::engine::Options;
use crate::message::{Block, Message, Role, Usage};
use crate::protocol::{EndReason, Event, Image, Item, Mode, Op, Part};
use crate::provider::{scripted, Response, Stop};
use serde_json::json;
use std::sync::{Arc, Mutex};
use std::time::Duration;

fn reply(content: Vec<Block>, stop: Stop) -> Response {
    Response {
        message: Message {
            role: Role::Assistant,
            content,
        },
        usage: Usage {
            input: 100,
            output: 10,
            cache_read: 0,
            cache_write: 0,
            model: None,
            upstream: None,
            ran_on: None,
        },
        stop,
    }
}

fn text(t: &str) -> Block {
    Block::Text { text: t.into() }
}

/// A Bash call the test model can make, so the turn has a boundary to ingest at.
fn bash_call() -> Block {
    Block::ToolUse {
        id: "b1".into(),
        name: "Bash".into(),
        input: json!({ "command": "echo hi" }),
    }
}

async fn until_idle(h: &mut Handle) -> Vec<Envelope> {
    let mut out = Vec::new();
    loop {
        let env = h.events.recv().await.unwrap();
        let idle = matches!(env.event, Event::Idle);
        out.push(env);
        if idle {
            return out;
        }
    }
}

/// Two follow-ups sent mid-turn, while its tool call runs, both arrive exactly once, in
/// order, at the boundary — and the turn continues to its next model call rather than
/// ending. The script: a turn that calls Bash, then replies again after it (which is where
/// the ingested messages sit), then ends.
#[tokio::test]
async fn two_queued_messages_ingest_once_in_order_at_the_boundary() {
    let script = vec![
        // Step 1: call Bash. While it runs (and after its batch), the client queues both.
        reply(vec![bash_call()], Stop::ToolUse),
        // Step 2: the model's next call — the boundary delivered both messages before it.
        reply(vec![text("both read")], Stop::End),
    ];
    let mut profile = Profile::new(ProviderKind::Ollama, "test");
    profile.tool_mode = crate::config::ToolMode::Native;
    let opts = Options {
        cfg: Config {
            hermetic: true,
            ..Config::default()
        },
        profile_name: "test".into(),
        profile,
        cwd: std::env::temp_dir(),
        mode: Mode::AcceptEdits,
        can_ask: true,
        resume: None,
        store: None,
        sandbox: false,
        rich: false,
        subagent: false,
        chat: false,
    };
    let client = scripted::Client::new(script);
    let sent = client.sent.clone();
    let mut h = crate::engine::start(opts, crate::provider::Provider::Scripted(client)).unwrap();
    while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}

    h.ops
        .send(Op::Submit {
            text: "first turn".into(),
            images: Vec::new(),
            more: Vec::new(),
        })
        .unwrap();
    // Wait until the turn is running (its first model call is out), then queue two.
    while sent.lock().unwrap().is_empty() {
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    h.ops
        .send(Op::Submit {
            text: "one".into(),
            images: Vec::new(),
            more: vec![Part {
                text: "two".into(),
                images: Vec::new(),
            }],
        })
        .unwrap();

    let mut evs = Vec::new();
    loop {
        let env = h.events.recv().await.unwrap();
        let done = matches!(env.event, Event::Idle);
        evs.push(env);
        if done {
            break;
        }
    }

    // One turn, not two: the queue went into the running turn.
    let starts: Vec<_> = evs
        .iter()
        .filter_map(|e| match &e.event {
            Event::TurnStarted { input, .. } => Some(input.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(starts, ["first turn"], "one turn; the follow-ups don't start another: {starts:?}");

    // The ingested event, exactly once, in order.
    let ingested: Vec<Vec<String>> = evs
        .iter()
        .filter_map(|e| match &e.event {
            Event::FollowUpsIngested { texts } => Some(texts.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(ingested, [vec!["one".to_string(), "two".to_string()]], "both messages, in order, exactly once: {ingested:?}");

    // The turn continued: the model was called again after the boundary, and its request
    // carried both messages as user text after the tool results, before the next step.
    let calls = sent.lock().unwrap().len();
    assert_eq!(calls, 2, "the turn continues after the boundary");

    // The second request's messages: exactly one new user message holding both texts, once.
    let last = sent.lock().unwrap().last().cloned().unwrap();
    let json = &last[last.rfind("[{\"role\"").expect("messages in the request")..];
    let messages: Vec<Message> = serde_json::from_str(json).unwrap();
    let user: Vec<&Message> = messages.iter().filter(|m| m.role == Role::User).collect();
    let joined: String = user
        .last()
        .unwrap()
        .content
        .iter()
        .filter_map(|b| match b {
            Block::Text { text } => Some(text.clone()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n---\n");
    assert!(joined.contains("one"), "{joined}");
    assert!(joined.contains("two"), "{joined}");
    // Count occurrences of each word (not the separator pattern)
    let count_one = joined.matches("one").count();
    let count_two = joined.matches("two").count();
    assert_eq!(count_one, 1, "exactly one 'one': {joined}");
    assert_eq!(count_two, 1, "exactly one 'two': {joined}");

    // The turn ended complete, not cancelled or errored.
    let ends: Vec<_> = evs
        .iter()
        .filter_map(|e| match &e.event {
            Event::TurnEnded { turn, reason, .. } => Some((*turn, reason.clone())),
            _ => None,
        })
        .collect();
    assert!(
        ends.iter().all(|(_, r)| matches!(r, EndReason::Complete)),
        "{ends:?}"
    );

    // Nothing left parked: a later submit runs as its own turn, as before.
    h.ops
        .send(Op::Submit {
            text: "after".into(),
            images: Vec::new(),
            more: Vec::new(),
        })
        .unwrap();
    let after = until_idle(&mut h).await;
    let after_starts: Vec<_> = after
        .iter()
        .filter_map(|e| match &e.event {
            Event::TurnStarted { input, .. } => Some(input.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(after_starts, ["after"]);
}

/// A message arriving while the model is mid-stream does not interrupt: it lands at the
/// next boundary (here: after the turn's single tool call), never during the call.
#[tokio::test]
async fn a_message_sent_midstream_lands_at_the_next_boundary_not_during_the_call() {
    // A slow Bash (the scripted provider's tool runner sleeps per delayMs; here the queue
    // arrives while the call is in flight) — the test asserts the ingest event comes after
    // the tool completes, not between request and tool result.
    let script = vec![
        reply(vec![bash_call()], Stop::ToolUse),
        reply(vec![text("read it")], Stop::End),
    ];
    let mut profile = Profile::new(ProviderKind::Ollama, "test");
    profile.tool_mode = crate::config::ToolMode::Native;
    let opts = Options {
        cfg: Config {
            hermetic: true,
            ..Config::default()
        },
        profile_name: "test".into(),
        profile,
        cwd: std::env::temp_dir(),
        mode: Mode::AcceptEdits,
        can_ask: true,
        resume: None,
        store: None,
        sandbox: false,
        rich: false,
        subagent: false,
        chat: false,
    };
    let client = scripted::Client::new(script);
    let sent = client.sent.clone();
    let mut h = crate::engine::start(opts, crate::provider::Provider::Scripted(client)).unwrap();
    while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
    h.ops
        .send(Op::Submit {
            text: "go".into(),
            images: Vec::new(),
            more: Vec::new(),
        })
        .unwrap();
    while sent.lock().unwrap().is_empty() {
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    h.ops
        .send(Op::Submit {
            text: "queued midstream".into(),
            images: Vec::new(),
            more: Vec::new(),
        })
        .unwrap();

    let order: Vec<String> = loop {
        let env = h.events.recv().await.unwrap();
        match &env.event {
            Event::Idle => break Vec::new(),
            Event::ItemCompleted {
                item: Item::ToolCall { .. },
                ..
            } => {
                // The tool finished; the ingest must come at or after this point, never before.
                let mut order = vec!["tool".to_string()];
                let mut done = false;
                while !done {
                    let env = h.events.recv().await.unwrap();
                    match &env.event {
                        Event::FollowUpsIngested { .. } => order.push("ingested".into()),
                        Event::TurnEnded { .. } => order.push("ended".into()),
                        Event::Idle => done = true,
                        _ => {}
                    }
                }
                break order;
            }
            _ => {}
        }
    };
    assert!(
        order.first().map(String::as_str) == Some("tool"),
        "the tool completed first: {order:?}"
    );
    assert!(
        order.iter().any(|s| s == "ingested"),
        "the queued message landed at the boundary: {order:?}"
    );
    assert!(
        !order.starts_with(&["ingested".to_string()]),
        "never mid-call: {order:?}"
    );
}

/// Images a queued message carries go along when it ingests, after the text they came with.
#[tokio::test]
async fn an_image_queued_midturn_ingests_with_its_text() {
    let script = vec![
        reply(vec![bash_call()], Stop::ToolUse),
        reply(vec![text("seen")], Stop::End),
    ];
    let mut profile = Profile::new(ProviderKind::Ollama, "test");
    profile.tool_mode = crate::config::ToolMode::Native;
    let opts = Options {
        cfg: Config {
            hermetic: true,
            ..Config::default()
        },
        profile_name: "test".into(),
        profile,
        cwd: std::env::temp_dir(),
        mode: Mode::AcceptEdits,
        can_ask: true,
        resume: None,
        store: None,
        sandbox: false,
        rich: false,
        subagent: false,
        chat: false,
    };
    let client = scripted::Client::new(script);
    let sent = client.sent.clone();
    let mut h = crate::engine::start(opts, crate::provider::Provider::Scripted(client)).unwrap();
    while !matches!(h.events.recv().await.unwrap().event, Event::Idle) {}
    h.ops
        .send(Op::Submit {
            text: "go".into(),
            images: Vec::new(),
            more: Vec::new(),
        })
        .unwrap();
    while sent.lock().unwrap().is_empty() {
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let png = Image {
        mime: "image/png".into(),
        data: "AAAA".into(),
    };
    h.ops
        .send(Op::Submit {
            text: "".into(),
            images: vec![png],
            more: Vec::new(),
        })
        .unwrap();
    until_idle(&mut h).await;

    let last = sent.lock().unwrap().last().cloned().unwrap();
    let json = &last[last.rfind("[{\"role\"").expect("messages in the request")..];
    let messages: Vec<Message> = serde_json::from_str(json).unwrap();
    let last_user = messages.iter().rev().find(|m| m.role == Role::User).unwrap();
    let blocks: Vec<String> = last_user
        .content
        .iter()
        .map(|b| match b {
            Block::Text { text } => text.trim().to_string(),
            Block::Image { mime, .. } => format!("<{mime}>"),
            _ => "?".into(),
        })
        .collect();
    assert!(
        blocks.iter().any(|b| b.contains("image/png")),
        "the image rode along: {blocks:?}"
    );
}
