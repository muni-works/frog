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
    /// `rates`: the node's measured tokens per second (moving averages), None until measured.
    pub prefill_tok_s: Option<f64>,
    pub decode_tok_s: Option<f64>,
    /// How long its last load took (loaded models).
    pub load_secs: Option<f64>,
    /// Memory a load needs (`load_bytes`, else `size_bytes`; on-disk models).
    pub load_bytes: Option<u64>,
    /// `kv.prompt_cache_keys`: each conversation's cached prompt length.
    pub cache_keys: Vec<(String, u64)>,
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
    /// `queue.running` then `queue.waiting`.
    pub queue: Vec<Queued>,
}

/// One request on a node's queue, as far as the wait estimate cares.
#[derive(Clone, Debug, PartialEq)]
pub struct Queued {
    pub background: bool,
    pub running: bool,
    /// Prompt positions it still has to prefill.
    pub prefill_left: u64,
    pub generated: u64,
}

impl NodeInfo {
    /// An interactive request is running or waiting.
    pub fn interactive_busy(&self) -> bool {
        self.queue.iter().any(|q| !q.background)
    }
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
        let load_bytes = m["load_bytes"].as_u64().or(m["size_bytes"].as_u64());
        if let Some(seen) = models.iter_mut().find(|x| x.weights_hash == hash) {
            seen.loaded |= loaded;
            seen.load_bytes = seen.load_bytes.or(load_bytes);
            continue;
        }
        let rate = |k: &str| m["rates"][k].as_f64().filter(|r| *r > 0.0);
        models.push(NodeModel {
            id: id.into(),
            weights_hash: hash,
            quant: m["quant"].as_str().map(String::from),
            loaded: loaded || m["loaded"].as_bool() == Some(true),
            context_window: m["context_window"].as_u64(),
            prefill_tok_s: rate("prefill_tok_s"),
            decode_tok_s: rate("decode_tok_s"),
            load_secs: m["load_secs"].as_f64(),
            load_bytes,
            cache_keys: m["kv"]["prompt_cache_keys"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(|k| {
                            Some((k["key"].as_str()?.to_string(), k["cached_tokens"].as_u64()?))
                        })
                        .collect()
                })
                .unwrap_or_default(),
        });
    }
    let n = |q: &Value, k: &str| q[k].as_u64().unwrap_or(0);
    let queued = |key: &str, running: bool| {
        v["queue"][key]
            .as_array()
            .cloned()
            .unwrap_or_default()
            .into_iter()
            .map(move |q| Queued {
                background: q["priority"].as_str() == Some("background"),
                running,
                prefill_left: n(&q, "prompt_tokens")
                    .saturating_sub(n(&q, "cached_tokens").max(n(&q, "prefilled_tokens"))),
                generated: n(&q, "generated_tokens"),
            })
    };
    Ok(NodeInfo {
        name: v["name"].as_str().map(String::from),
        fingerprint,
        free_bytes: v["hardware"]["free_bytes"].as_u64().unwrap_or(0),
        models,
        queue: queued("running", true)
            .chain(queued("waiting", false))
            .collect(),
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
    /// This Mac's tang isn't running: start it serving this model first.
    pub start: Option<String>,
    /// The estimated finish, in seconds.
    pub eta: f64,
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
    /// How long a `/node` poll takes: the round trip.
    rtt: Ema,
}

/// An exponential moving average; None until the first sample.
#[derive(Clone, Copy, Debug, Default)]
pub struct Ema(Option<f64>);

impl Ema {
    pub fn observe(&mut self, x: f64) {
        if x.is_finite() && x > 0.0 {
            self.0 = Some(self.0.map_or(x, |v| v + 0.3 * (x - v)));
        }
    }

    pub fn value(&self) -> Option<f64> {
        self.0
    }
}

/// What kind of call this is, for how much it's expected to write.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum Step {
    /// After the user's words: an answer, often long.
    #[default]
    Answer,
    /// After tool results: usually the next tool call, short.
    Tool,
    /// Beside the conversation (subagents, the classifier, compaction, titles).
    Background,
}

impl Step {
    /// Output tokens to expect before anything's measured.
    fn default_output(self) -> f64 {
        match self {
            Self::Answer => 600.0,
            Self::Tool => 150.0,
            Self::Background => 300.0,
        }
    }
}

