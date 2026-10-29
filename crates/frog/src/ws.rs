//! `--serve-ws <addr>`: the `--serve` protocol over a websocket, for Frog Cloud's gateway.
//! See docs/plans/2026-10-28-frog-cloud-wire-contract.md §2 and §3.
//!
//! One peer at a time; a new one replaces the old, and the engine keeps running between them.
//! Each side's first frame is the handshake (`hello`, then `welcome` or `refused`); after it,
//! one `Op` or `Envelope` per text frame. `GET /health` on the same port answers
//! `{"ok":true,"protocol":1}`.

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

#[derive(Default)]
struct State {
    session: String,
    last_seq: u64,
    /// Durable envelopes this process has emitted, as sent, for a peer's `resume_after`.
    durable: Vec<(u64, String)>,
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

pub async fn serve(mut h: Handle, addr: &str) -> Result<()> {
    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding {addr}"))?;
    eprintln!("frog serving websocket on {}", listener.local_addr()?);
    let state: Arc<Mutex<State>> = Default::default();
    let ops = h.ops.clone();
    drop(h.ops);
    {
        let (state, ops) = (state.clone(), ops.clone());
        tokio::spawn(async move {
            loop {
                let (sock, peer) = match listener.accept().await {
                    Ok(c) => c,
                    Err(e) => {
                        eprintln!("accept: {e}");
                        continue;
                    }
                };
                let (state, ops) = (state.clone(), ops.clone());
                tokio::spawn(async move {
                    if let Err(e) = conn(sock, state, ops).await {
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
    while let Some(env) = h.events.recv().await {
        let text = serde_json::to_string(&env)?;
        let mut s = state.lock().unwrap();
        s.session.clone_from(&env.session);
        s.last_seq = env.seq;
        if env.event.is_durable() {
            s.durable.push((env.seq, text.clone()));
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
) -> Result<()> {
    if let Some(path) = plain_get(&sock).await? {
        return health(sock, &path).await;
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

/// The request path, when the connection is a plain HTTP GET rather than a websocket upgrade.
/// Only peeks, so an upgrade's bytes are still there for the handshake.
async fn plain_get(sock: &TcpStream) -> Result<Option<String>> {
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
    let upgrade = head.lines().skip(1).any(|l| {
        l.split_once(':').is_some_and(|(k, v)| {
            k.trim().eq_ignore_ascii_case("upgrade") && v.trim().eq_ignore_ascii_case("websocket")
        })
    });
    if upgrade {
        return Ok(None);
    }
    let mut first = head.lines().next().unwrap_or("").split_whitespace();
    let (method, path) = (first.next().unwrap_or(""), first.next().unwrap_or(""));
    Ok(Some(if method == "GET" {
        path.to_string()
    } else {
        String::new()
    }))
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
