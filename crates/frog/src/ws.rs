//! `--serve-ws <addr>`: the `--serve` protocol over a websocket, for Frog Cloud's gateway.
//! See docs/plans/2026-10-28-frog-cloud-wire-contract.md §2 and §3.
//!
//! One peer at a time; a new one replaces the old, and the engine keeps running between them.
//! Each side's first frame is the handshake (`hello`, then `welcome` or `refused`); after it,
//! one `Op` or `Envelope` per text frame. `GET /health` on the same port answers
//! `{"ok":true,"protocol":1}`.
//!
//! Auth: with `FROG_SERVE_WS_TOKEN` set, a peer must present it, either as
//! `Authorization: Bearer <token>` on the upgrade request or as `"token"` in its `hello`;
//! otherwise it gets `{"refused":{"reason":"auth"}}` and close code 4003. Without a token,
//! frog only binds a loopback address, unless `FROG_SERVE_WS_INSECURE=1`. `/health` is open.

use anyhow::{Context, Result};
use frog_engine::{Event, Handle, Op};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use tokio::io::AsyncWriteExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

pub const PROTOCOL: u64 = 1;
const UPGRADE: &str = "https://frog.toys/download";
/// The largest integer a JSON number keeps exactly in JavaScript (2^53 - 1).
const MAX_SAFE_SEQ: u64 = (1 << 53) - 1;
/// How many bytes of durable envelopes to keep for `resume_after`. Past it the oldest go: a
/// peer resuming from before them gets what's left (the gateway keeps its own history).
const DURABLE_BUDGET: usize = 16 << 20;
pub const TOKEN_ENV: &str = "FROG_SERVE_WS_TOKEN";
pub const INSECURE_ENV: &str = "FROG_SERVE_WS_INSECURE";

#[derive(Default)]
struct State {
    session: String,
    /// The last seq sent to a peer (after `offset`).
    last_seq: u64,
    /// Added to the engine's seq on the wire. A restored container starts a new process whose
    /// engine counts from 1 again, while the gateway still holds the old seqs; a peer that
    /// resumes past anything this process sent moves the numbering above what it has, since a
    /// client drops anything at or below the last seq it has seen.
    offset: u64,
    /// Durable envelopes this process has emitted, as sent, for a peer's `resume_after`.
    durable: std::collections::VecDeque<(u64, String)>,
    /// Bytes in `durable`, held under `DURABLE_BUDGET`.
    durable_bytes: usize,
    /// Asks still waiting on an answer (permission requests, questions, elicitations), as
    /// sent. They're ephemeral, so `durable` never has them, but a peer that attaches
    /// mid-ask has to see them to answer. Cleared by their resolution or the turn's end.
    open: Vec<(String, u64, String)>,
    /// The latest `status` (model, mode, context), as sent: state, not history, so it's
    /// ephemeral too, but a peer that attaches between turns needs it.
    status: Option<(u64, String)>,
    /// The current peer's outbox, and which connection it is.
    peer: Option<(u64, mpsc::UnboundedSender<String>)>,
    next_peer: u64,
}

impl State {
    fn record_durable(&mut self, seq: u64, text: String, budget: usize) {
        self.durable_bytes += text.len();
        self.durable.push_back((seq, text));
        while self.durable_bytes > budget {
            let Some((_, old)) = self.durable.pop_front() else {
                break;
            };
            self.durable_bytes -= old.len();
        }
    }
}

/// Refuse to listen beyond loopback without a token, unless told to.
pub fn check_bind(addr: &str, token: Option<&str>, insecure: bool) -> Result<()> {
    if let Some(t) = token {
        anyhow::ensure!(t.len() >= 16, "{TOKEN_ENV} must be 16 characters or more");
        return Ok(());
    }
    let loopback = addr
        .parse::<std::net::SocketAddr>()
        .is_ok_and(|a| a.ip().is_loopback())
        || addr.starts_with("localhost:");
    anyhow::ensure!(
        loopback || insecure,
        "--serve-ws on {addr} needs {TOKEN_ENV} (or bind 127.0.0.1, or {INSECURE_ENV}=1)"
    );
    Ok(())
}