/// What placement knows about one call.
#[derive(Clone, Debug, Default)]
pub struct Call<'a> {
    /// The node the session is pinned to (`node/<hash>@<pin>`): it wins whenever it can serve.
    pub pin: Option<&'a str>,
    /// Where the session's last call ran: it wins ties.
    pub last: Option<&'a str>,
    /// The conversation's `prompt_cache_key`, matched against each node's KV.
    pub cache_key: Option<&'a str>,
    /// The whole prompt, estimated.
    pub prompt_tokens: u64,
    pub step: Step,
    pub background: bool,
}

/// Rates the engine measured itself, per node and model, for nodes that don't report them.
#[derive(Default)]
struct Measured {
    prefill: Ema,
    decode: Ema,
}

/// A call the engine has placed and not yet finished, so placements in the same instant see it
/// (a node's `/node` queue is up to a poll old).
struct Flight {
    node: String,
    background: bool,
    eta: f64,
    began: Instant,
}

/// What a finished call measured.
#[derive(Clone, Copy, Debug, Default)]
pub struct Sample {
    /// Prompt tokens the node prefilled (not cached).
    pub prefilled: u64,
    pub output: u64,
    /// Until the first byte of the reply.
    pub first_byte: Option<Duration>,
    pub total: Duration,
}

/// Starting this Mac's tang for a model it has on disk but isn't serving.
pub struct LocalStart {
    /// `(weights_hash, model)` for each model this Mac could serve.
    pub catalog: Box<dyn Fn() -> Vec<(String, String)> + Send + Sync>,
    pub start: Box<
        dyn Fn(String) -> futures_util::future::BoxFuture<'static, anyhow::Result<()>>
            + Send
            + Sync,
    >,
}

impl LocalStart {
    /// The sidecar: `tang-llm serve <model>` for models in the Hugging Face cache.
    fn tang() -> Self {
        Self {
            catalog: Box::new(|| {
                if !crate::sidecar::available("tang") {
                    return Vec::new();
                }
                local_catalog(&crate::setup::hf_hub_dir())
            }),
            start: Box::new(|model| {
                Box::pin(async move {
                    let mut p =
                        crate::config::Profile::new(crate::config::ProviderKind::Openai, &model);
                    p.sidecar = Some(model);
                    crate::sidecar::ensure(&p).await
                })
            }),
        }
    }
}

/// Every model in a Hugging Face hub cache that tang can serve, with its `weights_hash`.
pub fn local_catalog(hub: &std::path::Path) -> Vec<(String, String)> {
    let Ok(repos) = std::fs::read_dir(hub) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    for repo in repos.filter_map(|r| r.ok()) {
        let name = repo.file_name().to_string_lossy().into_owned();
        let Some(id) = name.strip_prefix("models--") else {
            continue;
        };
        let id = id.replacen("--", "/", 1);
        let Ok(snaps) = std::fs::read_dir(repo.path().join("snapshots")) else {
            continue;
        };
        for snap in snaps.filter_map(|s| s.ok()) {
            let dir = snap.path();
            if !dir.join("tokenizer.json").is_file() {
                continue;
            }
            if let Some(h) = weights_hash(&dir) {
                out.push((h, id.clone()));
            }
        }
    }
    out
}

/// docs/node-protocol.md §6: SHA-256 over `config.json`, then for each weight file by name its
/// name, 0x00, size (u64 LE) and first 1 MiB. None without a weight file.
pub fn weights_hash(dir: &std::path::Path) -> Option<String> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".safetensors") || n.ends_with(".gguf"))
        .collect();
    if names.is_empty() {
        return None;
    }
    names.sort();
    let mut h = Sha256::new();
    if let Ok(c) = std::fs::read(dir.join("config.json")) {
        h.update(c);
    }
    for n in names {
        let f = std::fs::File::open(dir.join(&n)).ok()?;
        let size = f.metadata().ok()?.len();
        h.update(n.as_bytes());
        h.update([0u8]);
        h.update(size.to_le_bytes());
        let mut head = Vec::new();
        f.take(1 << 20).read_to_end(&mut head).ok()?;
        h.update(&head);
    }
    Some(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Before anything's measured.
const PREFILL_TOK_S: f64 = 500.0;
const DECODE_TOK_S: f64 = 30.0;
/// A load with nothing to go on.
const LOAD_SECS: f64 = 30.0;
/// Loading reads about this fast.
const LOAD_BYTES_PER_SEC: f64 = 2e9;
/// Starting this Mac's tang before it loads.
const START_SECS: f64 = 5.0;
/// Finishes within this fraction of the best are a tie.
pub const TIE: f64 = 0.10;

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
    /// Starting this Mac's tang on demand, and what it could serve (re-read every few minutes).
    local_start: Option<LocalStart>,
    catalog: Mutex<Option<(Instant, Vec<(String, String)>)>>,
    starting: tokio::sync::Mutex<()>,
    /// Rates the engine measured, by `node_id/model`.
    measured: Mutex<HashMap<String, Measured>>,
    /// Output tokens per step kind.
    outputs: Mutex<HashMap<Step, Ema>>,
    flights: Mutex<HashMap<u64, Flight>>,
    next_flight: std::sync::atomic::AtomicU64,
}

