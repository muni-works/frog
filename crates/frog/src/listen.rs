//! `--listen`: one turn per HTTP request, for clients that can't keep a stdio pipe open (Siri,
//! via the iOS app). Small on purpose: no HTTP library, HTTP/1.1 only, one endpoint.
//!
//! ```text
//! POST /v1/turn
//! Authorization: Bearer <FROG_LISTEN_TOKEN>
//! {"text": "why is the garage cold?", "session": "<optional id>", "model": "<optional profile>"}
//! ```
//!
//! The reply is `application/x-ndjson`: the engine's event envelopes, exactly as `--serve`
//! prints them, ending after the turn's `idle`. Then the connection closes. Each request gets
//! its own engine, so a dropped client never leaves a turn holding another one up. A client that
//! hangs up early (Siri's time ran out) doesn't stop the turn: it runs to the end and is saved in
//! the session log like any other, and `GET /v1/session/<id>/answer` reads it from there:
//! `{"done": false}` while it runs, then `{"done": true, "text": "…"}`. Nobody can
//! answer a permission prompt here, so anything that would ask is denied (`can_ask: false`);
//! run with `--yolo` only when every tool is read-only, as with a chat plus read-only MCP.

use anyhow::{Context, Result};
use frog_engine::{Event, Op, Options};
use serde::Deserialize;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

/// Everything a request's engine starts from, minus the session.
pub struct Template {
    /// Where session logs live, for reading a finished answer back.
    pub store: std::path::PathBuf,
    pub make: Box<dyn Fn(Option<String>, Option<String>) -> Result<Options> + Send + Sync>,
}

#[derive(Deserialize)]
struct Turn {
    text: String,
    #[serde(default)]
    session: Option<String>,
    #[serde(default)]
    model: Option<String>,
}

const MAX_BODY: usize = 64 << 10;
/// The whole request head, read before the token is checked.
const MAX_HEAD: u64 = 16 << 10;

pub async fn run(addr: &str, token: String, t: Template) -> Result<()> {
    anyhow::ensure!(
        token.len() >= 16,
        "FROG_LISTEN_TOKEN must be set, 16 characters or more"
    );
    let listener = TcpListener::bind(addr)
        .await
        .with_context(|| format!("binding {addr}"))?;
    eprintln!("frog listening on {}", listener.local_addr()?);
    let t = Arc::new(t);
    let token = Arc::new(token);
    loop {
        let (sock, peer) = listener.accept().await?;
        let (t, token) = (t.clone(), token.clone());
        tokio::spawn(async move {
            if let Err(e) = handle(sock, &token, &t).await {
                eprintln!("{peer}: {e:#}");
            }
        });
    }
}

/// A parsed request head: method, path, the bearer token and the body length.
#[derive(Debug, PartialEq)]
struct Head {
    method: String,
    path: String,
    bearer: Option<String>,
    length: usize,
}

fn parse_head(lines: &[String]) -> Option<Head> {
    let mut first = lines.first()?.split(' ');
    let method = first.next()?.to_string();
    let path = first.next()?.to_string();
    let mut bearer = None;
    let mut length = 0;
    for l in &lines[1..] {
        let Some((k, v)) = l.split_once(':') else {
            continue;
        };
        let v = v.trim();
        match k.trim().to_ascii_lowercase().as_str() {
            "authorization" => bearer = v.strip_prefix("Bearer ").map(str::to_string),
            "content-length" => length = v.parse().ok()?,
            _ => {}
        }
    }
    Some(Head {
        method,
        path,
        bearer,
        length,
    })
}

/// The latest turn's answer in session `id`: its last message, once the turn has ended.
fn answer(store: &std::path::Path, id: &str) -> Option<serde_json::Value> {
    if !valid_id(id) {
        return None;
    }
    let events = frog_engine::session::events_after(store, id, 0).ok()?;
    Some(last_answer(events.into_iter().map(|e| e.event)))
}