/// Compare without leaking how much of the token matched.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

pub async fn serve(mut h: Handle, addr: &str, token: Option<String>) -> Result<()> {
    let token: Arc<Option<String>> = Arc::new(token);
    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding {addr}"))?;
    eprintln!("frog serving websocket on {}", listener.local_addr()?);
    let state: Arc<Mutex<State>> = Default::default();
    let ops = h.ops.clone();
    drop(h.ops);
    {
        let (state, ops, token) = (state.clone(), ops.clone(), token.clone());
        tokio::spawn(async move {
            loop {
                let (sock, peer) = match listener.accept().await {
                    Ok(c) => c,
                    Err(e) => {
                        eprintln!("accept: {e}");
                        continue;
                    }
                };
                let (state, ops, token) = (state.clone(), ops.clone(), token.clone());
                tokio::spawn(async move {
                    if let Err(e) = conn(sock, state, ops, token.as_deref()).await {
                        eprintln!("{peer}: {e:#}");
                    }
                });
            }
        });
    }
    {
        let ops = ops.clone();
        tokio::spawn(async move {
            let _ = tokio::signal::ctrl_c().await;
            let _ = ops.send(Op::Shutdown);
        });
    }
    while let Some(mut env) = h.events.recv().await {
        let mut s = state.lock().unwrap();
        env.seq += s.offset;
        let text = serde_json::to_string(&env)?;
        s.session.clone_from(&env.session);
        s.last_seq = env.seq;
        if env.event.is_durable() {
            s.record_durable(env.seq, text.clone(), DURABLE_BUDGET);
        }
        match &env.event {
            Event::PermissionRequest { id, .. }
            | Event::Question { id, .. }
            | Event::Elicitation { id, .. } => s.open.push((id.clone(), env.seq, text.clone())),
            Event::PermissionResolved { id, .. }
            | Event::QuestionResolved { id, .. }
            | Event::ElicitationDone { id } => s.open.retain(|(open, _, _)| open != id),
            Event::TurnEnded { .. } => s.open.clear(),
            Event::Status(_) => s.status = Some((env.seq, text.clone())),
            _ => {}
        }
        if let Some((_, tx)) = &s.peer
            && tx.send(text).is_err()
        {
            s.peer = None;
        }
    }
    Ok(())
}

