//! The local node pool: your own machines running `tang-llm serve`, paired once by the Mac app
//! (docs/node-protocol.md). The app writes the paired nodes to `~/.config/frog/nodes.json` and
//! their keys to the Keychain (account `node:<node_id>`); this module polls each node's
//! `GET /node`, keys models by `weights_hash`, and places each model call (section 7).

use crate::config::config_dir;
use crate::protocol::RanOn;
use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// The `/node` schema this engine reads.
pub const SCHEMA: u64 = 2;
/// This Mac's own tang (loopback: no key, no pin).
pub const LOCAL_BASE: &str = "http://127.0.0.1:8911";
/// How many hex digits of `weights_hash` a pooled model id carries.
pub const ID_LEN: usize = 12;

/// One paired node as the Mac app stores it.
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Paired {
    pub node_id: String,
    pub fingerprint: String,
    pub name: String,
    pub base_url: String,
    /// From the Keychain, never the file.
    #[serde(skip)]
    pub key: Option<String>,
}

#[derive(Deserialize, Default)]
struct StoreFile {
    #[serde(default)]
    nodes: Vec<Value>,
}

pub fn store_path() -> PathBuf {
    config_dir().join("nodes.json")
}

/// The paired nodes in a store file; entries missing a field are skipped, unknown fields
/// ignored. Keys come from `key` (the Keychain in production).
pub fn read_store(bytes: &[u8], key: &dyn Fn(&str) -> Option<String>) -> Vec<Paired> {
    let file: StoreFile = serde_json::from_slice(bytes).unwrap_or_default();
    file.nodes
        .into_iter()
        .filter_map(|v| serde_json::from_value::<Paired>(v).ok())
        .filter(|p| !p.node_id.is_empty() && !p.base_url.is_empty())
        .map(|mut p| {
            p.key = key(&p.node_id);
            p
        })
        .collect()
}

/// A model a node holds.
#[derive(Clone, Debug, PartialEq)]
pub struct NodeModel {
    /// What the node's `/v1/chat/completions` takes as `model`.
    pub id: String,
    pub weights_hash: String,
    pub quant: Option<String>,
    pub loaded: bool,
    pub context_window: Option<u64>,
}

impl NodeModel {
    /// The pooled id's hash part.
    pub fn short(&self) -> &str {
        &self.weights_hash[..self.weights_hash.len().min(ID_LEN)]
    }

    /// The display name: the checkpoint's last path segment.
    pub fn display(&self) -> &str {
        self.id.rsplit('/').next().unwrap_or(&self.id)
    }
}

/// What a node's `/node` says, as far as placement cares.
#[derive(Clone, Debug, PartialEq)]
pub struct NodeInfo {
    pub name: Option<String>,
    pub fingerprint: Option<String>,
    pub free_bytes: u64,
    pub models: Vec<NodeModel>,
}

/// Why a node answered but can't be used.
#[derive(Debug, PartialEq)]
pub enum Refused {
    Newer,
    Older,
    Mismatch,
    Unpaired,
}

impl Refused {
    pub fn line(&self, name: &str) -> String {
        match self {
            Self::Newer => format!("{name} runs a newer tang: update frog"),
            Self::Older => format!("{name} needs a newer tang"),
            Self::Mismatch => format!("this isn't the {name} you paired"),
            Self::Unpaired => format!("{name} isn't paired anymore"),
        }
    }
}

