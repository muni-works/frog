//! Compiled memory: named files kept in the model server's own recurrent-state heads (tang's
//! GDN memstore, `tang-llm serve --memory-layer N`), read and written by store ops the engine
//! runs internally, so remembering costs no context tokens.
//!
//! The server holds the store only for a session (keyed by `prompt_cache_key`, the session
//! id); between sessions it lives here, as a 768 KiB blob in the project's memory folder
//! (`compiled-memory.blob`, mode 0600, written atomically). Per session: probe, load the blob,
//! run ops (exporting the blob after each write, so a crash loses at most one op), export and
//! end. Design: `docs/design/compiled-memory.md`. At-rest encryption of the blob is a follow-up.
//!
//! Store values are token ids below 2^18 and the server takes nothing else; frog has no
//! tokenizer for tang models, so text is stored one UTF-8 byte per id (lossless, ids < 256).

use crate::provider::ToolSpec;
use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The model-facing tool.
pub const TOOL: &str = "Memory";
/// The blob's file name in the project's memory folder.
pub const BLOB_FILE: &str = "compiled-memory.blob";
/// Added to the system prompt while compiled memory is active.
pub const PROMPT: &str = "\nMemory holds named notes that persist across sessions in this project without using context; list it when earlier decisions or preferences might matter, and put durable facts there.\n";

/// `[memory] compiled = auto|on|off`.
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Compiled {
    /// Use it when the server offers it (only tang with `--memory-layer` does).
    #[default]
    Auto,
    /// Use it, and say so when the server doesn't offer it.
    On,
    /// Never: no probe, no tool.
    Off,
}

/// `[memory]` in config.toml.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Settings {
    #[serde(default)]
    pub compiled: Compiled,
}

/// Where a project's blob lives (the global memory folder for a chat).
pub fn blob_path(store: &crate::memory::Store) -> PathBuf {
    store
        .project_file(BLOB_FILE)
        .unwrap_or_else(|| store.folder().join(BLOB_FILE))
}

/// Text as store values: one id per UTF-8 byte.
pub fn encode(text: &str) -> Vec<u32> {
    text.bytes().map(u32::from).collect()
}

/// The inverse of [`encode`]; ids that aren't bytes (written by another client) show as U+FFFD.
pub fn decode(ids: &[u32]) -> String {
    let bytes: Vec<u8> = ids
        .iter()
        .map(|&i| u8::try_from(i).unwrap_or(0xff))
        .collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// The previous blob, if any.
pub fn read_blob(path: &Path) -> Result<Option<Vec<u8>>> {
    match std::fs::read(path) {
        Ok(b) => Ok(Some(b)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
    }
}

/// Replace the blob atomically: a 0600 temp file beside it, synced, then renamed over it. A
/// crash at any point leaves either the old blob or the new one, never a torn file.
pub fn write_blob(path: &Path, blob: &[u8]) -> Result<()> {
    use std::io::Write;
    let dir = path.parent().context("blob path has no folder")?;
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{BLOB_FILE}.{}.tmp", std::process::id()));
    let mut o = std::fs::OpenOptions::new();
    o.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut o, 0o600);
    let mut f = o
        .open(&tmp)
        .with_context(|| format!("writing {}", tmp.display()))?;
    f.write_all(blob)?;
    f.sync_all()?;
    drop(f);
    std::fs::rename(&tmp, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

/// Delete the blob (`frog memory clear`). Whether there was one.
pub fn clear(path: &Path) -> Result<bool> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e.into()),
    }
}

/// What `GET /v1/memory` returned.
#[derive(Debug, PartialEq, Eq)]
pub enum Export {
    Blob(Vec<u8>),
    /// 409: the store failed the server's audit; the reason it gave.
    Poisoned(String),
    /// 404: the server holds no store for the session (nothing was loaded or written).
    Missing,
}

/// The server's `/v1/memory*` endpoints.
#[derive(Clone)]
pub struct Remote {
    http: reqwest::Client,
    root: String,
    key: Option<String>,
}

impl Remote {
    /// `base` is the provider's base URL (with or without `/v1`); `key` its bearer key, which
    /// goes only where chat requests already go.
    pub fn new(http: reqwest::Client, base: &str, key: Option<String>) -> Self {
        let base = base.trim_end_matches('/');
        Self {
            http,
            root: base.strip_suffix("/v1").unwrap_or(base).to_string(),
            key,
        }
    }

