// What every model call re-sends: the system prompt and the tool list. Its size is cost and
// prefill time on every call, and its bytes must hold still so providers' prompt caches hit.

use super::*;
use crate::config::{Config, Profile, ProviderKind};
use crate::engine::Options;
use crate::message::{Block, Message, Role, Usage};
use crate::protocol::{Event, Mode, Op};
use crate::provider::{Response, Stop, scripted};
use serde_json::json;
use std::sync::{Arc, Mutex};

type Fixed = Arc<Mutex<Vec<(String, Vec<(String, String, String)>)>>>;

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

/// A small git project, as the benchmark tasks are.
fn project() -> PathBuf {
    let d = std::env::temp_dir().join(format!("frog-prompt-test-{}", session::new_id()));
    std::fs::create_dir_all(d.join("src")).unwrap();
    std::fs::create_dir_all(d.join(".git")).unwrap();
    std::fs::write(d.join("src/calc.py"), "def add(a, b):\n    return a + b\n").unwrap();
    d
}

/// A coding session on a big-window cloud model, headless or with the app's capabilities.
fn session(script: Vec<Response>, app: bool) -> (Handle, Fixed, PathBuf) {
    let dir = project();
    let mut profile = Profile::new(ProviderKind::Openai, "glm-5.3-flash");
    profile.context_window = Some(200_000);
    profile.tool_mode = crate::config::ToolMode::Native;
    let opts = Options {
        cfg: Config {
            hermetic: true,
            ..Config::default()
        },
        profile_name: "test".into(),
        profile,
        cwd: dir.clone(),
        mode: Mode::Default,
        can_ask: app,
        resume: None,
        store: Some(dir.clone()),
        sandbox: false,
        rich: false,
        subagent: false,
        chat: false,
    };
    let client = scripted::Client::new(script);
    let fixed = client.fixed.clone();
    let h = start(opts, Provider::Scripted(client)).unwrap();
    if app {
        h.ops
            .send(Op::SetClientCaps {
                irc: false,
                panes: true,
                ask: true,
                sessions: true,
            })
            .unwrap();
    }
    (h, fixed, dir)
}

async fn turn(h: &mut Handle, prompt: &str) {
    h.ops
        .send(Op::Submit {
            text: prompt.into(),
            images: Vec::new(),
            more: Vec::new(),
        })
        .unwrap();
}

/// Through the end of the next turn.
async fn idle(h: &mut Handle) {
    while !matches!(
        h.events.recv().await.unwrap().event,
        Event::TurnEnded { .. }
    ) {}
}

/// Chars of everything fixed in one request.
fn size(f: &(String, Vec<(String, String, String)>)) -> usize {
    f.0.len()
        + f.1
            .iter()
            .map(|(n, d, s)| n.len() + d.len() + s.len())
            .sum::<usize>()
}

/// One plain turn's first request.
async fn first_call(app: bool) -> (String, Vec<(String, String, String)>) {
    let (mut h, fixed, _dir) = session(vec![reply(vec![text("ok")], Stop::End)], app);
    turn(&mut h, "hi").await;
    idle(&mut h).await;
    let f = fixed.lock().unwrap();
    f[0].clone()
}

/// The system prompt split at its headings, each with its size, for the breakdown table.
fn sections(system: &str) -> Vec<(String, usize)> {
    let mut out: Vec<(String, usize)> = Vec::new();
    let mut name = "intro".to_string();
    let mut len = 0;
    for line in system.split_inclusive('\n') {
        if line.starts_with("# ") || line.starts_with("## ") {
            out.push((name, len));
            name = line.trim().to_string();
            len = 0;
        }
        len += line.len();
    }
    out.push((name, len));
    out
}