async fn conn(
    sock: TcpStream,
    state: Arc<Mutex<State>>,
    ops: mpsc::UnboundedSender<Op>,
    token: Option<&str>,
) -> Result<()> {
    let head = peek_head(&sock).await?;
    if !head.upgrade {
        return health(sock, &head.path).await;
    }
    let mut ws = tokio_tungstenite::accept_async(sock).await?;
    let hello = loop {
        match ws.next().await {
            Some(Ok(Message::Text(t))) => break serde_json::from_str::<Value>(&t).ok(),
            Some(Ok(Message::Ping(_) | Message::Pong(_))) => continue,
            _ => return Ok(()),
        }
    };
    let hello = hello.as_ref().and_then(|v| v.get("hello"));
    if !authorized(token, head.bearer.as_deref(), hello) {
        let refused = json!({"refused": {"reason": "auth"}});
        ws.send(Message::text(refused.to_string())).await?;
        ws.close(Some(CloseFrame {
            code: CloseCode::Library(4003),
            reason: "auth".into(),
        }))
        .await?;
        return Ok(());
    }
    let protocol = hello
        .and_then(|h| h.get("protocol"))
        .and_then(Value::as_u64);
    if protocol != Some(PROTOCOL) {
        let refused = json!({"refused": {
            "reason": "protocol", "min": PROTOCOL, "max": PROTOCOL, "upgrade": UPGRADE,
        }});
        ws.send(Message::text(refused.to_string())).await?;
        ws.close(Some(CloseFrame {
            code: CloseCode::Library(4001),
            reason: "protocol".into(),
        }))
        .await?;
        return Ok(());
    }
    let after = hello
        .and_then(|h| h.get("resume_after"))
        .and_then(Value::as_u64)
        .unwrap_or(0);

    // Welcome and the replay go into the outbox under the same lock that makes it the peer,
    // so nothing live slips in between or ahead.
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let me = {
        let mut s = state.lock().unwrap();
        // Past anything a JS client can hold (u64::MAX: "only what's new") is no real seq.
        if after > s.last_seq && after <= MAX_SAFE_SEQ {
            s.offset += after - s.last_seq;
            s.last_seq = after;
        }
        let welcome = json!({"welcome": {
            "protocol": PROTOCOL,
            "session": s.session,
            "engine": concat!("frog/", env!("CARGO_PKG_VERSION")),
            "last_seq": s.last_seq,
        }});
        let _ = tx.send(welcome.to_string());
        // Open asks go in at their own seq, so the replay stays in order: a client drops
        // anything at or below the last seq it has seen.
        let mut replay: Vec<(u64, &String)> = s.durable.iter().map(|(seq, t)| (*seq, t)).collect();
        replay.extend(s.open.iter().map(|(_, seq, t)| (*seq, t)));
        replay.extend(s.status.iter().map(|(seq, t)| (*seq, t)));
        replay.sort_by_key(|(seq, _)| *seq);
        for (_, text) in replay.into_iter().filter(|(seq, _)| *seq > after) {
            let _ = tx.send(text.clone());
        }
        s.next_peer += 1;
        // Dropping the old peer's outbox closes its socket.
        s.peer = Some((s.next_peer, tx));
        s.next_peer
    };
    let (mut sink, mut stream) = ws.split();
    let writer = tokio::spawn(async move {
        while let Some(text) = rx.recv().await {
            if sink.send(Message::text(text)).await.is_err() {
                return;
            }
        }
        let _ = sink.send(Message::Close(None)).await;
    });
    let current = || matches!(&state.lock().unwrap().peer, Some((id, _)) if *id == me);
    while let Some(Ok(msg)) = stream.next().await {
        let Message::Text(text) = msg else {
            if msg.is_close() {
                break;
            }
            continue;
        };
        if !current() {
            break;
        }
        // Unknown ops (a newer client) and malformed frames are skipped, never fatal.
        match serde_json::from_str::<Op>(&text) {
            Ok(op) => {
                if ops.send(op).is_err() {
                    break;
                }
            }
            Err(e) => eprintln!("skipped op: {e}"),
        }
    }
    {
        let mut s = state.lock().unwrap();
        if matches!(&s.peer, Some((id, _)) if *id == me) {
            s.peer = None;
        }
    }
    let _ = writer.await;
    Ok(())
}

/// Whether a peer may in: no token configured, or it sent the token on the upgrade request
/// or in its hello.
fn authorized(token: Option<&str>, bearer: Option<&str>, hello: Option<&Value>) -> bool {
    let Some(token) = token else {
        return true;
    };
    let in_hello = hello.and_then(|h| h.get("token")).and_then(Value::as_str);
    [bearer, in_hello]
        .into_iter()
        .flatten()
        .any(|t| same(t, token))
}

struct Head {
    /// A websocket upgrade, not a plain request.
    upgrade: bool,
    /// The path of a plain GET (empty for other methods).
    path: String,
    bearer: Option<String>,
}

/// What the request head says. Only peeks, so an upgrade's bytes are still there for the
/// handshake.
async fn peek_head(sock: &TcpStream) -> Result<Head> {
    let mut buf = vec![0u8; 8192];
    let head = loop {
        let n = sock.peek(&mut buf).await?;
        let seen = &buf[..n];
        if let Some(end) = seen.windows(4).position(|w| w == b"\r\n\r\n") {
            break String::from_utf8_lossy(&seen[..end]).into_owned();
        }
        anyhow::ensure!(n < buf.len(), "request head too large");
        if n == 0 {
            anyhow::bail!("closed before a request");
        }
        // Not all of the head has arrived yet.
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    };
    Ok(parse_head(&head))
}

fn parse_head(head: &str) -> Head {
    let header = |name: &str| {
        head.lines().skip(1).find_map(|l| {
            let (k, v) = l.split_once(':')?;
            k.trim().eq_ignore_ascii_case(name).then(|| v.trim())
        })
    };
    let upgrade = header("upgrade").is_some_and(|v| v.eq_ignore_ascii_case("websocket"));
    let bearer = header("authorization")
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::to_string);
    let mut first = head.lines().next().unwrap_or("").split_whitespace();
    let (method, path) = (first.next().unwrap_or(""), first.next().unwrap_or(""));
    Head {
        upgrade,
        path: if method == "GET" {
            path.to_string()
        } else {
            String::new()
        },
        bearer,
    }
}