/// A session id that can't step out of the store: letters, digits, `-` and `_`.
fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn last_answer(events: impl Iterator<Item = Event>) -> serde_json::Value {
    let (mut text, mut done) = (String::new(), false);
    for e in events {
        match e {
            Event::TurnStarted { .. } => (text, done) = (String::new(), false),
            Event::ItemCompleted {
                item: frog_engine::Item::Message { text: t, .. },
                ..
            } => text = t,
            Event::TurnEnded { .. } => done = true,
            _ => {}
        }
    }
    if done {
        serde_json::json!({ "done": true, "text": text })
    } else {
        serde_json::json!({ "done": false })
    }
}

/// Compare without leaking how much of the token matched.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

async fn respond(sock: &mut TcpStream, status: &str, body: &str) -> Result<()> {
    let msg = format!(
        "HTTP/1.1 {status}\r\ncontent-type: text/plain\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
        body.len()
    );
    sock.write_all(msg.as_bytes()).await?;
    Ok(())
}

async fn handle(mut sock: TcpStream, token: &str, t: &Template) -> Result<()> {
    let mut reader = BufReader::new(&mut sock);
    let mut lines = Vec::new();
    let mut left = MAX_HEAD;
    loop {
        let mut l = String::new();
        let n = (&mut reader).take(left).read_line(&mut l).await?;
        // Closed, too many lines, or out of budget before the line ended.
        if n == 0 || lines.len() > 64 || !l.ends_with('\n') {
            return Ok(());
        }
        left -= n as u64;
        let l = l.trim_end().to_string();
        if l.is_empty() {
            break;
        }
        lines.push(l);
    }
    let Some(head) = parse_head(&lines) else {
        return respond(&mut sock, "400 Bad Request", "bad request").await;
    };
    if !head.bearer.as_deref().is_some_and(|b| same(b, token)) {
        return respond(&mut sock, "401 Unauthorized", "unauthorized").await;
    }
    if head.method == "GET" && head.path == "/v1/health" {
        return respond(&mut sock, "200 OK", "ok").await;
    }
    if let Some(id) = head
        .path
        .strip_prefix("/v1/session/")
        .and_then(|p| p.strip_suffix("/answer"))
        .filter(|_| head.method == "GET")
    {
        let body = match answer(&t.store, id) {
            Some(v) => v.to_string(),
            None => return respond(&mut sock, "404 Not Found", "no such session").await,
        };
        let msg = format!(
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
            body.len()
        );
        sock.write_all(msg.as_bytes()).await?;
        return Ok(());
    }
    if head.method != "POST" || head.path != "/v1/turn" {
        return respond(&mut sock, "404 Not Found", "not found").await;
    }
    if head.length > MAX_BODY {
        return respond(&mut sock, "413 Payload Too Large", "too large").await;
    }
    let mut body = vec![0; head.length];
    reader.read_exact(&mut body).await?;
    let turn: Turn = match serde_json::from_slice::<Turn>(&body) {
        Ok(t) if !t.text.trim().is_empty() => t,
        _ => return respond(&mut sock, "400 Bad Request", "want {\"text\": ...}").await,
    };
    if turn.session.as_deref().is_some_and(|id| !valid_id(id)) {
        return respond(&mut sock, "400 Bad Request", "bad session id").await;
    }
    let mut h = match (t.make)(turn.session, turn.model) {
        Ok(opts) => match frog_engine::spawn_checked(opts).await {
            Ok(h) => h,
            Err(e) => {
                return respond(&mut sock, "500 Internal Server Error", &format!("{e:#}")).await;
            }
        },
        Err(e) => return respond(&mut sock, "500 Internal Server Error", &format!("{e:#}")).await,
    };
    sock.write_all(
        b"HTTP/1.1 200 OK\r\ncontent-type: application/x-ndjson\r\nconnection: close\r\n\r\n",
    )
    .await?;
    h.ops.send(Op::Submit {
        text: turn.text,
        images: Vec::new(),
        more: Vec::new(),
    })?;
    h.ops.send(Op::Shutdown)?;
    let (mut ended, mut gone) = (false, false);
    while let Some(env) = h.events.recv().await {
        if !gone {
            let mut line = serde_json::to_vec(&env)?;
            line.push(b'\n');
            gone = sock.write_all(&line).await.is_err();
        }
        match env.event {
            Event::TurnEnded { .. } => ended = true,
            Event::Idle if ended => break,
            _ => {}
        }
    }
    let _ = sock.shutdown().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lines(s: &[&str]) -> Vec<String> {
        s.iter().map(|l| l.to_string()).collect()
    }

    #[test]
    fn reads_the_head() {
        let h = parse_head(&lines(&[
            "POST /v1/turn HTTP/1.1",
            "Authorization: Bearer abc",
            "Content-Length: 12",
        ]))
        .unwrap();
        assert_eq!(
            h,
            Head {
                method: "POST".into(),
                path: "/v1/turn".into(),
                bearer: Some("abc".into()),
                length: 12
            }
        );
    }

    #[test]
    fn no_token_no_bearer() {
        let h = parse_head(&lines(&[
            "POST /v1/turn HTTP/1.1",
            "authorization: Basic abc",
        ]))
        .unwrap();
        assert_eq!(h.bearer, None);
        assert!(parse_head(&lines(&["POST /x", "content-length: nope"])).is_none());
    }

    #[test]
    fn session_ids_stay_in_the_store() {
        assert!(valid_id("2026-11-13_abc"));
        for bad in ["", "../etc", "a/b", "..", "a.b", "a\\b"] {
            assert!(!valid_id(bad), "{bad}");
        }
    }

    /// A head longer than MAX_HEAD, with no newline, is dropped without a reply.
    #[tokio::test]
    async fn long_head_lines_are_cut_off() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (sock, _) = listener.accept().await.unwrap();
            let t = Template {
                store: std::env::temp_dir(),
                make: Box::new(|_, _| anyhow::bail!("no engine in tests")),
            };
            handle(sock, "0123456789abcdef", &t).await
        });
        let mut c = TcpStream::connect(addr).await.unwrap();
        let junk = vec![b'a'; MAX_HEAD as usize + 1024];
        // The server may hang up mid-write; that's the point.
        let _ = c.write_all(&junk).await;
        let done = tokio::time::timeout(std::time::Duration::from_secs(5), server).await;
        assert!(done.is_ok(), "server kept reading an endless header line");
        let mut reply = Vec::new();
        let _ = c.read_to_end(&mut reply).await;
        assert!(reply.is_empty());
    }

    #[test]
    fn compares_tokens() {
        assert!(same("abcdef", "abcdef"));
        assert!(!same("abcdef", "abcdeg"));
        assert!(!same("abc", "abcdef"));
    }

    #[test]
    fn answer_is_the_last_turns_last_message() {
        let ev = |v: serde_json::Value| serde_json::from_value::<Event>(v).unwrap();
        let msg = |t: &str| {
            ev(
                serde_json::json!({"event":"item_completed","id":"m","item":{"type":"message","text":t}}),
            )
        };
        let started = || ev(serde_json::json!({"event":"turn_started","turn":1,"input":"q"}));
        let ended = || Event::TurnEnded {
            turn: 1,
            reason: frog_engine::EndReason::Complete,
            usage: Default::default(),
        };
        let done = last_answer(
            [
                started(),
                msg("first"),
                ended(),
                started(),
                msg("a"),
                msg("b"),
                ended(),
            ]
            .into_iter(),
        );
        assert_eq!(done, serde_json::json!({"done": true, "text": "b"}));
        let running =
            last_answer([started(), msg("a"), ended(), started(), msg("half")].into_iter());
        assert_eq!(running, serde_json::json!({"done": false}));
    }
}