/// Read a `/node` body (schema 2). `pin` is the paired fingerprint (None for this Mac).
pub fn parse_node(v: &Value, pin: Option<&str>) -> Result<NodeInfo, Refused> {
    let schema = v["schema"].as_u64().unwrap_or(0);
    if schema > SCHEMA {
        return Err(Refused::Newer);
    }
    if schema < SCHEMA {
        return Err(Refused::Older);
    }
    let fingerprint = v["identity"]["fingerprint"].as_str().map(str::to_lowercase);
    if let Some(pin) = pin
        && fingerprint.as_deref() != Some(pin.to_lowercase().as_str())
    {
        return Err(Refused::Mismatch);
    }
    let mut models: Vec<NodeModel> = Vec::new();
    let entries = |key: &str| v["models"][key].as_array().cloned().unwrap_or_default();
    for (m, loaded) in entries("loaded")
        .into_iter()
        .map(|m| (m, true))
        .chain(entries("on_disk").into_iter().map(|m| (m, false)))
    {
        let (Some(id), Some(hash)) = (m["id"].as_str(), m["weights_hash"].as_str()) else {
            continue;
        };
        let hash = hash.to_lowercase();
        // A checkpoint both loaded and on disk is one model, loaded.
        if let Some(seen) = models.iter_mut().find(|x| x.weights_hash == hash) {
            seen.loaded |= loaded;
            continue;
        }
        models.push(NodeModel {
            id: id.into(),
            weights_hash: hash,
            quant: m["quant"].as_str().map(String::from),
            loaded: loaded || m["loaded"].as_bool() == Some(true),
            context_window: m["context_window"].as_u64(),
        });
    }
    Ok(NodeInfo {
        name: v["name"].as_str().map(String::from),
        fingerprint,
        free_bytes: v["hardware"]["free_bytes"].as_u64().unwrap_or(0),
        models,
    })
}

/// Where a call goes.
#[derive(Clone, Debug, PartialEq)]
pub struct Placed {
    pub node_id: String,
    pub name: String,
    /// The server root.
    pub base: String,
    pub key: Option<String>,
    pub model: String,
    pub local: bool,
}

impl Placed {
    pub fn ran_on(&self) -> RanOn {
        RanOn {
            node_id: self.node_id.clone(),
            name: self.name.clone(),
            local: self.local,
        }
    }

    /// How the notice names it.
    pub fn label(&self) -> &str {
        if self.local { "this Mac" } else { &self.name }
    }
}

/// How long things take; tests shrink them.
#[derive(Clone, Debug)]
pub struct Timing {
    pub poll_every: Duration,
    pub poll_timeout: Duration,
    pub down_for: Duration,
    /// No bytes for this long once the reply started: the node is gone.
    pub stall: Duration,
    /// No bytes for this long before the first: the node is gone.
    pub first_byte: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            poll_every: Duration::from_secs(2),
            poll_timeout: Duration::from_secs(2),
            down_for: Duration::from_secs(30),
            stall: Duration::from_secs(20),
            first_byte: Duration::from_secs(120),
        }
    }
}

#[derive(Default)]
struct NodeState {
    info: Option<NodeInfo>,
    refused: Option<Refused>,
    polled: Option<Instant>,
    down_until: Option<Instant>,
}

impl NodeState {
    fn usable(&self, now: Instant) -> Option<&NodeInfo> {
        if self.refused.is_some() || self.down_until.is_some_and(|t| t > now) {
            return None;
        }
        self.info.as_ref()
    }
}

/// Where the paired list comes from.
enum Source {
    /// The store file, re-read on every refresh (the app may pair a node mid-session).
    File(PathBuf),
    Fixed(Vec<Paired>),
}

pub struct Pool {
    source: Source,
    paired: Mutex<Vec<Paired>>,
    /// This Mac's tang, when it may be used.
    local: Option<String>,
    pub timing: Timing,
    pub(crate) http: reqwest::Client,
    state: Mutex<HashMap<String, NodeState>>,
    /// The last refresh, for staleness.
    refreshed: Mutex<Option<Instant>>,
    /// Serializes refreshes so a poll and a placement don't both hit every node.
    refreshing: tokio::sync::Mutex<()>,
}

/// The id this Mac's tang goes by in the pool.
pub const LOCAL_ID: &str = "local";