async fn health(mut sock: TcpStream, path: &str) -> Result<()> {
    let (status, body) = match path.split('?').next() {
        Some("/health") => (
            "200 OK",
            json!({"ok": true, "protocol": PROTOCOL}).to_string(),
        ),
        _ => ("404 Not Found", json!({"ok": false}).to_string()),
    };
    let resp = format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    sock.write_all(resp.as_bytes()).await?;
    sock.shutdown().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durable_stays_under_budget() {
        let mut s = State::default();
        for seq in 1..=100 {
            s.record_durable(seq, "x".repeat(10), 95);
        }
        assert_eq!(s.durable.len(), 9);
        assert_eq!(s.durable_bytes, 90);
        assert_eq!(s.durable.front().map(|(seq, _)| *seq), Some(92));
        assert_eq!(s.durable.back().map(|(seq, _)| *seq), Some(100));
    }

    #[test]
    fn auth_needs_the_token_somewhere() {
        let tok = Some("0123456789abcdef");
        let hello = |t: &str| json!({"protocol": 1, "token": t});
        assert!(authorized(None, None, None));
        assert!(!authorized(tok, None, Some(&json!({"protocol": 1}))));
        assert!(!authorized(tok, Some("nope"), Some(&hello("nope"))));
        assert!(authorized(tok, Some("0123456789abcdef"), None));
        assert!(authorized(tok, None, Some(&hello("0123456789abcdef"))));
    }

    #[test]
    fn head_reads_upgrade_and_bearer() {
        let h =
            parse_head("GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nAuthorization: Bearer sekrit");
        assert!(h.upgrade);
        assert_eq!(h.bearer.as_deref(), Some("sekrit"));
        let h = parse_head("GET /health?x HTTP/1.1\r\nHost: a");
        assert!(!h.upgrade && h.bearer.is_none());
        assert_eq!(h.path, "/health?x");
        assert_eq!(parse_head("POST /x HTTP/1.1").path, "");
    }

    #[test]
    fn no_token_only_on_loopback() {
        assert!(check_bind("127.0.0.1:7070", None, false).is_ok());
        assert!(check_bind("[::1]:7070", None, false).is_ok());
        assert!(check_bind("0.0.0.0:7070", None, false).is_err());
        assert!(check_bind("0.0.0.0:7070", None, true).is_ok());
        assert!(check_bind("0.0.0.0:7070", Some("0123456789abcdef"), false).is_ok());
        assert!(check_bind("0.0.0.0:7070", Some("short"), false).is_err());
    }

    /// End to end: a peer without the token is refused, one with it is welcomed.
    #[tokio::test]
    async fn refuses_a_peer_without_the_token() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let state: Arc<Mutex<State>> = Default::default();
        let (ops, _rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            loop {
                let (sock, _) = listener.accept().await.unwrap();
                let (state, ops) = (state.clone(), ops.clone());
                tokio::spawn(async move {
                    let _ = conn(sock, state, ops, Some("0123456789abcdef")).await;
                });
            }
        });
        let first = |hello: Value| async move {
            let tcp = TcpStream::connect(addr).await.unwrap();
            let (mut ws, _) = tokio_tungstenite::client_async(format!("ws://{addr}/"), tcp)
                .await
                .unwrap();
            ws.send(Message::text(json!({ "hello": hello }).to_string()))
                .await
                .unwrap();
            match ws.next().await {
                Some(Ok(Message::Text(t))) => serde_json::from_str::<Value>(&t).unwrap(),
                other => panic!("{other:?}"),
            }
        };
        let bad = first(json!({"protocol": 1})).await;
        assert_eq!(bad["refused"]["reason"], "auth");
        let good = first(json!({"protocol": 1, "token": "0123456789abcdef"})).await;
        assert!(good.get("welcome").is_some(), "{good}");
    }
}