/// A placed call in progress; dropping it ends it.
pub struct InFlight {
    pool: Arc<Pool>,
    id: u64,
}

impl Drop for InFlight {
    fn drop(&mut self) {
        self.pool.flights.lock().unwrap().remove(&self.id);
    }
}

/// The id this Mac's tang goes by in the pool.
pub const LOCAL_ID: &str = "local";

impl Pool {
    fn build(
        source: Source,
        local: Option<String>,
        timing: Timing,
        local_start: Option<LocalStart>,
    ) -> Self {
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
            local_start,
            catalog: Mutex::new(None),
            starting: tokio::sync::Mutex::new(()),
            measured: Mutex::new(HashMap::new()),
            outputs: Mutex::new(HashMap::new()),
            flights: Mutex::new(HashMap::new()),
            next_flight: Default::default(),
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
                Some(LocalStart::tang()),
            ))
        })
        .clone()
    }

    /// A pool over a fixed list (tests, tools).
    pub fn fixed(paired: Vec<Paired>, local: Option<String>, timing: Timing) -> Arc<Self> {
        Arc::new(Self::build(Source::Fixed(paired), local, timing, None))
    }

    /// A fixed pool that can start this Mac's tang.
    pub fn fixed_with_start(
        paired: Vec<Paired>,
        local: String,
        timing: Timing,
        start: LocalStart,
    ) -> Arc<Self> {
        Arc::new(Self::build(
            Source::Fixed(paired),
            Some(local),
            timing,
            Some(start),
        ))
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
                    let sent = Instant::now();
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
                    (id, name, got, sent.elapsed())
                }
            });
        let results = futures_util::future::join_all(polls).await;
        let now = Instant::now();
        let mut state = self.state.lock().unwrap();
        let live: Vec<String> = results.iter().map(|(id, ..)| id.clone()).collect();
        state.retain(|id, _| live.contains(id));
        for (id, name, got, took) in results {
            let s = state.entry(id).or_default();
            s.polled = Some(now);
            match got {
                Some(Ok(info)) => {
                    s.rtt.observe(took.as_secs_f64());
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

    /// Placement with only pins: the session's pinned node, then where it last ran.
    pub fn place(&self, hash: &str, pins: &[&str]) -> Result<Placed, String> {
        self.schedule(
            hash,
            &Call {
                pin: pins.first().copied(),
                last: pins.get(1).copied(),
                ..Call::default()
            },
        )
    }

    /// The model this Mac's tang could be started with, by hash.
    fn local_model(&self, hash: &str) -> Option<String> {
        let ls = self.local_start.as_ref()?;
        let mut cat = self.catalog.lock().unwrap();
        if cat
            .as_ref()
            .is_none_or(|(t, _)| t.elapsed() > Duration::from_secs(300))
        {
            *cat = Some((Instant::now(), (ls.catalog)()));
        }
        let (_, list) = cat.as_ref()?;
        list.iter()
            .find(|(h, _)| h.starts_with(hash))
            .map(|(_, m)| m.clone())
    }

    /// Start this Mac's tang serving `model`, then read it.
    pub async fn start_local(&self, model: &str) -> anyhow::Result<()> {
        let Some(ls) = &self.local_start else {
            anyhow::bail!("this Mac can't start tang");
        };
        let _one = self.starting.lock().await;
        (ls.start)(model.to_string()).await?;
        self.refresh().await;
        Ok(())
    }

    /// Count a placed call until the guard drops.
    pub fn begin(self: &Arc<Self>, at: &Placed, background: bool) -> InFlight {
        let id = self
            .next_flight
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.flights.lock().unwrap().insert(
            id,
            Flight {
                node: at.node_id.clone(),
                background,
                eta: at.eta,
                began: Instant::now(),
            },
        );
        InFlight {
            pool: self.clone(),
            id,
        }
    }

    /// Learn from a finished call: the step's output length, and the node's rates where it
    /// doesn't report its own.
    pub fn observe(&self, at: &Placed, step: Step, s: Sample) {
        if s.output > 0 {
            self.outputs
                .lock()
                .unwrap()
                .entry(step)
                .or_default()
                .observe(s.output as f64);
        }
        let Some(fb) = s.first_byte else { return };
        let mut measured = self.measured.lock().unwrap();
        let m = measured
            .entry(format!("{}/{}", at.node_id, at.model))
            .or_default();
        if s.prefilled >= 64 {
            m.prefill
                .observe(s.prefilled as f64 / fb.as_secs_f64().max(1e-3));
        }
        if s.output >= 16 {
            m.decode
                .observe(s.output as f64 / (s.total.saturating_sub(fb)).as_secs_f64().max(1e-3));
        }
    }

    /// Placement (N4): a pin that can serve wins; otherwise the earliest estimated finish, where
    /// finish = queue wait + uncached prompt ÷ prefill rate + expected output ÷ decode rate +
    /// round trip (+ starting and loading). Finishes within [`TIE`] of the best are a tie, won
    /// by the node holding the conversation's KV, then the one it last ran on. Background calls
    /// go only to nodes with no interactive call, when there is one. `Err` with one line when
    /// nowhere can.
    pub fn schedule(&self, hash: &str, call: &Call) -> Result<Placed, String> {
        let hash = hash.to_lowercase();
        let now = Instant::now();
        // This Mac's tang, when it isn't answering but could be started.
        let startable = self.local.is_some() && {
            let state = self.state.lock().unwrap();
            state.get(LOCAL_ID).is_none_or(|s| {
                s.info.is_none() && s.refused.is_none() && !s.down_until.is_some_and(|t| t > now)
            })
        };
        let start_model = if startable {
            self.local_model(&hash)
        } else {
            None
        };
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
            start: None,
            eta: 0.0,
        };
        if let Some(pin) = call.pin
            && let Some(p) = paired.iter().find(|p| p.node_id == pin || p.name == pin)
        {
            if let Some(r @ Refused::Mismatch) =
                state.get(&p.node_id).and_then(|s| s.refused.as_ref())
            {
                return Err(r.line(&p.name));
            }
            if let Some((_, m)) = has(&p.node_id) {
                return Ok(placed(p, m));
            }
        }
        // Every node that could take it.
        let mut cands: Vec<(Placed, Option<&NodeInfo>, NodeModel)> = paired
            .iter()
            .filter_map(|p| has(&p.node_id).map(|(i, m)| (placed(p, m), Some(i), m.clone())))
            .collect();
        if let Some(base) = &self.local {
            let here = |model: String, start: Option<String>| Placed {
                node_id: LOCAL_ID.into(),
                name: "this Mac".into(),
                base: base.clone(),
                key: None,
                model,
                local: true,
                start,
                eta: 0.0,
            };
            if let Some((i, m)) = has(LOCAL_ID) {
                cands.push((here(m.id.clone(), None), Some(i), m.clone()));
            } else if let Some(model) = start_model {
                let m = NodeModel {
                    id: model.clone(),
                    weights_hash: hash.clone(),
                    quant: None,
                    loaded: false,
                    context_window: None,
                    prefill_tok_s: None,
                    decode_tok_s: None,
                    load_secs: None,
                    load_bytes: None,
                    cache_keys: Vec::new(),
                };
                cands.push((here(model.clone(), Some(model)), None, m));
            }
        }
        if cands.is_empty() {
            let what = Self::model_in(&state, &hash)
                .map(|m| m.display().to_string())
                .unwrap_or_else(|| format!("node/{}", &hash[..hash.len().min(ID_LEN)]));
            return Err(format!("no paired node has {what} right now"));
        }
        let measured = self.measured.lock().unwrap();
        let outputs = self.outputs.lock().unwrap();
        let flights = self.flights.lock().unwrap();
        let expect = |step: Step| {
            outputs
                .get(&step)
                .and_then(Ema::value)
                .unwrap_or_else(|| step.default_output())
        };
        // (placed, cached tokens, interactive work on it)
        let mut scored: Vec<(Placed, u64, bool, u64)> = cands
            .into_iter()
            .map(|(mut at, info, m)| {
                let mine = measured.get(&format!("{}/{}", at.node_id, at.model));
                let prefill = m
                    .prefill_tok_s
                    .or_else(|| mine.and_then(|x| x.prefill.value()))
                    .unwrap_or(PREFILL_TOK_S);
                let decode = m
                    .decode_tok_s
                    .or_else(|| mine.and_then(|x| x.decode.value()))
                    .unwrap_or(DECODE_TOK_S);
                let s = state.get(&at.node_id);
                let rtt = s.and_then(|s| s.rtt.value()).unwrap_or(0.01);
                let cached = call
                    .cache_key
                    .and_then(|k| m.cache_keys.iter().find(|(c, _)| c == k))
                    .map_or(0, |(_, n)| (*n).min(call.prompt_tokens));
                let mut load = 0.0;
                if !m.loaded {
                    load += m
                        .load_secs
                        .or(m.load_bytes.map(|b| b as f64 / LOAD_BYTES_PER_SEC))
                        .unwrap_or(LOAD_SECS);
                }
                if at.start.is_some() {
                    load += START_SECS;
                }
                // Work ahead of it: an interactive call waits only for interactive work (a
                // node runs background work after it); background waits for everything.
                let counts = |bg: bool| call.background || !bg;
                let since = s
                    .and_then(|s| s.polled)
                    .map_or(0.0, |t| (now - t).as_secs_f64());
                let polled: f64 = info
                    .map(|i| {
                        i.queue
                            .iter()
                            .filter(|q| counts(q.background))
                            .map(|q| {
                                let out = if q.background {
                                    Step::Background
                                } else {
                                    Step::Answer
                                };
                                q.prefill_left as f64 / prefill
                                    + (expect(out) - q.generated as f64).max(0.0) / decode
                            })
                            .sum()
                    })
                    .unwrap_or(0.0);
                let ours: f64 = flights
                    .values()
                    .filter(|f| f.node == at.node_id && counts(f.background))
                    .map(|f| (f.eta - f.began.elapsed().as_secs_f64()).max(0.0))
                    .sum();
                let wait = (polled - since).max(0.0) + ours;
                let step = if call.background {
                    Step::Background
                } else {
                    call.step
                };
                at.eta = wait
                    + (call.prompt_tokens - cached) as f64 / prefill
                    + expect(step) / decode
                    + rtt
                    + load;
                let busy = info.is_some_and(NodeInfo::interactive_busy)
                    || flights
                        .values()
                        .any(|f| f.node == at.node_id && !f.background);
                let free = info.map_or(0, |i| i.free_bytes);
                (at, cached, busy, free)
            })
            .collect();
        if call.background && scored.iter().any(|(_, _, busy, _)| !busy) {
            scored.retain(|(_, _, busy, _)| !busy);
        }
        let best = scored
            .iter()
            .map(|(at, ..)| at.eta)
            .fold(f64::INFINITY, f64::min);
        // Within the tie band: the KV holder, then where it last ran, then loaded, then most
        // free memory, then a paired node before this Mac.
        let rank = |(at, cached, _, free): &(Placed, u64, bool, u64)| {
            (
                *cached,
                call.last.is_some_and(|l| at.node_id == l || at.name == l),
                at.start.is_none(),
                *free,
                !at.local,
            )
        };
        scored
            .into_iter()
            .filter(|(at, ..)| at.eta <= best * (1.0 + TIE) + 1e-9)
            .max_by(|a, b| rank(a).cmp(&rank(b)).then(b.0.eta.total_cmp(&a.0.eta)))
            .map(|(at, ..)| at)
            .ok_or_else(|| "no node can take this call".into())
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
        /// The `/node` body it serves.
        pub node: Arc<std::sync::Mutex<serde_json::Value>>,
        /// Each chat's `x-frog-priority`.
        pub priorities: Arc<std::sync::Mutex<Vec<String>>>,
    }

    impl Fake {
        pub fn chats(&self) -> usize {
            self.chats.load(Ordering::SeqCst)
        }

        /// Change what `/node` says.
        pub fn edit(&self, f: impl FnOnce(&mut serde_json::Value)) {
            f(&mut self.node.lock().unwrap());
        }

        /// Change the first loaded model's entry.
        pub fn model(&self, f: impl FnOnce(&mut serde_json::Value)) {
            self.edit(|v| f(&mut v["models"]["loaded"][0]));
        }
    }

    pub async fn spawn(
        fingerprint: &'static str,
        free: u64,
        models: Vec<(&'static str, &'static str, bool)>,
        chat: Chat,
    ) -> Fake {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        spawn_on(listener, fingerprint, free, models, chat)
    }

    /// A fake on an address picked now, not yet listening (for a tang that starts later).
    pub fn reserve() -> std::net::SocketAddr {
        std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
    }

    pub async fn spawn_at(
        addr: std::net::SocketAddr,
        fingerprint: &'static str,
        models: Vec<(&'static str, &'static str, bool)>,
        chat: Chat,
    ) -> Fake {
        let listener = tokio::net::TcpListener::bind(addr).await.unwrap();
        spawn_on(listener, fingerprint, 1, models, chat)
    }

    fn spawn_on(
        listener: tokio::net::TcpListener,
        fingerprint: &'static str,
        free: u64,
        models: Vec<(&'static str, &'static str, bool)>,
        chat: Chat,
    ) -> Fake {
        let addr = listener.local_addr().unwrap();
        let chats = Arc::new(AtomicUsize::new(0));
        let count = chats.clone();
        let priorities = Arc::new(std::sync::Mutex::new(Vec::new()));
        let heard = priorities.clone();
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
            "queue": {"running": [], "waiting": []},
        });
        let node = Arc::new(std::sync::Mutex::new(node));
        let served = node.clone();
        tokio::spawn(async move {
            while let Ok((mut s, _)) = listener.accept().await {
                let (count, node, chat, heard) =
                    (count.clone(), served.clone(), chat.clone(), heard.clone());
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
                        let body = node.lock().unwrap().to_string();
                        ok(&body, "application/json")
                    } else if line.contains("/v1/chat/completions") {
                        count.fetch_add(1, Ordering::SeqCst);
                        let head = String::from_utf8_lossy(&got).to_ascii_lowercase();
                        if let Some(p) = head
                            .lines()
                            .find_map(|l| l.strip_prefix("x-frog-priority: "))
                        {
                            heard.lock().unwrap().push(p.trim().to_string());
                        }
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
            node,
            priorities,
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
        // Down nodes drop out. A model this Mac has loaded beats one a node would have to
        // load first (the stub put any paired node first).
        pool.mark_down("id-roomy");
        pool.mark_down("id-small");
        assert!(pool.place("aa11bb22cc33", &["small"]).unwrap().local);
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

    fn rates(f: &fake::Fake, prefill: f64, decode: f64) {
        f.model(|m| m["rates"] = json!({"prefill_tok_s": prefill, "decode_tok_s": decode}));
    }

    fn holds(f: &fake::Fake, key: &str, tokens: u64) {
        f.model(|m| {
            m["kv"] = json!({"prompt_cache_keys": [{"key": key, "cached_tokens": tokens}]})
        });
    }

    fn call(prompt: u64) -> Call<'static> {
        Call {
            cache_key: Some("s1"),
            prompt_tokens: prompt,
            ..Call::default()
        }
    }

    async fn two() -> (fake::Fake, fake::Fake, Arc<Pool>) {
        use fake::{Chat, paired, quick, spawn};
        let a = spawn(
            "fa",
            100,
            vec![("org/Qwen3-4B", Q4, true)],
            Chat::Reply("x"),
        )
        .await;
        let b = spawn(
            "fb",
            100,
            vec![("org/Qwen3-4B", Q4, true)],
            Chat::Reply("x"),
        )
        .await;
        let pool = Pool::fixed(
            vec![paired("a", "fa", &a), paired("b", "fb", &b)],
            None,
            quick(),
        );
        (a, b, pool)
    }

    #[tokio::test]
    async fn the_node_that_finishes_first_wins() {
        let (a, b, pool) = two().await;
        // Decode-bound: the faster decoder.
        rates(&a, 1000.0, 20.0);
        rates(&b, 1000.0, 80.0);
        pool.refresh().await;
        assert_eq!(pool.schedule(Q4, &call(2000)).unwrap().name, "b");
        // A long prompt: the faster prefill.
        rates(&a, 4000.0, 30.0);
        rates(&b, 500.0, 30.0);
        pool.refresh().await;
        assert_eq!(pool.schedule(Q4, &call(20000)).unwrap().name, "a");
        // Rates the node doesn't report come from what the engine measured.
        a.model(|m| m["rates"] = json!({}));
        b.model(|m| m["rates"] = json!({}));
        pool.refresh().await;
        let at_b = pool
            .schedule(
                Q4,
                &Call {
                    pin: Some("b"),
                    ..call(0)
                },
            )
            .unwrap();
        pool.observe(
            &at_b,
            Step::Answer,
            Sample {
                prefilled: 5000,
                output: 500,
                first_byte: Some(Duration::from_secs(1)),
                total: Duration::from_secs(6),
            },
        );
        assert_eq!(pool.schedule(Q4, &call(5000)).unwrap().name, "b");
    }

    #[tokio::test]
    async fn the_node_holding_the_kv_wins_a_tie() {
        let (a, b, pool) = two().await;
        // b is 5% slower but holds the conversation's cache: a tie, and b wins it.
        rates(&a, 1000.0, 40.0);
        rates(&b, 1000.0, 38.0);
        holds(&b, "s1", 100);
        pool.refresh().await;
        assert_eq!(pool.schedule(Q4, &call(1000)).unwrap().name, "b");
        // Another conversation: no cache anywhere, the faster one.
        let other = Call {
            cache_key: Some("s2"),
            ..call(1000)
        };
        assert_eq!(pool.schedule(Q4, &other).unwrap().name, "a");
        // A big cache makes the holder genuinely faster.
        holds(&b, "s1", 30000);
        rates(&b, 1000.0, 36.0);
        pool.refresh().await;
        assert_eq!(pool.schedule(Q4, &call(32000)).unwrap().name, "b");
        // Clearly faster beats the cache.
        holds(&b, "s1", 100);
        rates(&a, 1000.0, 80.0);
        pool.refresh().await;
        assert_eq!(pool.schedule(Q4, &call(1000)).unwrap().name, "a");
    }

    #[tokio::test]
    async fn noise_does_not_flap_a_conversation() {
        let (a, b, pool) = two().await;
        let mut last: Option<String> = None;
        for i in 0..30 {
            // Each node's measured rate wobbles ±4%, out of step with the other.
            let wobble = if i % 2 == 0 { 1.04 } else { 0.96 };
            rates(&a, 1000.0, 40.0 * wobble);
            rates(&b, 1000.0, 40.0 / wobble);
            pool.refresh().await;
            let c = Call {
                last: last.as_deref(),
                cache_key: None,
                ..call(2000)
            };
            let at = pool.schedule(Q4, &c).unwrap();
            if let Some(l) = &last {
                assert_eq!(&at.node_id, l, "round {i} moved");
            }
            last = Some(at.node_id);
        }
    }

    #[tokio::test]
    async fn background_work_avoids_a_node_with_interactive_work() {
        let (a, b, pool) = two().await;
        rates(&a, 1000.0, 80.0);
        rates(&b, 1000.0, 40.0);
        pool.refresh().await;
        let bg = Call {
            background: true,
            ..call(1000)
        };
        assert_eq!(pool.schedule(Q4, &bg).unwrap().name, "a");
        // An interactive request is running on a (seen by its /node): background goes to b.
        a.edit(|v| {
            v["queue"]["running"] = json!([{"priority": "interactive", "prompt_tokens": 1000,
                "cached_tokens": 0, "prefilled_tokens": 1000, "generated_tokens": 10}]);
        });
        pool.refresh().await;
        assert_eq!(pool.schedule(Q4, &bg).unwrap().name, "b");
        // A queue of background work doesn't keep background off a node.
        a.edit(|v| {
            v["queue"]["running"] = json!([{"priority": "background", "prompt_tokens": 10,
                "cached_tokens": 0, "prefilled_tokens": 10, "generated_tokens": 290}]);
        });
        pool.refresh().await;
        assert_eq!(pool.schedule(Q4, &bg).unwrap().name, "a");
        // An interactive call the engine just placed on a, before any poll sees it.
        let at = pool.schedule(Q4, &call(1000)).unwrap();
        assert_eq!(at.name, "a");
        let flight = pool.begin(&at, false);
        assert_eq!(pool.schedule(Q4, &bg).unwrap().name, "b");
        drop(flight);
        assert_eq!(pool.schedule(Q4, &bg).unwrap().name, "a");
        // With every node busy, background still runs somewhere.
        b.edit(|v| {
            v["queue"]["waiting"] = json!([{"priority": "interactive", "prompt_tokens": 10}]);
        });
        let _f = pool.begin(&at, false);
        pool.refresh().await;
        assert!(pool.schedule(Q4, &bg).is_ok());
    }

    #[tokio::test]
    async fn a_pinned_node_that_is_not_the_one_paired_stops() {
        use fake::{Chat, paired, quick, spawn};
        let imposter = spawn(
            "0bad",
            999,
            vec![("org/Qwen3-4B", Q4, true)],
            Chat::Reply("x"),
        )
        .await;
        let good = spawn("fb", 1, vec![("org/Qwen3-4B", Q4, true)], Chat::Reply("x")).await;
        let pool = Pool::fixed(
            vec![
                paired("mew", "a11ce", &imposter),
                paired("box", "fb", &good),
            ],
            None,
            quick(),
        );
        pool.refresh().await;
        assert_eq!(
            pool.place(Q4, &["mew"]).unwrap_err(),
            "this isn't the mew you paired"
        );
        // Unpinned, the session runs on the node that is who it says.
        assert_eq!(pool.place(Q4, &[]).unwrap().name, "box");
    }

    /// The additivity check: the same work on one node and on two (the second slower). No
    /// case's median finish may get worse with the second node. Virtual time: each call takes
    /// what its node's true rates say, and a node runs its calls one after another.
    #[tokio::test]
    async fn a_second_node_never_makes_a_case_slower() {
        use fake::{Chat, paired, quick, spawn};
        const FAST: (f64, f64) = (2000.0, 60.0);
        const SLOW: (f64, f64) = (1000.0, 40.0);
        let a = spawn(
            "fa",
            100,
            vec![("org/Qwen3-4B", Q4, true)],
            Chat::Reply("x"),
        )
        .await;
        let b = spawn(
            "fb",
            100,
            vec![("org/Qwen3-4B", Q4, true)],
            Chat::Reply("x"),
        )
        .await;
        rates(&a, FAST.0, FAST.1);
        rates(&b, SLOW.0, SLOW.1);
        let truth = |id: &str| if id == "id-a" { FAST } else { SLOW };
        let secs = |id: &str, c: &Call| {
            let (p, d) = truth(id);
            let step = if c.background {
                Step::Background
            } else {
                c.step
            };
            c.prompt_tokens as f64 / p + step.default_output() / d
        };
        let median = |mut v: Vec<f64>| {
            v.sort_by(f64::total_cmp);
            v[v.len() / 2]
        };
        // Each case's call finish times.
        let run = |pool: Arc<Pool>, case: &str| {
            let mut busy: HashMap<String, f64> = HashMap::new();
            let mut done = Vec::new();
            let mut held = Vec::new();
            let mut last: Option<String> = None;
            let n = match case {
                "one session" => 8,
                "fan-out" => 4,
                _ => 6,
            };
            for i in 0..n {
                let prev = last.clone();
                let mut c = Call {
                    cache_key: None,
                    prompt_tokens: 4000,
                    step: if i % 2 == 0 { Step::Answer } else { Step::Tool },
                    ..Call::default()
                };
                c.background = match case {
                    "one session" => false,
                    "fan-out" => true,
                    // Background subagents with an interactive call in the middle.
                    _ => i != n / 2,
                };
                c.last = prev.as_deref();
                let at = pool.schedule(Q4, &c).unwrap();
                let took = secs(&at.node_id, &c);
                let finish = if case == "one session" {
                    took
                } else if !c.background {
                    // Interactive goes first on its node.
                    took
                } else {
                    let t = busy.entry(at.node_id.clone()).or_default();
                    *t += took;
                    *t
                };
                if case == "one session" {
                    last = Some(at.node_id.clone());
                } else {
                    held.push(pool.begin(&at, c.background));
                }
                if !c.background || case != "mixed" {
                    done.push(finish);
                }
            }
            drop(held);
            median(done)
        };
        for case in ["one session", "fan-out", "mixed"] {
            let one = Pool::fixed(vec![paired("a", "fa", &a)], None, quick());
            let two = Pool::fixed(
                vec![paired("a", "fa", &a), paired("b", "fb", &b)],
                None,
                quick(),
            );
            one.refresh().await;
            two.refresh().await;
            let (m1, m2) = (run(one, case), run(two, case));
            eprintln!(
                "additivity: {case:12} one node {m1:6.2}s  two nodes {m2:6.2}s  ({:.2}x)",
                m1 / m2
            );
            assert!(
                m2 <= m1 + 1e-9,
                "{case}: two nodes {m2:.2}s > one node {m1:.2}s"
            );
        }
    }
}