impl Pool {
    fn build(source: Source, local: Option<String>, timing: Timing) -> Self {
        let paired = match &source {
            Source::Fixed(p) => p.clone(),
            Source::File(_) => Vec::new(),
        };
        Self {
            source,
            paired: Mutex::new(paired),
            local,
            timing,
            http: reqwest::Client::builder()
                .no_proxy()
                .connect_timeout(Duration::from_secs(5))
                .build()
                .unwrap_or_default(),
            state: Mutex::new(HashMap::new()),
            refreshed: Mutex::new(None),
            refreshing: tokio::sync::Mutex::new(()),
        }
    }

    /// The pool every session shares: the store file plus this Mac's tang.
    pub fn global() -> Arc<Self> {
        static POOL: OnceLock<Arc<Pool>> = OnceLock::new();
        POOL.get_or_init(|| {
            Arc::new(Self::build(
                Source::File(store_path()),
                Some(LOCAL_BASE.into()),
                Timing::default(),
            ))
        })
        .clone()
    }

    /// A pool over a fixed list (tests, tools).
    pub fn fixed(paired: Vec<Paired>, local: Option<String>, timing: Timing) -> Arc<Self> {
        Arc::new(Self::build(Source::Fixed(paired), local, timing))
    }

    fn reload(&self) {
        if let Source::File(path) = &self.source {
            let bytes = std::fs::read(path).unwrap_or_default();
            *self.paired.lock().unwrap() = read_store(&bytes, &crate::providers::node_key);
        }
    }

    /// Every candidate: paired nodes, then this Mac.
    fn targets(&self) -> Vec<(String, String, Option<String>, Option<String>, String)> {
        let mut out: Vec<_> = self
            .paired
            .lock()
            .unwrap()
            .iter()
            .map(|p| {
                (
                    p.node_id.clone(),
                    p.base_url.clone(),
                    p.key.clone(),
                    Some(p.fingerprint.clone()),
                    p.name.clone(),
                )
            })
            .collect();
        if let Some(base) = &self.local {
            out.push((LOCAL_ID.into(), base.clone(), None, None, "this Mac".into()));
        }
        out
    }

