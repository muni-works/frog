//! `--serve-ws`, driven over a real websocket: the handshake, refusals, a peer replacing
//! another, a permission round trip, and the git credential helper. The model is a scripted
//! OpenAI-compatible server standing in for Frog Cloud (FROG_BASE_URL), with a placeholder
//! FROG_API_KEY, as in Frog Cloud's sandbox.

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;

type Ws = WebSocketStream<TcpStream>;

fn temp_dir(name: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let d = std::env::temp_dir().join(format!("frog-ws-{name}-{nanos}"));
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// Read one HTTP/1.1 request: its head (request line and headers) and body.
async fn read_request(sock: &mut TcpStream) -> Option<(String, String)> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let end = loop {
        if let Some(p) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break p + 4;
        }
        let n = sock.read(&mut chunk).await.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = String::from_utf8_lossy(&buf[..end]).into_owned();
    let len: usize = head
        .lines()
        .find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.eq_ignore_ascii_case("content-length")
                .then(|| v.trim().parse().ok())?
        })
        .unwrap_or(0);
    while buf.len() < end + len {
        let n = sock.read(&mut chunk).await.ok()?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    Some((head, String::from_utf8_lossy(&buf[end..]).into_owned()))
}

async fn respond(sock: &mut TcpStream, kind: &str, body: &str) {
    let resp = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = sock.write_all(resp.as_bytes()).await;
    let _ = sock.shutdown().await;
}

fn sse(chunks: &[Value]) -> String {
    let mut s: String = chunks.iter().map(|c| format!("data: {c}\n\n")).collect();
    s.push_str("data: [DONE]\n\n");
    s
}

fn text_reply(text: &str) -> String {
    sse(&[
        json!({"choices":[{"index":0,"delta":{"role":"assistant","content":text},"finish_reason":null}]}),
        json!({"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}),
    ])
}

fn tool_reply(name: &str, args: Value) -> String {
    sse(&[
        json!({"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":name,"arguments":args.to_string()}}]},"finish_reason":null}]}),
        json!({"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}),
    ])
}

/// An OpenAI-compatible server that answers each turn request with the next scripted reply
/// (then "ok"), and anything else (model lists, titles) blandly. Returns its `/v1` base.
async fn fake_model(script: Vec<String>, models: Models) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let script = Arc::new(Mutex::new(VecDeque::from(script)));
    tokio::spawn(async move {
        loop {
            let (mut sock, _) = listener.accept().await.unwrap();
            let (script, models) = (script.clone(), models.clone());
            tokio::spawn(async move {
                let Some((head, body)) = read_request(&mut sock).await else {
                    return;
                };
                if !head.starts_with("POST") {
                    return respond(&mut sock, "application/json", r#"{"data":[]}"#).await;
                }
                // Only model requests name a model; the compiled-memory probe doesn't.
                if let Ok(v) = serde_json::from_str::<Value>(&body)
                    && v.get("model").is_some()
                {
                    let auth = head
                        .lines()
                        .find_map(|l| {
                            let (k, v) = l.split_once(':')?;
                            k.eq_ignore_ascii_case("authorization")
                                .then(|| v.trim().to_string())
                        })
                        .unwrap_or_default();
                    models
                        .lock()
                        .unwrap()
                        .push((v["model"].as_str().unwrap_or("").into(), auth));
                }
                // A turn carries the tools; side requests (titles, summaries) don't.
                let next = body
                    .contains("\"tools\"")
                    .then(|| script.lock().unwrap().pop_front())
                    .flatten();
                let reply = next.unwrap_or_else(|| text_reply("ok"));
                respond(&mut sock, "text/event-stream", &reply).await;
            });
        }
    });
    format!("http://{addr}/v1")
}

struct Frog {
    child: tokio::process::Child,
    addr: String,
    /// The model each request named, and its Authorization header.
    models: Models,
}

type Models = Arc<Mutex<Vec<(String, String)>>>;