    fn request(
        &self,
        method: reqwest::Method,
        path: &str,
        session: &str,
    ) -> reqwest::RequestBuilder {
        let mut rb = self
            .http
            .request(
                method,
                format!(
                    "{}/v1/memory{path}?prompt_cache_key={}",
                    self.root,
                    percent(session)
                ),
            )
            .header("x-prompt-cache-key", session)
            .timeout(Duration::from_secs(30));
        if let Some(k) = &self.key {
            rb = rb.bearer_auth(k);
        }
        rb
    }

    /// Whether the server keeps memory: a read-only `list` on a fresh key. A server without
    /// the feature answers 404 (as does one with it for a `GET /v1/memory` of a key with no
    /// store yet, which is why the probe is a `list`). It changes nothing on the server.
    pub async fn probe(&self, session: &str) -> bool {
        let rb = self
            .request(reqwest::Method::POST, "/op", session)
            .timeout(Duration::from_secs(3))
            .json(&json!({ "op": "list" }));
        rb.send().await.is_ok_and(|r| r.status().is_success())
    }

    pub async fn load(&self, session: &str, blob: &[u8]) -> Result<()> {
        let r = self
            .request(reqwest::Method::POST, "/load", session)
            .header("content-type", "application/octet-stream")
            .body(blob.to_vec())
            .send()
            .await?;
        check(r).await.map(drop)
    }

    pub async fn export(&self, session: &str) -> Result<Export> {
        let r = self
            .request(reqwest::Method::GET, "", session)
            .send()
            .await?;
        match r.status().as_u16() {
            404 => Ok(Export::Missing),
            409 => Ok(Export::Poisoned(r.text().await.unwrap_or_default())),
            _ => Ok(Export::Blob(check(r).await?.bytes().await?.to_vec())),
        }
    }

    /// `POST /v1/memory/op`: `{op, name, ids}` → the server's JSON reply.
    pub async fn op(&self, session: &str, op: &Value) -> Result<Value> {
        let r = self
            .request(reqwest::Method::POST, "/op", session)
            .json(op)
            .send()
            .await?;
        Ok(check(r).await?.json().await?)
    }

    pub async fn end(&self, session: &str) -> Result<()> {
        let r = self
            .request(reqwest::Method::POST, "/end", session)
            .json(&json!({ "prompt_cache_key": session }))
            .send()
            .await?;
        check(r).await.map(drop)
    }
}