    /// Read every node's `/node` now.
    pub async fn refresh(&self) {
        let _one = self.refreshing.lock().await;
        self.reload();
        let polls = self
            .targets()
            .into_iter()
            .map(|(id, base, key, pin, name)| {
                let http = self.http.clone();
                let timeout = self.timing.poll_timeout;
                async move {
                    let mut rb = http.get(format!("{}/node", base.trim_end_matches('/')));
                    if let Some(k) = &key {
                        rb = rb.bearer_auth(k);
                    }
                    let got = tokio::time::timeout(timeout, async {
                        let resp = rb.send().await.ok()?;
                        if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
                            return Some(Err(Refused::Unpaired));
                        }
                        if !resp.status().is_success() {
                            return None;
                        }
                        let v: Value = resp.json().await.ok()?;
                        Some(parse_node(&v, pin.as_deref()))
                    })
                    .await
                    .ok()
                    .flatten();
                    (id, name, got)
                }
            });
        let results = futures_util::future::join_all(polls).await;
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
        let live: Vec<String> = results.iter().map(|(id, ..)| id.clone()).collect();
        state.retain(|id, _| live.contains(id));
        for (id, name, got) in results {
            let s = state.entry(id).or_default();
            s.polled = Some(now);
            match got {
                Some(Ok(info)) => {
                    s.info = Some(info);
                    s.refused = None;
                }
                Some(Err(r)) => {
                    if s.refused.as_ref() != Some(&r) {
                        eprintln!("frog: node {}", r.line(&name));
                    }
                    s.info = None;
                    s.refused = Some(r);
                }
                // Unreachable: nothing to place on until it answers again.
                None => {
                    s.info = None;
                    s.refused = None;
                }
            }
        }
        *self.refreshed.lock().unwrap() = Some(now);
    }

    /// Refresh when what's known is older than a poll or two.
    pub async fn ensure_fresh(&self) {
        let stale = self
            .refreshed
            .lock()
            .unwrap()
            .is_none_or(|t| t.elapsed() > self.timing.poll_every * 2);
        if stale {
            self.refresh().await;
        }
    }

    /// Poll every `poll_every` until the guard drops (while a session runs on a pooled model).
    pub fn watch(self: &Arc<Self>) -> tokio_util::sync::DropGuard {
        let token = tokio_util::sync::CancellationToken::new();
        let pool = Arc::downgrade(self);
        let stop = token.clone();
        let every = self.timing.poll_every;
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = stop.cancelled() => return,
                    _ = tokio::time::sleep(every) => {}
                }
                let Some(pool) = pool.upgrade() else { return };
                pool.refresh().await;
            }
        });
        token.drop_guard()
    }

    /// Take a node out of placement for `down_for`.
    pub fn mark_down(&self, node_id: &str) {
        let until = Instant::now() + self.timing.down_for;
        self.state
            .lock()
            .unwrap()
            .entry(node_id.into())
            .or_default()
            .down_until = Some(until);
    }

    /// Placement (section 7): `pins` in order (the session's pinned node, then the one it last
    /// ran on) → any paired node with the hash, loaded first, then most free memory → this
    /// Mac's tang → `Err` with one line.
    pub fn place(&self, hash: &str, pins: &[&str]) -> Result<Placed, String> {
        let hash = hash.to_lowercase();
        let now = Instant::now();
        let state = self.state.lock().unwrap();
        let paired = self.paired.lock().unwrap();
        let has = |id: &str| -> Option<(&NodeInfo, &NodeModel)> {
            let info = state.get(id)?.usable(now)?;
            let m = info
                .models
                .iter()
                .find(|m| m.weights_hash.starts_with(&hash))?;
            Some((info, m))
        };
        let placed = |p: &Paired, m: &NodeModel| Placed {
            node_id: p.node_id.clone(),
            name: p.name.clone(),
            base: p.base_url.clone(),
            key: p.key.clone(),
            model: m.id.clone(),
            local: false,
        };
        for pin in pins {
            if let Some(p) = paired.iter().find(|p| p.node_id == *pin || p.name == *pin)
                && let Some((_, m)) = has(&p.node_id)
            {
                return Ok(placed(p, m));
            }
        }
        let best = paired
            .iter()
            .filter_map(|p| has(&p.node_id).map(|(i, m)| (p, i, m)))
            .max_by_key(|(_, i, m)| (m.loaded, i.free_bytes));
        if let Some((p, _, m)) = best {
            return Ok(placed(p, m));
        }
        if let Some(base) = &self.local
            && let Some((_, m)) = has(LOCAL_ID)
        {
            return Ok(Placed {
                node_id: LOCAL_ID.into(),
                name: "this Mac".into(),
                base: base.clone(),
                key: None,
                model: m.id.clone(),
                local: true,
            });
        }
        let what = Self::model_in(&state, &hash)
            .map(|m| m.display().to_string())
            .unwrap_or_else(|| format!("node/{}", &hash[..hash.len().min(ID_LEN)]));
        Err(format!("no paired node has {what} right now"))
    }

    /// A model with this hash on any node that answered (down or not), for its name and window.
    fn model_in(state: &HashMap<String, NodeState>, hash: &str) -> Option<NodeModel> {
        state
            .values()
            .filter_map(|s| s.info.as_ref())
            .flat_map(|i| i.models.iter())
            .find(|m| m.weights_hash.starts_with(hash))
            .cloned()
    }

    pub fn model(&self, hash: &str) -> Option<NodeModel> {
        Self::model_in(&self.state.lock().unwrap(), &hash.to_lowercase())
    }

    /// Every pooled model once, keyed by hash (for the picker). Includes this Mac's tang's
    /// models only when a paired node has the same weights.
    pub fn pooled(&self) -> Vec<NodeModel> {
        let state = self.state.lock().unwrap();
        let now = Instant::now();
        let mut out: Vec<NodeModel> = Vec::new();
        for (id, s) in state.iter() {
            if id == LOCAL_ID {
                continue;
            }
            for m in s
                .usable(now)
                .map(|i| i.models.as_slice())
                .unwrap_or_default()
            {
                if !out.iter().any(|x| x.weights_hash == m.weights_hash) {
                    out.push(m.clone());
                }
            }
        }
        out.sort_by(|a, b| a.display().cmp(b.display()));
        out
    }

    /// The one line saying why a node can't be used, if one answered and was refused.
    pub fn refusals(&self) -> Vec<String> {
        let state = self.state.lock().unwrap();
        let paired = self.paired.lock().unwrap();
        paired
            .iter()
            .filter_map(|p| {
                state
                    .get(&p.node_id)
                    .and_then(|s| s.refused.as_ref())
                    .map(|r| r.line(&p.name))
            })
            .collect()
    }
}