impl Drop for Frog {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

async fn frog(script: Vec<String>, extra: &[&str]) -> Frog {
    frog_on(script, Some("cloud/scripted"), extra).await
}

/// The key Frog Cloud's sandbox hands the engine; its gateway swaps in the real one.
const PLACEHOLDER_KEY: &str = "frog-sandbox-placeholder";

async fn frog_on(script: Vec<String>, model: Option<&str>, extra: &[&str]) -> Frog {
    let models: Models = Default::default();
    let base = fake_model(script, models.clone()).await;
    let home = temp_dir("home");
    let work = temp_dir("work");

    let store = home.join("store");
    let mut c = tokio::process::Command::new(env!("CARGO_BIN_EXE_frog"));
    // Port 0: frog binds a free port itself and prints it. Picking one here and handing it
    // over raced between the tests running in parallel: two frogs could get the same port, and
    // one test's client then replaced the other's peer mid-test.
    c.args(["--serve", "--serve-ws", "127.0.0.1:0"]);
    if let Some(m) = model {
        c.args(["-m", m]);
    }
    c.arg("--store")
        .arg(&store)
        .args(extra)
        .current_dir(&work)
        .env("HOME", &home)
        // A plain Frog Cloud client, with its base URL pointed at the scripted server.
        .env("FROG_BASE_URL", &base)
        .env("FROG_API_KEY", PLACEHOLDER_KEY)
        .env("FROG_KEYCHAIN", "off")
        .env_remove("TANG_CLOUD_BASE_URL")
        .env_remove("TANG_BASE_URL")
        .env_remove("FROG_MODEL")
        .env_remove("OPENAI_API_KEY")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    let mut child = c.spawn().unwrap();
    // "frog serving websocket on <addr>" names the port it bound; the rest of stderr is passed
    // through so a failing test still shows the engine's log.
    let mut lines = tokio::io::BufReader::new(child.stderr.take().unwrap()).lines();
    let addr = tokio::time::timeout(Duration::from_secs(30), async {
        while let Some(line) = lines.next_line().await.unwrap() {
            eprintln!("{line}");
            if let Some(a) = line.strip_prefix("frog serving websocket on ") {
                return a.trim().to_string();
            }
        }
        panic!("frog exited before serving the websocket");
    })
    .await
    .expect("frog --serve-ws never said where it's serving");
    tokio::spawn(async move {
        while let Ok(Some(line)) = lines.next_line().await {
            eprintln!("{line}");
        }
    });
    let f = Frog {
        child,
        addr,
        models,
    };
    for _ in 0..600 {
        if let Some(v) = health(&f.addr).await {
            assert_eq!(v, json!({"ok": true, "protocol": 1}));
            return f;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("frog --serve-ws never became healthy");
}

async fn health(addr: &str) -> Option<Value> {
    let mut s = TcpStream::connect(addr).await.ok()?;
    s.write_all(b"GET /health HTTP/1.1\r\nHost: frog\r\n\r\n")
        .await
        .ok()?;
    let mut out = String::new();
    s.read_to_string(&mut out).await.ok()?;
    assert!(out.starts_with("HTTP/1.1 200"), "{out}");
    serde_json::from_str(out.split("\r\n\r\n").nth(1)?).ok()
}

async fn connect(addr: &str) -> Ws {
    let sock = TcpStream::connect(addr).await.unwrap();
    let (ws, _) = tokio_tungstenite::client_async(format!("ws://{addr}/"), sock)
        .await
        .unwrap();
    ws
}

async fn send(ws: &mut Ws, v: Value) {
    ws.send(Message::text(v.to_string())).await.unwrap();
}

/// The next JSON text frame, or None when the socket closes.
async fn recv(ws: &mut Ws) -> Option<Value> {
    loop {
        let msg = tokio::time::timeout(Duration::from_secs(30), ws.next())
            .await
            .expect("timed out waiting for a frame");
        match msg {
            Some(Ok(Message::Text(t))) => return Some(serde_json::from_str(&t).unwrap()),
            Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return None,
            Some(Ok(_)) => continue,
        }
    }
}

async fn hello(ws: &mut Ws, resume_after: u64) -> Value {
    send(
        ws,
        json!({"hello": {"protocol": 1, "client": "test/0", "resume_after": resume_after, "future": true}}),
    )
    .await;
    let w = recv(ws).await.unwrap();
    w["welcome"].clone()
}

/// Envelopes until one with `event == name`, returning everything seen.
async fn until(ws: &mut Ws, name: &str) -> Vec<Value> {
    let mut seen = Vec::new();
    loop {
        let env = recv(ws)
            .await
            .unwrap_or_else(|| panic!("closed before {name}: {seen:?}"));
        let done = env["event"] == name;
        seen.push(env);
        if done {
            return seen;
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn handshake_then_a_turn() {
    let f = frog(vec![text_reply("hello there")], &[]).await;
    let mut ws = connect(&f.addr).await;
    let w = hello(&mut ws, 0).await;
    assert_eq!(w["protocol"], 1);
    assert!(w["engine"].as_str().unwrap().starts_with("frog/"), "{w}");
    assert!(w["last_seq"].is_u64(), "{w}");
    // Unknown ops and unknown fields are skipped, not fatal.
    send(&mut ws, json!({"op": "from_the_future", "x": 1})).await;
    send(
        &mut ws,
        json!({"op": "submit", "text": "hi", "mood": "sunny"}),
    )
    .await;
    let seen = until(&mut ws, "turn_ended").await;
    let text: String = seen
        .iter()
        .filter(|e| e["event"] == "item_delta")
        .filter_map(|e| e["delta"]["text"].as_str())
        .collect();
    assert_eq!(text, "hello there");
    assert_eq!(
        seen.last().unwrap()["reason"]["type"],
        "complete",
        "{seen:?}"
    );
}

/// A restored container is a new process whose engine counts from 1, while the gateway
/// resumes after the seqs it already has: everything sent from then on is numbered above them.
#[tokio::test(flavor = "multi_thread")]
async fn a_peer_resuming_past_this_process_gets_seqs_above_it() {
    let f = frog(vec![text_reply("again")], &[]).await;
    let mut ws = connect(&f.addr).await;
    let w = hello(&mut ws, 500).await;
    assert_eq!(w["last_seq"], 500, "{w}");
    send(&mut ws, json!({"op": "submit", "text": "hi"})).await;
    let seen = until(&mut ws, "turn_ended").await;
    assert!(
        seen.iter().any(|e| e["event"] == "turn_started"),
        "{seen:?}"
    );
    let seqs: Vec<u64> = seen.iter().filter_map(|e| e["seq"].as_u64()).collect();
    assert!(seqs.iter().all(|&s| s > 500), "{seqs:?}");
    assert!(seqs.windows(2).all(|p| p[0] < p[1]), "{seqs:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn refuses_other_protocols_with_4001() {
    let f = frog(vec![], &[]).await;
    let mut ws = connect(&f.addr).await;
    send(
        &mut ws,
        json!({"hello": {"protocol": 0, "client": "old/0"}}),
    )
    .await;
    let r = recv(&mut ws).await.unwrap();
    assert_eq!(r["refused"]["reason"], "protocol");
    assert_eq!(r["refused"]["min"], 1);
    assert_eq!(r["refused"]["max"], 1);
    assert!(r["refused"]["upgrade"].is_string());
    let code = loop {
        match ws.next().await {
            Some(Ok(Message::Close(Some(frame)))) => break u16::from(frame.code),
            Some(Ok(_)) => continue,
            other => panic!("expected a close frame, got {other:?}"),
        }
    };
    assert_eq!(code, 4001);
    // The engine is still there for a peer that speaks protocol 1.
    let mut ws = connect(&f.addr).await;
    assert_eq!(hello(&mut ws, 0).await["protocol"], 1);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_peer_replaces_the_old_and_can_resume() {
    let f = frog(vec![text_reply("first"), text_reply("second")], &[]).await;
    let mut a = connect(&f.addr).await;
    hello(&mut a, 0).await;
    send(&mut a, json!({"op": "submit", "text": "one"})).await;
    let seen = until(&mut a, "turn_ended").await;
    let ended = seen.last().unwrap()["seq"].as_u64().unwrap();

    let mut b = connect(&f.addr).await;
    let w = hello(&mut b, 0).await;
    assert!(w["last_seq"].as_u64().unwrap() >= ended, "{w}");
    assert_eq!(w["session"], seen[0]["session"]);
    // The old peer is closed.
    while recv(&mut a).await.is_some() {}
    // resume_after 0 replays the durable envelopes in order, plus the latest status at its
    // own seq; the first durable one is the turn.
    let replay = until(&mut b, "turn_ended").await;
    let first = replay.iter().find(|e| e["event"] != "status").unwrap();
    assert_eq!(first["event"], "turn_started");
    assert!(replay.iter().filter(|e| e["event"] == "status").count() <= 1);
    assert!(
        replay
            .iter()
            .all(|e| e["event"] != "item_delta" || e["delta"]["type"] == "image_preview")
    );
    assert!(
        replay
            .windows(2)
            .all(|w| w[0]["seq"].as_u64() < w[1]["seq"].as_u64())
    );
    assert_eq!(replay.last().unwrap()["seq"].as_u64().unwrap(), ended);
    // The engine kept running: the new peer runs the next turn.
    send(&mut b, json!({"op": "submit", "text": "two"})).await;
    let seen = until(&mut b, "turn_ended").await;
    assert!(
        seen.iter().any(|e| e["delta"]["text"] == "second"),
        "{seen:?}"
    );

    // A peer resuming after everything gets only what's new.
    drop(b);
    let mut c = connect(&f.addr).await;
    let last = hello(&mut c, u64::MAX).await["last_seq"].as_u64().unwrap();
    send(&mut c, json!({"op": "submit", "text": "three"})).await;
    let seen = until(&mut c, "turn_ended").await;
    assert!(
        seen.iter().all(|e| e["seq"].as_u64().unwrap() > last),
        "{seen:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn ask_waits_for_the_peers_permission() {
    let bash = tool_reply(
        "Bash",
        json!({"command": "echo hi > made.txt && cat made.txt", "unsandboxed": true}),
    );
    let f = frog(vec![bash, text_reply("done")], &["--ask"]).await;
    let mut ws = connect(&f.addr).await;
    hello(&mut ws, 0).await;
    send(&mut ws, json!({"op": "submit", "text": "run it"})).await;
    let seen = until(&mut ws, "permission_request").await;
    let id = seen.last().unwrap()["id"].as_str().unwrap().to_string();
    send(
        &mut ws,
        json!({"op": "permission", "id": id, "decision": "allow"}),
    )
    .await;
    let seen = until(&mut ws, "turn_ended").await;
    let resolved = seen
        .iter()
        .find(|e| e["event"] == "permission_resolved")
        .expect("permission_resolved");
    assert_eq!(resolved["id"], id.as_str());
    assert_eq!(resolved["decision"], "allow");
    let out = seen
        .iter()
        .find(|e| e["event"] == "item_completed" && e["item"]["type"] == "tool_call")
        .expect("the tool ran");
    assert!(
        out["item"]["output"].as_str().unwrap().contains("hi"),
        "{out}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn a_peer_that_attaches_mid_ask_gets_the_ask() {
    let bash = tool_reply(
        "Bash",
        json!({"command": "echo hi > made.txt && cat made.txt", "unsandboxed": true}),
    );
    let f = frog(vec![bash, text_reply("done")], &["--ask"]).await;
    let mut a = connect(&f.addr).await;
    hello(&mut a, 0).await;
    send(&mut a, json!({"op": "submit", "text": "run it"})).await;
    let asked = until(&mut a, "permission_request").await;
    let ask = asked.last().unwrap().clone();

    // A reload, or another device: the ask is in the replay, in seq order, and answerable.
    let mut b = connect(&f.addr).await;
    hello(&mut b, 0).await;
    let replay = until(&mut b, "permission_request").await;
    assert_eq!(replay.last().unwrap()["id"], ask["id"]);
    assert!(
        replay
            .windows(2)
            .all(|w| w[0]["seq"].as_u64() < w[1]["seq"].as_u64()),
        "{replay:?}"
    );
    send(
        &mut b,
        json!({"op": "permission", "id": ask["id"], "decision": "allow"}),
    )
    .await;
    until(&mut b, "turn_ended").await;

    // Answered and finished: a later peer's replay has no open ask, and it does have the
    // engine's latest status (model and mode) though status isn't durable.
    let mut c = connect(&f.addr).await;
    hello(&mut c, 0).await;
    let replay = until(&mut c, "status").await;
    assert!(
        replay.iter().all(|e| e["event"] != "permission_request"),
        "{replay:?}"
    );
    assert!(replay.last().unwrap()["mode"].is_string(), "{replay:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn without_ask_headless_denies() {
    let bash = tool_reply(
        "Bash",
        json!({"command": "echo hi > made.txt && cat made.txt", "unsandboxed": true}),
    );
    let f = frog(vec![bash, text_reply("done")], &[]).await;
    let mut ws = connect(&f.addr).await;
    hello(&mut ws, 0).await;
    send(&mut ws, json!({"op": "submit", "text": "run it"})).await;
    let seen = until(&mut ws, "turn_ended").await;
    assert!(
        seen.iter().all(|e| e["event"] != "permission_request"),
        "{seen:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn git_credential_helper_asks_the_gateway() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let gateway = format!("http://{}", listener.local_addr().unwrap());
    let asked = Arc::new(Mutex::new(Vec::new()));
    {
        let asked = asked.clone();
        tokio::spawn(async move {
            loop {
                let (mut sock, _) = listener.accept().await.unwrap();
                let (head, _) = read_request(&mut sock).await.unwrap();
                asked
                    .lock()
                    .unwrap()
                    .push(head.lines().next().unwrap_or("").to_string());
                let body = json!({"username": "x-access-token", "password": "ghs_secret", "expires": "2026-10-28T20:00:00Z"});
                respond(&mut sock, "application/json", &body.to_string()).await;
            }
        });
    }
    let home = temp_dir("git");
    // As git runs it, through the environment --git-credential-gateway sets up.
    let out = tokio::process::Command::new("git")
        .args(["credential", "fill"])
        .env("HOME", &home)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("FROG_GIT_CREDENTIAL_GATEWAY", &gateway)
        .env("GIT_CONFIG_COUNT", "2")
        .env("GIT_CONFIG_KEY_0", "credential.helper")
        .env("GIT_CONFIG_VALUE_0", "")
        .env("GIT_CONFIG_KEY_1", "credential.helper")
        .env(
            "GIT_CONFIG_VALUE_1",
            format!("!'{}' git-credential", env!("CARGO_BIN_EXE_frog")),
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut out = out;
    out.stdin
        .take()
        .unwrap()
        .write_all(b"protocol=https\nhost=github.com\npath=muni-works/frog.git\n\n")
        .await
        .unwrap();
    let out = out.wait_with_output().await.unwrap();
    let stdout = String::from_utf8(out.stdout).unwrap();
    assert!(out.status.success(), "{stdout}");
    assert!(stdout.contains("username=x-access-token\n"), "{stdout}");
    assert!(stdout.contains("password=ghs_secret\n"), "{stdout}");
    let asked = asked.lock().unwrap().clone();
    assert_eq!(
        asked,
        ["GET /internal/git-credential?host=github.com HTTP/1.1"]
    );
    // Nothing landed on disk.
    assert!(!home.join(".git-credentials").exists());
}

#[tokio::test(flavor = "multi_thread")]
async fn git_credential_gateway_flag_installs_the_helper() {
    // A turn's shell sees git configured with frog as the only credential helper.
    let bash = tool_reply(
        "Bash",
        json!({"command": "git config --get-all credential.helper; echo \"gw=$FROG_GIT_CREDENTIAL_GATEWAY\"", "unsandboxed": true}),
    );
    let f = frog(
        vec![bash, text_reply("done")],
        &[
            "--yolo",
            "--git-credential-gateway",
            "http://gateway.internal/",
        ],
    )
    .await;
    let mut ws = connect(&f.addr).await;
    hello(&mut ws, 0).await;
    send(&mut ws, json!({"op": "submit", "text": "check"})).await;
    let seen = until(&mut ws, "turn_ended").await;
    let out = seen
        .iter()
        .find(|e| e["event"] == "item_completed" && e["item"]["type"] == "tool_call")
        .expect("the tool ran");
    let out = out["item"]["output"].as_str().unwrap();
    assert!(out.contains("git-credential"), "{out}");
    assert!(out.contains("gw=http://gateway.internal"), "{out}");
}

#[tokio::test(flavor = "multi_thread")]
async fn without_a_model_the_gateway_gets_frog_clouds() {
    // The gateway sets FROG_MODEL only when the session picked a model.
    let f = frog_on(vec![text_reply("hi")], None, &[]).await;
    let mut ws = connect(&f.addr).await;
    hello(&mut ws, 0).await;
    send(&mut ws, json!({"op": "submit", "text": "hi"})).await;
    until(&mut ws, "turn_ended").await;
    let models = f.models.lock().unwrap().clone();
    assert!(!models.is_empty());
    assert!(
        models.iter().all(|(m, _)| m == "qwen3-coder-next"),
        "{models:?}"
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn switching_cloud_models_keeps_frog_clouds_base_and_key() {
    // Nothing sandbox-specific: a mid-session switch goes where the first model did, with the
    // same key.
    let f = frog(vec![text_reply("one"), text_reply("two")], &[]).await;
    let mut ws = connect(&f.addr).await;
    hello(&mut ws, 0).await;
    send(&mut ws, json!({"op": "submit", "text": "first"})).await;
    until(&mut ws, "turn_ended").await;
    send(&mut ws, json!({"op": "set_model", "spec": "cloud/other"})).await;
    until(&mut ws, "model_changed").await;
    send(&mut ws, json!({"op": "submit", "text": "second"})).await;
    until(&mut ws, "turn_ended").await;
    let models = f.models.lock().unwrap().clone();
    let bearer = format!("Bearer {PLACEHOLDER_KEY}");
    assert!(models.iter().any(|(m, _)| m == "scripted"), "{models:?}");
    assert!(models.iter().any(|(m, _)| m == "other"), "{models:?}");
    assert!(models.iter().all(|(_, a)| *a == bearer), "{models:?}");
}