/// `s` as a query value: everything but unreserved characters percent-encoded.
fn percent(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

async fn check(r: reqwest::Response) -> Result<reqwest::Response> {
    let status = r.status();
    if status.is_success() {
        return Ok(r);
    }
    let body = r.text().await.unwrap_or_default();
    bail!("memory server answered {status}: {}", body.trim())
}

/// Compiled memory for one session: the server's copy keyed by `key`, the blob at `blob`.
pub struct Session {
    remote: Remote,
    key: String,
    blob: PathBuf,
}

impl Session {
    /// Probe and load. `Ok(None)`: not in use (off, or the server doesn't offer it under
    /// `auto`), and nothing was sent beyond the probe. `Err`: it should be in use and isn't
    /// (`on` without server support, or the server refused the saved blob); the blob is left
    /// as it was, and text memory carries on alone.
    pub async fn start(
        setting: Compiled,
        remote: Remote,
        key: &str,
        blob: PathBuf,
    ) -> Result<Option<Self>> {
        if setting == Compiled::Off {
            return Ok(None);
        }
        if !remote.probe(key).await {
            if setting == Compiled::On {
                bail!(
                    "[memory] compiled = \"on\", but this model's server keeps no memory (tang-llm serve --memory-layer N does)"
                );
            }
            return Ok(None);
        }
        if let Some(b) = read_blob(&blob)? {
            remote.load(key, &b).await.with_context(|| {
                format!(
                    "compiled memory is off this session: the server refused {}",
                    blob.display()
                )
            })?;
        }
        Ok(Some(Self {
            remote,
            key: key.to_string(),
            blob,
        }))
    }

    pub fn blob(&self) -> &Path {
        &self.blob
    }

    /// Export the server's store into the blob. `Some(notice)`: it couldn't, and the last
    /// good blob was kept.
    pub async fn save(&self) -> Option<String> {
        match self.remote.export(&self.key).await {
            Ok(Export::Blob(b)) => write_blob(&self.blob, &b)
                .err()
                .map(|e| format!("Couldn't save compiled memory: {e:#}")),
            Ok(Export::Missing) => None,
            Ok(Export::Poisoned(why)) => Some(format!(
                "The server's memory store failed its audit ({}); kept the last good copy at {}.",
                why.trim(),
                self.blob.display()
            )),
            Err(e) => Some(format!(
                "Couldn't export compiled memory ({e:#}); kept the last good copy at {}.",
                self.blob.display()
            )),
        }
    }

    /// Run one tool call: the model's text and, if saving failed, a notice for the user.
    pub async fn run(&self, input: &Value) -> Result<(String, Option<String>)> {
        let action = input["action"].as_str().unwrap_or("");
        let name = input["name"].as_str().unwrap_or("").trim();
        if action != "list" && name.is_empty() {
            bail!("{action} needs a `name`");
        }
        match action {
            "list" => {
                let v = self.remote.op(&self.key, &json!({ "op": "list" })).await?;
                Ok((render_list(&v), None))
            }
            "get" => {
                let v = self
                    .remote
                    .op(&self.key, &json!({ "op": "get", "name": name }))
                    .await?;
                Ok((render_get(name, &v), None))
            }
            "put" => {
                let text = input["text"].as_str().context("put needs `text`")?;
                let op = json!({ "op": "put", "name": name, "ids": encode(text) });
                self.remote.op(&self.key, &op).await?;
                let notice = self.save().await;
                Ok((format!("Saved {name} ({} bytes).", text.len()), notice))
            }
            "delete" => {
                let v = self
                    .remote
                    .op(&self.key, &json!({ "op": "delete", "name": name }))
                    .await?;
                if v["deleted"].as_bool() != Some(true) {
                    return Ok((format!("No file named {name}."), None));
                }
                let notice = self.save().await;
                Ok((format!("Deleted {name}."), notice))
            }
            a => bail!("action must be list, get, put or delete, not `{a}`"),
        }
    }

    /// Session end: export into the blob, then end the server's session (dropping its copy).
    pub async fn finish(self) -> Option<String> {
        let notice = self.save().await;
        let _ = self.remote.end(&self.key).await;
        notice
    }
}

fn render_list(v: &Value) -> String {
    let files = v["files"].as_array().cloned().unwrap_or_default();
    if files.is_empty() {
        return "Memory is empty.".into();
    }
    files
        .iter()
        .map(|f| {
            format!(
                "{} ({} bytes)",
                f["name"].as_str().unwrap_or("?"),
                f["tokens"].as_u64().unwrap_or(0)
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn ids(v: &Value) -> Vec<u32> {
    v["ids"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_u64())
                .map(|x| x as u32)
                .collect()
        })
        .unwrap_or_default()
}

fn render_get(name: &str, v: &Value) -> String {
    if v["found"].as_bool() != Some(true) {
        return format!("No file named {name}.");
    }
    decode(&ids(v))
}

/// Whether a call only reads (list/get), so it runs without asking, like Read.
pub fn is_read(input: &Value) -> bool {
    matches!(input["action"].as_str(), Some("list" | "get"))
}

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Persistent memory for this project, kept by the model server outside your context window: named text files that survive across sessions. `list` shows the files, `get` reads one, `put` writes one (replacing it), `delete` removes one. Keep durable facts (conventions, decisions, the user's preferences), not transcripts.".into(),
        schema: json!({
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["list", "get", "put", "delete"]},
                "name": {"type": "string", "description": "The file's name, e.g. `build-commands`"},
                "text": {"type": "string", "description": "For put: the file's whole new contents"}
            },
            "required": ["action"]
        }),
    }
}

/// A throwaway server session for the `frog memory` commands, ended however they go.
fn cli_key() -> String {
    let n = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("frog-memory-cli-{}-{n}", std::process::id())
}