/// `node/<hash12>[@pin]` → (hash, pin).
pub fn split_spec(model: &str) -> (&str, Option<&str>) {
    match model.split_once('@') {
        Some((h, pin)) if !pin.is_empty() => (h, Some(pin)),
        Some((h, _)) => (h, None),
        None => (model, None),
    }
}

/// In-process fake nodes for tests: `GET /node` (schema 2) and OpenAI-compatible chat.
#[cfg(test)]
pub mod fake {
    use serde_json::json;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// How a fake node answers chat.
    #[derive(Clone)]
    pub enum Chat {
        /// A whole reply.
        Reply(&'static str),
        /// This much text, then silence with the connection open.
        Stall(&'static str),
        /// HTTP 500.
        Fail,
    }

    pub struct Fake {
        pub base: String,
        pub chats: Arc<AtomicUsize>,
    }

    impl Fake {
        pub fn chats(&self) -> usize {
            self.chats.load(Ordering::SeqCst)
        }
    }

    pub async fn spawn(
        fingerprint: &'static str,
        free: u64,
        models: Vec<(&'static str, &'static str, bool)>,
        chat: Chat,
    ) -> Fake {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let chats = Arc::new(AtomicUsize::new(0));
        let count = chats.clone();
        let loaded: Vec<_> = models
            .iter()
            .filter(|m| m.2)
            .map(|(id, h, _)| json!({"id": id, "weights_hash": h, "quant": "mlx-4bit", "context_window": 32768}))
            .collect();
        let disk: Vec<_> = models
            .iter()
            .map(
                |(id, h, l)| json!({"id": id, "weights_hash": h, "quant": "mlx-4bit", "loaded": l}),
            )
            .collect();
        let node = json!({
            "schema": 2, "node_id": fingerprint, "name": "fake",
            "identity": {"fingerprint": fingerprint, "public_key": "AA=="},
            "hardware": {"kind": "metal", "free_bytes": free},
            "models": {"loaded": loaded, "on_disk": disk, "loading": null},
        })
        .to_string();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                let (count, node, chat) = (count.clone(), node.clone(), chat.clone());
                tokio::spawn(async move {
                    let mut got = Vec::new();
                    loop {
                        let mut buf = [0u8; 8192];
                        let Ok(n) = s.read(&mut buf).await else {
                            return;
                        };
                        if n == 0 {
                            return;
                        }
                        got.extend_from_slice(&buf[..n]);
                        if let Some(end) = got.windows(4).position(|w| w == b"\r\n\r\n") {
                            let head = String::from_utf8_lossy(&got[..end]).to_ascii_lowercase();
                            let len: usize = head
                                .lines()
                                .find_map(|l| l.strip_prefix("content-length: ").map(str::to_owned))
                                .and_then(|l| l.trim().parse().ok())
                                .unwrap_or(0);
                            if got.len() >= end + 4 + len {
                                break;
                            }
                        }
                    }
                    let line = String::from_utf8_lossy(&got)
                        .lines()
                        .next()
                        .unwrap_or("")
                        .to_string();
                    let ok = |body: &str, ty: &str| {
                        format!(
                            "HTTP/1.1 200 OK\r\ncontent-type: {ty}\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                            body.len()
                        )
                    };
                    let sse = |t: &str| {
                        format!(
                            "data: {}\n\n",
                            json!({"choices":[{"delta":{"content": t}}]})
                        )
                    };
                    let out = if line.starts_with("GET /node") {
                        ok(&node, "application/json")
                    } else if line.contains("/v1/chat/completions") {
                        count.fetch_add(1, Ordering::SeqCst);
                        match chat {
                            Chat::Reply(t) => ok(
                                &format!(
                                    "{}data: {{\"choices\":[{{\"delta\":{{}},\"finish_reason\":\"stop\"}}]}}\n\ndata: [DONE]\n\n",
                                    sse(t)
                                ),
                                "text/event-stream",
                            ),
                            Chat::Fail => "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 4\r\nconnection: close\r\n\r\ndead".into(),
                            Chat::Stall(t) => {
                                let head = "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n";
                                let _ = s.write_all(format!("{head}{}", sse(t)).as_bytes()).await;
                                let _ = s.flush().await;
                                tokio::time::sleep(std::time::Duration::from_secs(600)).await;
                                return;
                            }
                        }
                    } else {
                        ok("{}", "application/json")
                    };
                    let _ = s.write_all(out.as_bytes()).await;
                    let _ = s.flush().await;
                });
            }
        });
        Fake {
            base: format!("http://{addr}"),
            chats,
        }
    }

    pub fn paired(name: &str, fingerprint: &str, f: &Fake) -> super::Paired {
        super::Paired {
            node_id: format!("id-{name}"),
            fingerprint: fingerprint.into(),
            name: name.into(),
            base_url: f.base.clone(),
            key: Some("tnk_test".into()),
        }
    }

    pub fn quick() -> super::Timing {
        super::Timing {
            poll_every: std::time::Duration::from_secs(60),
            poll_timeout: std::time::Duration::from_secs(2),
            down_for: std::time::Duration::from_secs(30),
            stall: std::time::Duration::from_millis(300),
            first_byte: std::time::Duration::from_secs(5),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn node(fp: &str, free: u64, loaded: &[(&str, &str)], disk: &[(&str, &str)]) -> Value {
        let m = |(id, h): &(&str, &str)| json!({"id": id, "weights_hash": h, "quant": "mlx-4bit", "extra": 1});
        json!({
            "schema": 2,
            "name": "box",
            "identity": {"fingerprint": fp, "public_key": "AAAA"},
            "hardware": {"free_bytes": free, "kind": "metal"},
            "models": {
                "loaded": loaded.iter().map(m).collect::<Vec<_>>(),
                "on_disk": disk.iter().map(m).collect::<Vec<_>>(),
            },
            "future_field": {"ignored": true},
        })
    }

    #[test]
    fn store_skips_incomplete_entries_and_reads_keys() {
        let bytes = br#"{"nodes":[
            {"node_id":"a","fingerprint":"f","name":"mew","base_url":"http://mew:8911","new":1},
            {"node_id":"b","name":"half"}
        ], "other": true}"#;
        let got = read_store(bytes, &|id| Some(format!("k-{id}")));
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].name, "mew");
        assert_eq!(got[0].key.as_deref(), Some("k-a"));
        assert!(read_store(b"not json", &|_| None).is_empty());
    }

    #[test]
    fn parse_checks_schema_and_fingerprint_and_ignores_unknown_fields() {
        let v = node(
            "ABCD",
            5,
            &[("org/Qwen3-4B", "aa11")],
            &[("org/Qwen3-4B", "aa11"), ("org/Big", "bb22")],
        );
        let info = parse_node(&v, Some("abcd")).unwrap();
        assert_eq!(info.models.len(), 2);
        assert!(info.models[0].loaded && !info.models[1].loaded);
        assert_eq!(info.models[0].display(), "Qwen3-4B");
        assert_eq!(parse_node(&v, Some("ffff")), Err(Refused::Mismatch));
        assert!(parse_node(&v, None).is_ok());
        let mut newer = v.clone();
        newer["schema"] = json!(3);
        assert_eq!(parse_node(&newer, None), Err(Refused::Newer));
        assert_eq!(
            Refused::Newer.line("mew"),
            "mew runs a newer tang: update frog"
        );
        let mut older = v;
        older["schema"] = json!(1);
        assert_eq!(parse_node(&older, None), Err(Refused::Older));
    }

    #[test]
    fn spec_pins() {
        assert_eq!(split_spec("aa11"), ("aa11", None));
        assert_eq!(split_spec("aa11@mew"), ("aa11", Some("mew")));
    }

    const Q4: &str = "aa11bb22cc33dd44";
    const BIG: &str = "ffff0000eeee1111";

    #[tokio::test]
    async fn placement_prefers_pinned_then_loaded_then_free_memory_then_this_mac() {
        use fake::{Chat, paired, quick, spawn};
        let roomy_disk = spawn(
            "fa",
            900,
            vec![("org/Qwen3-4B", Q4, false)],
            Chat::Reply("x"),
        )
        .await;
        let loaded = spawn(
            "fb",
            100,
            vec![("org/Qwen3-4B", Q4, true)],
            Chat::Reply("x"),
        )
        .await;
        let roomy_loaded = spawn(
            "fc",
            500,
            vec![("org/Qwen3-4B", Q4, true)],
            Chat::Reply("x"),
        )
        .await;
        let mac = spawn(
            "fd",
            1,
            vec![("org/Qwen3-4B", Q4, true), ("org/Big", BIG, true)],
            Chat::Reply("x"),
        )
        .await;
        let pool = Pool::fixed(
            vec![
                paired("disk", "fa", &roomy_disk),
                paired("small", "fb", &loaded),
                paired("roomy", "fc", &roomy_loaded),
            ],
            Some(mac.base.clone()),
            quick(),
        );
        pool.refresh().await;
        // Loaded beats on-disk; among loaded, more free memory wins.
        assert_eq!(pool.place("aa11bb22cc33", &[]).unwrap().name, "roomy");
        // A pin wins (by name or id), even over a better node.
        assert_eq!(
            pool.place("aa11bb22cc33", &["small"]).unwrap().name,
            "small"
        );
        assert_eq!(
            pool.place("aa11bb22cc33", &["id-disk"]).unwrap().name,
            "disk"
        );
        // A pin that doesn't have the model falls through to the order.
        assert_eq!(
            pool.place("aa11bb22cc33", &["nobody"]).unwrap().name,
            "roomy"
        );
        // Down nodes drop out; on-disk still beats this Mac.
        pool.mark_down("id-roomy");
        pool.mark_down("id-small");
        assert_eq!(pool.place("aa11bb22cc33", &["small"]).unwrap().name, "disk");
        pool.mark_down("id-disk");
        let local = pool.place("aa11bb22cc33", &[]).unwrap();
        assert!(local.local && local.label() == "this Mac" && local.key.is_none());
        // Only this Mac has it: still placed there, but not listed as pooled.
        assert!(pool.place("ffff0000eeee", &[]).unwrap().local);
        assert_eq!(pool.pooled().len(), 0, "every paired node is down");
        pool.mark_down(LOCAL_ID);
        assert_eq!(
            pool.place("aa11bb22cc33", &[]).unwrap_err(),
            "no paired node has Qwen3-4B right now"
        );
    }

    #[tokio::test]
    async fn a_fingerprint_mismatch_is_never_placed() {
        use fake::{Chat, paired, quick, spawn};
        let imposter = spawn(
            "0bad",
            999,
            vec![("org/Qwen3-4B", Q4, true)],
            Chat::Reply("x"),
        )
        .await;
        let pool = Pool::fixed(vec![paired("mew", "a11ce", &imposter)], None, quick());
        pool.refresh().await;
        assert_eq!(
            pool.refusals(),
            vec!["this isn't the mew you paired".to_string()]
        );
        assert!(pool.place("aa11bb22cc33", &["mew"]).is_err());
        assert!(pool.pooled().is_empty());
    }
}