/// `cargo test -p frog-engine prompt_breakdown -- --ignored --nocapture`: the table in the PR.
#[tokio::test]
#[ignore]
async fn prompt_breakdown() {
    let est = context::Estimator::default();
    for app in [false, true] {
        let (system, tools) = first_call(app).await;
        println!("\n## {} mode", if app { "app" } else { "headless" });
        println!("| part | chars | ~tokens |\n|---|---:|---:|");
        for (name, len) in sections(&system) {
            println!("| system: {name} | {len} | {} |", est.tokens(len));
        }
        let mut t: Vec<_> = tools
            .iter()
            .map(|(n, d, s)| (n.clone(), d.len() + s.len() + n.len()))
            .collect();
        t.sort_by_key(|x| std::cmp::Reverse(x.1));
        for (n, len) in &t {
            println!("| tool: {n} | {len} | {} |", est.tokens(*len));
        }
        if std::env::var("DUMP").is_ok() {
            for (n, d, s) in &tools {
                println!("\n=== {n}\n{d}\n{s}");
            }
            println!("\n=== SYSTEM\n{system}");
        }
        let total = size(&(system.clone(), tools.clone()));
        println!(
            "| **total** ({} tools) | {total} | {} |",
            tools.len(),
            est.tokens(total)
        );
    }
}

/// The budget for what a plain coding call re-sends, in chars. Set from the size after the
/// prompt diet (see the PR); raise it only on purpose, since every call pays it.
const HEADLESS_BUDGET: usize = 19_000;
const APP_BUDGET: usize = 22_000;

#[tokio::test]
async fn the_fixed_prompt_stays_under_budget() {
    for (app, budget) in [(false, HEADLESS_BUDGET), (true, APP_BUDGET)] {
        let f = first_call(app).await;
        let n = size(&f);
        assert!(
            n <= budget,
            "{} fixed prompt is {n} chars, over its {budget} budget: tools {:?}",
            if app { "app" } else { "headless" },
            f.1.iter().map(|t| &t.0).collect::<Vec<_>>()
        );
    }
}

/// Two calls in one turn and the first call of the next turn send the same system prompt and
/// tool list byte for byte, so a provider's prompt cache serves them.
#[tokio::test]
async fn consecutive_calls_share_the_fixed_prefix() {
    for app in [false, true] {
        let script = vec![
            reply(
                vec![Block::ToolUse {
                    id: "g1".into(),
                    name: "Glob".into(),
                    input: json!({ "pattern": "**/*.py" }),
                }],
                Stop::ToolUse,
            ),
            reply(vec![text("one")], Stop::End),
            reply(vec![text("two")], Stop::End),
        ];
        let (mut h, fixed, _dir) = session(script, app);
        turn(&mut h, "find python files").await;
        idle(&mut h).await;
        turn(&mut h, "again").await;
        idle(&mut h).await;
        let f = fixed.lock().unwrap();
        assert_eq!(f.len(), 3);
        for i in 1..3 {
            assert_eq!(f[0].0, f[i].0, "system prompt changed on call {i}");
            assert_eq!(f[0].1, f[i].1, "tool list changed on call {i}");
        }
    }
}

/// A deferred built-in is out of the default list and named in the system prompt; calling it
/// by name runs it and appends it to the tool list, leaving the prefix before it as it was.
#[tokio::test]
async fn calling_a_deferred_tool_loads_it_at_the_end() {
    let script = vec![
        reply(
            vec![Block::ToolUse {
                id: "n1".into(),
                name: "Next".into(),
                input: json!({ "text": "commit this" }),
            }],
            Stop::ToolUse,
        ),
        reply(vec![text("done")], Stop::End),
    ];
    let (mut h, fixed, _dir) = session(script, false);
    turn(&mut h, "suggest").await;
    let mut ran = false;
    loop {
        let e = h.events.recv().await.unwrap().event;
        if let Event::ItemCompleted { item, .. } = &e
            && let crate::protocol::Item::ToolCall { name, outcome, .. } = item
            && name == "Next"
        {
            ran = *outcome == crate::protocol::ToolOutcome::Ok;
        }
        if matches!(e, Event::TurnEnded { .. }) {
            break;
        }
    }
    assert!(ran, "Next didn't run");
    let f = fixed.lock().unwrap();
    let names = |i: usize| f[i].1.iter().map(|t| t.0.clone()).collect::<Vec<_>>();
    assert!(!names(0).contains(&"Next".to_string()), "{:?}", names(0));
    assert!(f[0].0.contains("- Next(text"), "the catalog names it");
    assert_eq!(f[0].0, f[1].0, "loading changed the system prompt");
    assert_eq!(
        f[1].1[..f[0].1.len()],
        f[0].1[..],
        "loading rewrote the prefix"
    );
    assert_eq!(names(1).last().map(String::as_str), Some("Next"));
}