/// `frog memory dump`: every file in the blob as `(name, text)`. The blob can only be read by
/// the model that wrote it, so this loads it into a throwaway session on that server.
pub async fn dump(remote: &Remote, blob: &[u8]) -> Result<Vec<(String, String)>> {
    let key = cli_key();
    let out = async {
        remote.load(&key, blob).await?;
        let listed = remote.op(&key, &json!({ "op": "list" })).await?;
        let mut files = Vec::new();
        for f in listed["files"].as_array().cloned().unwrap_or_default() {
            let name = f["name"].as_str().unwrap_or_default().to_string();
            let v = remote
                .op(&key, &json!({ "op": "get", "name": name }))
                .await?;
            files.push((name, decode(&ids(&v))));
        }
        Ok(files)
    }
    .await;
    let _ = remote.end(&key).await;
    out
}

/// `frog memory forget <name>`: delete one file from the blob. Whether it was there.
pub async fn forget(remote: &Remote, path: &Path, name: &str) -> Result<bool> {
    let Some(blob) = read_blob(path)? else {
        return Ok(false);
    };
    let key = cli_key();
    let out = async {
        remote.load(&key, &blob).await?;
        let v = remote
            .op(&key, &json!({ "op": "delete", "name": name }))
            .await?;
        if v["deleted"].as_bool() != Some(true) {
            return Ok(false);
        }
        match remote.export(&key).await? {
            Export::Blob(b) => write_blob(path, &b)?,
            Export::Poisoned(why) => bail!(
                "the store failed its audit ({}); blob unchanged",
                why.trim()
            ),
            Export::Missing => bail!("the server lost the store; blob unchanged"),
        }
        Ok(true)
    }
    .await;
    let _ = remote.end(&key).await;
    out
}

#[cfg(test)]
pub(crate) mod mock {
    //! A fake tang memory server: the store is a name → ids map, and its "blob" is that map
    //! as JSON (frog treats blobs as opaque bytes, so any encoding will do).
    use serde_json::{Value, json};
    use std::collections::{BTreeMap, HashMap};
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[derive(Default)]
    pub struct State {
        /// Answer 404 to everything, as a server without `--memory-layer`.
        pub disabled: bool,
        /// Answer 409 to exports, as when the store fails its audit.
        pub poisoned: bool,
        pub stores: HashMap<String, BTreeMap<String, Vec<u32>>>,
        /// Every request line, in order.
        pub log: Vec<String>,
    }

    pub async fn serve(state: Arc<Mutex<State>>) -> String {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let state = state.clone();
                tokio::spawn(async move {
                    let mut buf = Vec::new();
                    let (head, body) = loop {
                        let mut chunk = [0u8; 65536];
                        let n = sock.read(&mut chunk).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        buf.extend_from_slice(&chunk[..n]);
                        let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") else {
                            continue;
                        };
                        let head = String::from_utf8_lossy(&buf[..end]).to_string();
                        let len: usize = head
                            .lines()
                            .find_map(|l| {
                                l.to_ascii_lowercase()
                                    .strip_prefix("content-length: ")
                                    .map(|s| s.trim().parse().unwrap())
                            })
                            .unwrap_or(0);
                        if buf.len() >= end + 4 + len {
                            break (head, buf[end + 4..end + 4 + len].to_vec());
                        }
                    };
                    let (status, reply) = handle(&mut state.lock().unwrap(), &head, &body);
                    let resp = format!(
                        "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        reply.len()
                    );
                    let _ = sock.write_all(resp.as_bytes()).await;
                    let _ = sock.write_all(&reply).await;
                });
            }
        });
        format!("http://{addr}/v1")
    }

    fn handle(s: &mut State, head: &str, body: &[u8]) -> (u16, Vec<u8>) {
        let line = head.lines().next().unwrap_or("").to_string();
        s.log.push(line.clone());
        if s.disabled {
            return (404, b"not found".to_vec());
        }
        let mut parts = line.split_whitespace();
        let (method, target) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
        let (path, query) = target.split_once('?').unwrap_or((target, ""));
        let key = query
            .strip_prefix("prompt_cache_key=")
            .unwrap_or("")
            .to_string();
        let j = |v: Value| (200, v.to_string().into_bytes());
        match (method, path) {
            ("POST", "/v1/memory/load") => match serde_json::from_slice(body) {
                Ok(m) => {
                    s.stores.insert(key, m);
                    j(json!({ "loaded": true }))
                }
                Err(_) => (400, b"bad blob".to_vec()),
            },
            ("GET", "/v1/memory") => match s.stores.get(&key) {
                None => (404, b"no store".to_vec()),
                Some(_) if s.poisoned => (409, b"heads [12] poisoned".to_vec()),
                Some(m) => (200, serde_json::to_vec(m).unwrap()),
            },
            ("POST", "/v1/memory/op") => {
                let v: Value = serde_json::from_slice(body).unwrap();
                let name = v["name"].as_str().unwrap_or("").to_string();
                match v["op"].as_str().unwrap() {
                    "list" => {
                        let files: Vec<Value> = s
                            .stores
                            .get(&key)
                            .map(|m| {
                                m.iter()
                                    .map(|(n, ids)| json!({ "name": n, "tokens": ids.len() }))
                                    .collect()
                            })
                            .unwrap_or_default();
                        j(json!({ "files": files }))
                    }
                    "get" => {
                        let ids = s.stores.get(&key).and_then(|m| m.get(&name)).cloned();
                        j(json!({ "found": ids.is_some(), "ids": ids }))
                    }
                    "put" => {
                        let ids = v["ids"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(|x| x.as_u64().unwrap() as u32)
                            .collect();
                        s.stores.entry(key).or_default().insert(name, ids);
                        j(json!({ "ok": true }))
                    }
                    "delete" => {
                        let d = s
                            .stores
                            .get_mut(&key)
                            .is_some_and(|m| m.remove(&name).is_some());
                        j(json!({ "deleted": d }))
                    }
                    _ => (400, Vec::new()),
                }
            }
            ("POST", "/v1/memory/end") => {
                let had = s.stores.remove(&key).is_some();
                j(json!({ "had_store": had }))
            }
            _ => (404, Vec::new()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::mock::{State, serve};
    use super::*;
    use std::sync::{Arc, Mutex};

    async fn server(f: impl FnOnce(&mut State)) -> (Arc<Mutex<State>>, Remote) {
        let state = Arc::new(Mutex::new(State::default()));
        f(&mut state.lock().unwrap());
        let base = serve(state.clone()).await;
        (state, Remote::new(reqwest::Client::new(), &base, None))
    }

    #[test]
    fn text_round_trips_as_byte_ids() {
        let s = "héllo 🐸\nline two";
        let ids = encode(s);
        assert!(ids.iter().all(|&i| i < 256));
        assert_eq!(decode(&ids), s);
    }

    #[tokio::test]
    async fn probe_follows_the_server() {
        let (_, on) = server(|_| {}).await;
        assert!(on.probe("k").await);
        let (_, off) = server(|s| s.disabled = true).await;
        assert!(!off.probe("k").await);
    }

    #[tokio::test]
    async fn load_op_export_round_trip() {
        let dir = tempfile::tempdir().unwrap();
        let blob = dir.path().join(BLOB_FILE);
        let (state, remote) = server(|_| {}).await;
        let s = Session::start(Compiled::Auto, remote.clone(), "s1", blob.clone())
            .await
            .unwrap()
            .expect("active");
        let put = json!({ "action": "put", "name": "build", "text": "cargo test -p frog-engine" });
        let (out, notice) = s.run(&put).await.unwrap();
        assert_eq!((out.as_str(), notice), ("Saved build (25 bytes).", None));
        // Saved after the write, before the session ends: a crash now keeps it.
        assert!(blob.exists());
        let (listed, _) = s.run(&json!({ "action": "list" })).await.unwrap();
        assert_eq!(listed, "build (25 bytes)");
        assert_eq!(s.finish().await, None);
        assert!(state.lock().unwrap().stores.is_empty(), "the session ended");

        // The next session loads it back.
        let s = Session::start(Compiled::Auto, remote.clone(), "s2", blob.clone())
            .await
            .unwrap()
            .unwrap();
        let (got, _) = s
            .run(&json!({ "action": "get", "name": "build" }))
            .await
            .unwrap();
        assert_eq!(got, "cargo test -p frog-engine");
        let (d, _) = s
            .run(&json!({ "action": "delete", "name": "build" }))
            .await
            .unwrap();
        assert_eq!(d, "Deleted build.");
        s.finish().await;
        assert_eq!(
            dump(&remote, &std::fs::read(&blob).unwrap()).await.unwrap(),
            vec![]
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&blob).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o600);
        }
    }

    #[tokio::test]
    async fn unsupported_server_leaves_everything_alone() {
        let dir = tempfile::tempdir().unwrap();
        let blob = dir.path().join(BLOB_FILE);
        std::fs::write(&blob, b"old").unwrap();
        let (state, remote) = server(|s| s.disabled = true).await;
        let s = Session::start(Compiled::Auto, remote.clone(), "k", blob.clone()).await;
        assert!(s.unwrap().is_none());
        // Only the probe went out; the blob is untouched.
        assert_eq!(state.lock().unwrap().log.len(), 1);
        assert_eq!(std::fs::read(&blob).unwrap(), b"old");
        // `on` says why instead.
        let e = Session::start(Compiled::On, remote.clone(), "k", blob.clone()).await;
        assert!(format!("{:#}", e.err().unwrap()).contains("keeps no memory"));
        // `off` doesn't even probe.
        let s = Session::start(Compiled::Off, remote, "k", blob).await;
        assert!(s.unwrap().is_none());
        assert_eq!(state.lock().unwrap().log.len(), 2);
    }

    #[tokio::test]
    async fn poisoned_export_keeps_the_last_good_blob() {
        let dir = tempfile::tempdir().unwrap();
        let blob = dir.path().join(BLOB_FILE);
        let good = serde_json::to_vec(&json!({ "a": encode("one") })).unwrap();
        write_blob(&blob, &good).unwrap();
        let (state, remote) = server(|_| {}).await;
        let s = Session::start(Compiled::Auto, remote, "k", blob.clone())
            .await
            .unwrap()
            .unwrap();
        state.lock().unwrap().poisoned = true;
        let put = json!({ "action": "put", "name": "b", "text": "two" });
        let (_, notice) = s.run(&put).await.unwrap();
        assert!(notice.unwrap().contains("failed its audit"));
        assert_eq!(std::fs::read(&blob).unwrap(), good);
        assert!(
            s.finish()
                .await
                .unwrap()
                .contains("kept the last good copy")
        );
        assert_eq!(std::fs::read(&blob).unwrap(), good);
    }

    #[tokio::test]
    async fn a_refused_blob_is_not_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let blob = dir.path().join(BLOB_FILE);
        std::fs::write(&blob, b"not a store").unwrap();
        let (_, remote) = server(|_| {}).await;
        let e = Session::start(Compiled::Auto, remote, "k", blob.clone()).await;
        assert!(e.is_err());
        assert_eq!(std::fs::read(&blob).unwrap(), b"not a store");
    }

    #[test]
    fn a_crash_mid_write_leaves_the_old_blob() {
        let dir = tempfile::tempdir().unwrap();
        let blob = dir.path().join(BLOB_FILE);
        write_blob(&blob, b"first").unwrap();
        // A write that died before its rename: a torn temp file beside the blob.
        let tmp = dir
            .path()
            .join(format!(".{BLOB_FILE}.{}.tmp", std::process::id()));
        std::fs::write(&tmp, b"fir").unwrap();
        assert_eq!(read_blob(&blob).unwrap().unwrap(), b"first");
        // The next write replaces both.
        write_blob(&blob, b"second").unwrap();
        assert_eq!(read_blob(&blob).unwrap().unwrap(), b"second");
        assert!(!tmp.exists());
        assert!(clear(&blob).unwrap());
        assert!(!clear(&blob).unwrap());
    }

    #[tokio::test]
    async fn cli_forget_and_dump() {
        let dir = tempfile::tempdir().unwrap();
        let blob = dir.path().join(BLOB_FILE);
        let m = json!({ "a": encode("alpha"), "b": encode("beta") });
        write_blob(&blob, &serde_json::to_vec(&m).unwrap()).unwrap();
        let (state, remote) = server(|_| {}).await;
        assert!(forget(&remote, &blob, "a").await.unwrap());
        assert!(!forget(&remote, &blob, "a").await.unwrap());
        let files = dump(&remote, &read_blob(&blob).unwrap().unwrap())
            .await
            .unwrap();
        assert_eq!(files, vec![("b".to_string(), "beta".to_string())]);
        assert!(
            state.lock().unwrap().stores.is_empty(),
            "throwaway sessions end"
        );
    }
}
