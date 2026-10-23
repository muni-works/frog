//! MCP OAuth: sign a server's user in with a browser when the server answers 401.
//!
//! The streamable-HTTP transport connects unauthenticated; when the server answers `401`
//! with a `WWW-Authenticate` challenge, [`authorize`] runs the MCP authorization flow
//! (2025-06-18 §authorization): protected-resource metadata (RFC 9728) names the
//! authorization server, that server's metadata (RFC 8414) names the endpoints, dynamic
//! client registration (RFC 7591) gets frog a client identity, a loopback redirect on
//! `127.0.0.1` is caught by a short-lived local listener, and the code is exchanged with
//! PKCE (S256). Tokens go to the Keychain keyed by the **server name**, never the URL —
//! a look-alike redirect can't hand one server's tokens to another — and the next connect
//! sends `Authorization: Bearer`. Mid-session 401s refresh once, transparently, and retry
//! (see `mcp::connect_one`); a refresh that fails names the server and asks to reconnect.
//!
//! Nothing here touches the MCP server's JSON-RPC surface: plain HTTP plus a browser. The
//! open-in-browser step takes [`Browser`] so tests can drive the redirect themselves.

use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How long the whole browser sign-in may take: the user finds the window, signs in,
/// maybe answers a second factor. Past this the server stays disconnected; the session
/// never waited on it (`connect_one` runs in the background).
pub const AUTH_TIMEOUT: Duration = Duration::from_secs(15 * 60);

/// Opens a URL in a browser; overridable so tests can skip the real browser.
pub type Browser = Arc<dyn Fn(String) + Send + Sync>;

/// Whether OAuth can ever be needed for a configured server: an HTTP server without a
/// configured `Authorization` header. The header is the escape hatch — a `${VAR}` in it
/// counts as configured whether or not the variable is set. (The 401 path decides the
/// rest; this documents and pins the precedence the connect path relies on.)
#[cfg(test)]
pub(crate) fn authorize_url(
    url: Option<&str>,
    headers: &std::collections::BTreeMap<String, String>,
) -> Option<String> {
    let url = url?;
    let configured = headers
        .iter()
        .any(|(k, _)| k.eq_ignore_ascii_case("authorization"));
    (!configured).then(|| url.to_string())
}

/// The browser frog opens on macOS.
pub fn system_browser() -> Browser {
    Arc::new(|url: String| {
        let _ = std::process::Command::new("open").arg(url).spawn();
    })
}

// ---- discovery ---------------------------------------------------------

/// The endpoints (and scopes) a flow needs, from either well-known document.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Metadata {
    #[serde(default)]
    pub issuer: Option<String>,
    #[serde(default)]
    pub authorization_endpoint: String,
    #[serde(default)]
    pub token_endpoint: String,
    #[serde(default)]
    pub registration_endpoint: Option<String>,
    #[serde(default)]
    pub scopes_supported: Option<Vec<String>>,
}

#[derive(Deserialize)]
struct ResourceMetadata {
    #[serde(default)]
    authorization_servers: Vec<String>,
}

/// Discover the authorization server's metadata for the MCP server at `url`.
///
/// The spec's order: the protected-resource metadata on the resource's origin (or the URL
/// the `WWW-Authenticate` challenge named, when it did) names the authorization servers;
/// each candidate then publishes its own metadata document. With no resource metadata at
/// all, the resource's own origin is tried as the authorization server — an older layout
/// that still answers the same document. A `scope` hint in the challenge wins over
/// `scopes_supported`.
pub async fn discover(http: &reqwest::Client, url: &str, challenge: Option<&str>) -> Result<Metadata> {
    let challenge_url = challenge.and_then(|c| resource_metadata_url(c, url));
    let challenge_scopes: Option<Vec<String>> = challenge
        .and_then(|c| param(c, "scope"))
        .map(|s| s.split_whitespace().map(str::to_string).collect());

    let mut servers: Vec<String> = Vec::new();
    let mut probes = well_known_candidates(url, "oauth-protected-resource");
    probes.extend(challenge_url);
    for candidate in probes {
        if let Some(doc) = fetch_json::<ResourceMetadata>(http, &candidate).await {
            servers = doc.authorization_servers;
        }
        if !servers.is_empty() {
            break;
        }
    }
    if servers.is_empty() {
        // No resource metadata anywhere: the MCP server itself may be the authorization
        // server.
        servers.push(origin(url).with_context(|| format!("parsing {url}"))?);
    }

    for server in &servers {
        for candidate in well_known_candidates(server, "oauth-authorization-server") {
            if let Some(m) = fetch_json::<Metadata>(http, &candidate).await
                && !m.authorization_endpoint.is_empty()
                && !m.token_endpoint.is_empty()
            {
                return Ok(Metadata {
                    scopes_supported: challenge_scopes.clone().or(m.scopes_supported),
                    ..m
                });
            }
        }
    }
    bail!("no OAuth metadata: the server's authorization server published none")
}

/// `resource_metadata="…"` out of a `WWW-Authenticate` header, resolved against `base`.
fn resource_metadata_url(header: &str, base: &str) -> Option<String> {
    let raw = param(header, "resource_metadata")?;
    if raw.starts_with("http://") || raw.starts_with("https://") {
        return Some(raw);
    }
    let base = origin(base)?;
    Some(format!("{}/{}", base.trim_end_matches('/'), raw.trim_start_matches('/')))
}

/// One `key="value"` (or bare `key=value`) parameter of a challenge header. A leading
/// scheme word (`Bearer`) is ignored.
fn param(header: &str, key: &str) -> Option<String> {
    for part in header.split(',') {
        let part = part.trim();
        let Some((k, v)) = part.split_once('=') else { continue };
        let mut k = k.trim();
        if let Some(rest) = k
            .strip_prefix("Bearer ")
            .or_else(|| k.strip_prefix("bearer "))
        {
            k = rest.trim();
        }
        if k.eq_ignore_ascii_case(key) {
            return Some(v.trim().trim_matches('"').to_string());
        }
    }
    None
}

/// Well-known URLs to probe for `name` (RFC 8414 §3.1 / RFC 9728 §3.1): the path-aware
/// insert first when the URL has a path, then the root form. Canonical last so a server
/// that bothers with the standard document wins.
fn well_known_candidates(url: &str, name: &str) -> Vec<String> {
    let Some(base) = origin(url) else {
        return Vec::new();
    };
    let (_, rest) = url.split_once("://").unwrap_or(("", ""));
    let path = rest
        .split_once('/')
        .map(|(_, p)| p.trim_end_matches('/').to_string())
        .unwrap_or_default();
    let mut out = Vec::new();
    if !path.is_empty() {
        out.push(format!("{base}/.well-known/{name}/{path}"));
    }
    out.push(format!("{base}/.well-known/{name}"));
    out
}

async fn fetch_json<T: serde::de::DeserializeOwned>(http: &reqwest::Client, url: &str) -> Option<T> {
    let Ok(response) = http.get(url).send().await else {
        return None;
    };
    if !response.status().is_success() {
        return None;
    }
    serde_json::from_str(&response.text().await.ok()?).ok()
}

/// Scheme + host + port of a URL, no path.
fn origin(url: &str) -> Option<String> {
    let (scheme, rest) = url.split_once("://")?;
    let host = rest.split(['/', '?', '#']).next()?;
    (!host.is_empty()).then(|| format!("{scheme}://{host}"))
}

// ---- tokens ------------------------------------------------------------

/// Tokens a server connection uses, stored per server name.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tokens {
    pub client_id: String,
    /// The authorization server the tokens came from; discovery pointing elsewhere
    /// invalidates them.
    pub issuer: Option<String>,
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    /// Epoch seconds the access token expires at, when the server said.
    #[serde(default)]
    pub expires_at: Option<u64>,
    /// Scopes the server granted.
    #[serde(default)]
    pub scopes: Vec<String>,
}

fn key(server: &str) -> String {
    format!("mcp-oauth:{server}")
}

/// Stored tokens for `server` (Keychain, keyed by the server's name). Tests swap the
/// store out for memory with `use_memory_store`.
pub fn stored(server: &str) -> Option<Tokens> {
    let text = mem_store()
        .and_then(|m| m.lock().unwrap().get(server).cloned())
        .or_else(|| crate::mcp::keychain_get(&key(server)))?;
    // Values are stored base64-encoded: the `security` CLI behind the Keychain rejects
    // quotes and other JSON punctuation, so tokens always travel encoded.
    let json = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(text.trim())
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .unwrap_or(text);
    serde_json::from_str(&json).ok()
}

/// Remember `server`'s tokens.
pub fn save(server: &str, tokens: &Tokens) -> Result<()> {
    let json = serde_json::to_string(tokens).context("serializing tokens")?;
    let text = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(json.as_bytes());
    if let Some(memory) = mem_store() {
        memory.lock().unwrap().insert(server.to_string(), text);
        return Ok(());
    }
    crate::mcp::keychain_set(&key(server), &text)
}

/// Forget a server's tokens.
pub fn clear(server: &str) {
    if let Some(memory) = mem_store() {
        memory.lock().unwrap().remove(server);
        return;
    }
    crate::mcp::keychain_delete(&key(server));
}

/// The tests' in-memory stand-in for the Keychain.
type Memory = Arc<Mutex<std::collections::BTreeMap<String, String>>>;

static TEST_STORE: Mutex<Option<Memory>> = Mutex::new(None);

fn mem_store() -> Option<Memory> {
    TEST_STORE.lock().unwrap().clone()
}

/// Route token storage to memory (tests) instead of the Keychain. Idempotent.
#[cfg(test)]
pub(crate) fn use_memory_store() -> Memory {
    let mut guard = TEST_STORE.lock().unwrap();
    guard
        .get_or_insert_with(|| Arc::new(Mutex::new(std::collections::BTreeMap::new())))
        .clone()
}

fn now_epoch() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// An `Authorization: Bearer …` header for `server`, when its access token isn't near
/// expiry. Revoked tokens are the 401 path's problem; near-expiry ones are [`refresh`]'s.
pub fn bearer(server: &str) -> Option<String> {
    let tokens = stored(server)?;
    if let Some(at) = tokens.expires_at
        && now_epoch() + 30 >= at
    {
        return None;
    }
    Some(format!("Bearer {}", tokens.access_token))
}

// ---- PKCE --------------------------------------------------------------

struct Pkce {
    verifier: String,
    challenge: String,
}

impl Pkce {
    /// RFC 7636 §4.1: 32 random bytes, base64url; the challenge is their SHA-256.
    fn new() -> Result<Self> {
        let mut bytes = [0u8; 32];
        fill_random(&mut bytes)?;
        Self::from_verifier_ok(base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes))
    }

    fn from_verifier_ok(verifier: String) -> Result<Self> {
        let digest = Sha256::digest(verifier.as_bytes());
        Ok(Self {
            verifier,
            challenge: base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest),
        })
    }
}

/// Fill `buf` from the OS entropy pool (`/dev/urandom` on macOS and Linux).
fn fill_random(buf: &mut [u8]) -> Result<()> {
    use std::io::Read;
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(buf))
        .map_err(|e| anyhow!("reading OS entropy: {e}"))
}

// ---- registration + exchange -------------------------------------------

#[derive(Serialize)]
struct Registration<'a> {
    client_name: String,
    redirect_uris: Vec<&'a str>,
    grant_types: [&'static str; 2],
    response_types: [&'static str; 1],
    #[serde(skip_serializing_if = "Option::is_none")]
    scope: Option<String>,
    token_endpoint_auth_method: &'static str,
}

#[derive(Deserialize)]
struct RegistrationReply {
    client_id: String,
    #[serde(default)]
    client_secret: Option<String>,
}

#[derive(Deserialize)]
struct TokenReply {
    access_token: String,
    #[serde(default, alias = "refreshToken")]
    refresh_token: Option<String>,
    #[serde(default)]
    expires_in: Option<u64>,
    #[serde(default)]
    scope: Option<String>,
}

/// RFC 7591 dynamic client registration; frog registers as a public client.
async fn register(
    http: &reqwest::Client,
    endpoint: &str,
    name: &str,
    redirect: &str,
    scopes: &[String],
) -> Result<(String, Option<String>)> {
    let body = Registration {
        client_name: name.to_string(),
        redirect_uris: vec![redirect],
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"],
        scope: (!scopes.is_empty()).then(|| scopes.join(" ")),
        token_endpoint_auth_method: "none",
    };
    let response = http
        .post(endpoint)
        .json(&body)
        .send()
        .await
        .with_context(|| format!("registering at {endpoint}"))?;
    let status = response.status();
    let text = response.text().await.unwrap_or_default();
    if !status.is_success() {
        bail!("registration failed: HTTP {status}: {}", clip(&text, 200));
    }
    let reply: RegistrationReply =
        serde_json::from_str(&text).context("reading the registration reply")?;
    Ok((
        reply.client_id,
        reply.client_secret.filter(|s| !s.is_empty()),
    ))
}

/// POST a token request; `form` is the OAuth parameters, sent as
/// `application/x-www-form-urlencoded` (RFC 6749 §4.1.3).
async fn token_request(
    http: &reqwest::Client,
    token_endpoint: &str,
    form: &[(&str, &str)],
) -> Result<TokenReply> {
    let body = body(form);
    let response = http
        .post(token_endpoint)
        .header("content-type", "application/x-www-form-urlencoded")
        .body(body)
        .send()
        .await
        .with_context(|| format!("calling {token_endpoint}"))?;
    let status = response.status();
    let text = response.text().await.unwrap_or_default();
    if !status.is_success() {
        bail!("token request failed: HTTP {status}: {}", clip(&text, 200));
    }
    serde_json::from_str(&text).context("reading the token reply")
}

/// Percent-encode one string for a query or form body (RFC 3986: unreserved chars pass).
fn encoded(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for byte in s.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(*byte as char)
            }
            other => out.push_str(&format!("%{other:02X}")),
        }
    }
    out
}

/// `form` as an urlencoded body: `k=v` pairs with keys and values percent-encoded.
fn body<'a>(form: &[(&'a str, &'a str)]) -> String {
    form.iter()
        .map(|(k, v)| format!("{}={}", encoded(k), encoded(v)))
        .collect::<Vec<_>>()
        .join("&")
}

/// Attach query pairs to a URL that may already carry a `?`.
fn join_query(url: &str, pairs: &[(&str, String)]) -> String {
    let query = pairs
        .iter()
        .map(|(k, v)| format!("{}={}", encoded(k), encoded(v)))
        .collect::<Vec<_>>()
        .join("&");
    if url.contains('?') {
        format!("{url}&{query}")
    } else {
        format!("{url}?{query}")
    }
}

/// Parse a query string into (`key`, `value`) pairs, percent-decoded (`+` is a space).
fn parse_query(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter(|p| !p.is_empty())
        .map(|pair| match pair.split_once('=') {
            Some((k, v)) => (decode(k), decode(v)),
            None => (decode(pair), String::new()),
        })
        .collect()
}

fn decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("");
                match u8::from_str_radix(hex, 16) {
                    Ok(b) => {
                        out.push(b);
                        i += 3;
                    }
                    Err(_) => {
                        out.push(b'%');
                        i += 1;
                    }
                }
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn clip(s: &str, n: usize) -> &str {
    let end = s.char_indices().nth(n).map(|(i, _)| i).unwrap_or(s.len());
    &s[..end]
}

// ---- signing in --------------------------------------------------------

/// Sign the user in to `url` for the server `name`, and store the tokens for next time.
///
/// `challenge` is the server's `WWW-Authenticate` header when it sent one (it may name the
/// resource-metadata URL and scopes directly), `None` when the 401 arrived folded inside a
/// transport error. `open` opens the browser; tests pass their own and drive the redirect.
/// Returns the tokens (which are already stored for [`bearer`]/[`refresh`]).
pub async fn authorize(
    http: &reqwest::Client,
    name: &str,
    url: &str,
    challenge: Option<&str>,
    open: Browser,
    timeout: Duration,
) -> Result<Tokens> {
    let metadata = discover(http, url, challenge).await?;
    let Some(registration) = &metadata.registration_endpoint else {
        bail!(
            "the server's authorization server has no dynamic registration endpoint, so frog can't sign you in to it"
        );
    };

    // A loopback listener on a random free port is the redirect target; it lives exactly
    // as long as the flow does.
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .context("opening a loopback listener")?;
    let port = listener.local_addr()?.port();
    let redirect = format!("http://127.0.0.1:{port}/callback");

    let scopes: Vec<String> = metadata
        .scopes_supported
        .iter()
        .flatten()
        .filter(|s| s.as_str() != "offline_access")
        .cloned()
        .collect();
    let (client_id, client_secret) =
        register(http, registration, "frog (MCP)", &redirect, &scopes).await?;

    // The authorization URL, with PKCE and state.
    let pkce = Pkce::new()?;
    let mut state = [0u8; 24];
    fill_random(&mut state)?;
    let state = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(state);
    let mut pairs: Vec<(&str, String)> = vec![
        ("response_type", "code".into()),
        ("client_id", client_id.clone()),
        ("redirect_uri", redirect.clone()),
        ("state", state.clone()),
        ("code_challenge", pkce.challenge.clone()),
        ("code_challenge_method", "S256".into()),
    ];
    if !scopes.is_empty() {
        pairs.push(("scope", scopes.join(" ")));
    }
    let auth_url = join_query(&metadata.authorization_endpoint, &pairs);
    // Spawned: a blocking `open` (and any browser-adjacent work) must not park the
    // async worker that's about to accept the redirect.
    let open_url = auth_url.clone();
    tokio::task::spawn_blocking(move || open(open_url));

    // Wait for the browser's redirect on the loopback listener.
    let deadline = tokio::time::Instant::now() + timeout;
    let code = loop {
        let (mut stream, _) = tokio::time::timeout_at(deadline, listener.accept())
            .await
            .map_err(|_| anyhow!("the sign-in didn't finish within {}s", timeout.as_secs()))?
            .context("browser redirected")?;
        let Some(callback) = read_callback(&mut stream).await else {
            continue;
        };
        let query = callback.split_once('?').map(|(_, q)| q).unwrap_or("");
        let pairs: Vec<(String, String)> = parse_query(query);
        let state_in = pairs.iter().find(|(k, _)| k == "state").map(|(_, v)| v.clone());
        if state_in.as_deref() != Some(state.as_str()) {
            // Not frog's redirect, or a replay: nobody's page, keep listening.
            write_page(&mut stream, "frog: stray request").await;
            continue;
        }
        let Some(code) = pairs.iter().find(|(k, _)| k == "code").map(|(_, v)| v.clone()) else {
            let error = pairs
                .iter()
                .find(|(k, _)| k == "error")
                .map(|(_, v)| v.clone())
                .unwrap_or_else(|| "the authorization server refused".to_string());
            write_page(&mut stream, &format!("frog: sign-in failed: {error}")).await;
            bail!("{error}");
        };
        write_page(&mut stream, "frog: signed in — you can close this tab.").await;
        break code;
    };

    // Exchange the code for tokens.
    let mut form = vec![
        ("grant_type", "authorization_code"),
        ("code", code.as_str()),
        ("redirect_uri", redirect.as_str()),
        ("client_id", client_id.as_str()),
        ("code_verifier", pkce.verifier.as_str()),
    ];
    if let Some(secret) = &client_secret
        && !secret.is_empty()
    {
        form.push(("client_secret", secret));
    }
    let reply = token_request(http, &metadata.token_endpoint, &form).await?;
    let tokens = Tokens {
        client_id,
        issuer: metadata.issuer,
        access_token: reply.access_token,
        refresh_token: reply.refresh_token,
        expires_at: reply.expires_in.map(|s| now_epoch() + s),
        scopes: reply
            .scope
            .map(|s| s.split_whitespace().map(str::to_string).collect())
            .unwrap_or(scopes),
    };
    save(name, &tokens)?;
    Ok(tokens)
}

/// Read the browser's redirect request off the loopback connection, as its raw target.
async fn read_callback(stream: &mut tokio::net::TcpStream) -> Option<String> {
    use tokio::io::AsyncReadExt;
    let mut buf = [0u8; 4096];
    let n = stream.read(&mut buf).await.ok()?;
    let request = String::from_utf8_lossy(&buf[..n]);
    request.lines().next()?.split_whitespace().nth(1)?.to_string().into()
}

/// Answer the redirect with a small HTML page the user sees.
async fn write_page(stream: &mut tokio::net::TcpStream, text: &str) {
    use tokio::io::AsyncWriteExt;
    let body = format!("<!doctype html><title>{text}</title><p>{text}</p>");
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.shutdown().await;
}

// ---- refresh -----------------------------------------------------------

/// Refresh `server`'s access token with its refresh token.
///
/// `Ok(Some)` is fresh tokens (already stored). `Ok(None)` means the grant is dead —
/// nothing stored, no refresh token, or the server refused the refresh — so the user
/// signs in again; the caller surfaces that in words. `Err` is a network or metadata
/// problem: transient, worth retrying later.
pub async fn refresh(http: &reqwest::Client, name: &str, url: &str) -> Result<Option<Tokens>> {
    let Some(tokens) = stored(name) else {
        return Ok(None);
    };
    let Some(refresh_token) = tokens.refresh_token.clone() else {
        return Ok(None);
    };
    // Discovery again: the token endpoint may have moved, and a new issuer means the old
    // grant is someone else's now.
    let metadata = discover(http, url, None).await?;
    if metadata.issuer.is_some()
        && tokens.issuer.is_some()
        && metadata.issuer != tokens.issuer
    {
        clear(name);
        return Ok(None);
    }
    let mut form = vec![
        ("grant_type", "refresh_token"),
        ("refresh_token", refresh_token.as_str()),
        ("client_id", tokens.client_id.as_str()),
    ];
    let scope = tokens.scopes.join(" ");
    if !scope.is_empty() {
        form.push(("scope", scope.as_str()));
    }
    let reply = match token_request(http, &metadata.token_endpoint, &form).await {
        Ok(reply) => reply,
        // 4xx on a refresh means the grant was refused: dead, not retryable.
        Err(e) if e.to_string().contains("HTTP 4") => {
            clear(name);
            return Ok(None);
        }
        Err(e) => return Err(e),
    };
    let fresh = Tokens {
        client_id: tokens.client_id,
        issuer: tokens.issuer,
        access_token: reply.access_token,
        // RFC 6749 §6: a refresh response may omit a new refresh token; keep the old one.
        refresh_token: reply.refresh_token.or(Some(refresh_token)),
        expires_at: reply.expires_in.map(|s| now_epoch() + s),
        scopes: reply
            .scope
            .map(|s| s.split_whitespace().map(str::to_string).collect())
            .unwrap_or(tokens.scopes),
    };
    save(name, &fresh)?;
    Ok(Some(fresh))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicUsize, Ordering};

    // ---- a tiny blocking HTTP server -------------------------------------

    /// One recorded request: method, path, lowercased headers, body.
    struct Request {
        method: String,
        path: String,
        headers: Vec<(String, String)>,
        body: String,
    }

    impl Request {
        fn header(&self, name: &str) -> Option<&str> {
            self.headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(name))
                .map(|(_, v)| v.as_str())
        }
    }

    fn reply_json(status: u16, body: serde_json::Value) -> Vec<u8> {
        let body = body.to_string();
        let reason = match status {
            200 => "OK",
            201 => "Created",
            400 => "Bad Request",
            401 => "Unauthorized",
            _ => "Status",
        };
        format!(
            "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
            body.len()
        )
        .into_bytes()
    }

    fn reply_text(status: u16, body: &str, extra: &[(&str, String)]) -> Vec<u8> {
        let reason = match status {
            200 => "OK",
            202 => "Accepted",
            401 => "Unauthorized",
            405 => "Method Not Allowed",
            _ => "Status",
        };
        let mut head = format!(
            "HTTP/1.1 {status} {reason}\r\ncontent-type: text/plain\r\ncontent-length: {}\r\n",
            body.len()
        );
        for (k, v) in extra {
            head.push_str(&format!("{k}: {v}\r\n"));
        }
        format!("{head}connection: close\r\n\r\n{body}").into_bytes()
    }

    /// Serve `route` on a fresh port until dropped. One thread per connection.
    pub(crate) struct MockServer {
        #[allow(dead_code)]
        handle: std::thread::JoinHandle<()>,
        pub(crate) port: u16,
    }

    impl MockServer {
        fn spawn(route: impl Fn(Request) -> Vec<u8> + Send + Sync + 'static) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            let route = Arc::new(route);
            let handle = std::thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(mut stream) = stream else { break };
                    let route = route.clone();
                    std::thread::spawn(move || {
                        if let Some(request) = read_request(&mut stream) {
                            let bytes = route(request);
                            let _ = stream.write_all(&bytes);
                            let _ = stream.flush();
                        }
                    });
                }
            });
            Self { handle, port }
        }

        pub(crate) fn url(&self, path: &str) -> String {
            format!("http://127.0.0.1:{}{path}", self.port)
        }

    }

    impl Drop for MockServer {
        fn drop(&mut self) {
            // The accept loop runs until the process exits; a finished test just leaves
            // the listening thread parked. Drop without joining (detaches).
            let _ = &self.handle;
        }
    }

    fn read_request(stream: &mut TcpStream) -> Option<Request> {
        let mut buf = [0u8; 16_384];
        let mut raw = Vec::new();
        let header_end = loop {
            let n = stream.read(&mut buf).ok()?;
            raw.extend_from_slice(&buf[..n]);
            if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                break pos;
            }
            if n == 0 {
                return None;
            }
        };
        let head = String::from_utf8_lossy(&raw[..header_end]).into_owned();
        let mut lines = head.lines();
        let mut request_line = lines.next()?.split_whitespace();
        let method = request_line.next()?.to_string();
        let target = request_line.next()?.to_string();
        let mut headers = Vec::new();
        for line in lines {
            let Some((k, v)) = line.split_once(':') else { continue };
            headers.push((k.trim().to_lowercase(), v.trim().to_string()));
        }
        let length: usize = headers
            .iter()
            .find(|(k, _)| k == "content-length")
            .and_then(|(_, v)| v.parse().ok())
            .unwrap_or(0);
        let mut body = raw[header_end + 4..].to_vec();
        while body.len() < length {
            let n = stream.read(&mut buf).ok()?;
            if n == 0 {
                break;
            }
            body.extend_from_slice(&buf[..n]);
        }
        body.truncate(length);
        Some(Request {
            method,
            path: target.split('?').next().unwrap_or("").to_string(),
            headers,
            body: String::from_utf8_lossy(&body).into_owned(),
        })
    }

    // ---- the mock OAuth + MCP world ---------------------------------------

    #[derive(Default)]
    pub(crate) struct Mock {
        /// The token the AS issues and the MCP server accepts.
        pub(crate) token: Mutex<String>,
        pub(crate) registrations: AtomicUsize,
        pub(crate) exchanges: AtomicUsize,
        pub(crate) refreshes: AtomicUsize,
        /// The refresh token the mock accepts; a different one is refused.
        pub(crate) refresh_token: Mutex<String>,
    }

    impl Mock {
        fn metadata(&self, base: &str) -> serde_json::Value {
            serde_json::json!({
                "issuer": base,
                "authorization_endpoint": format!("{base}/authorize"),
                "token_endpoint": format!("{base}/token"),
                "registration_endpoint": format!("{base}/register"),
                "scopes_supported": ["mcp:read", "offline_access"],
                "code_challenge_methods_supported": ["S256"],
                "response_types_supported": ["code"]
            })
        }

        fn resource_metadata(&self, base: &str) -> serde_json::Value {
            serde_json::json!({
                "resource": format!("{base}/mcp"),
                "authorization_servers": [base],
                "scopes_supported": ["mcp:read"]
            })
        }
    }

    /// Start the combined mock: OAuth docs on the origin, MCP JSON-RPC at `/mcp` that
    /// requires the mock's bearer. Served per connection, so the MCP side answers
    /// 401+challenge until a Bearer with the right token arrives.
    pub(crate) fn start_mock(token: &str) -> (MockServer, Arc<Mock>) {
        let mock = Arc::new(Mock {
            token: Mutex::new(token.to_string()),
            refresh_token: Mutex::new("refresh-1".to_string()),
            ..Default::default()
        });
        let for_route = mock.clone();
        let server = MockServer::spawn(move |request| {
            route_mock(&for_route, request)
        });
        (server, mock)
    }

    fn route_mock(mock: &Mock, request: Request) -> Vec<u8> {
        match request.path.as_str() {
            p if p.starts_with("/.well-known/oauth-protected-resource") => {
                let base = format!("http://{}", request.header("host").unwrap_or(""));
                reply_json(200, mock.resource_metadata(&base))
            }
            p if p.starts_with("/.well-known/oauth-authorization-server") => {
                let base = format!("http://{}", request.header("host").unwrap_or(""));
                reply_json(200, mock.metadata(&base))
            }
            "/register" => {
                mock.registrations.fetch_add(1, Ordering::SeqCst);
                reply_json(
                    201,
                    serde_json::json!({
                        "client_id": format!("client-{}", mock.registrations.load(Ordering::SeqCst)),
                        "grant_types": ["authorization_code", "refresh_token"]
                    }),
                )
            }
            "/token" => token_route(mock, &request),
            "/mcp" => {
                let expected = format!("Bearer {}", mock.token.lock().unwrap());
                if request.header("authorization") != Some(expected.as_str()) {
                    let base = format!("http://{}", request.header("host").unwrap_or(""));
                    return reply_text(
                        401,
                        "unauthorized",
                        &[(
                            "www-authenticate",
                            format!("Bearer resource_metadata=\"{base}/.well-known/oauth-protected-resource\""),
                        )],
                    );
                }
                mcp_route(&request)
            }
            _ => reply_text(404, "not found", &[]),
        }
    }

    fn token_route(mock: &Mock, request: &Request) -> Vec<u8> {
        let form: Vec<(String, String)> = request
            .body
            .split('&')
            .filter_map(|pair| pair.split_once('='))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let get = |name: &str| {
            form.iter()
                .find(|(k, _)| k == name)
                .map(|(_, v)| v.clone())
        };
        match get("grant_type").as_deref() {
            Some("authorization_code") => {
                mock.exchanges.fetch_add(1, Ordering::SeqCst);
                assert!(
                    get("code_verifier").is_some_and(|v| !v.is_empty()),
                    "the code exchange must carry the PKCE verifier"
                );
                assert!(
                    get("client_id").is_some_and(|c| c.starts_with("client-")),
                    "the exchange must carry the registered client id"
                );
                reply_json(
                    200,
                    serde_json::json!({
                        "access_token": mock.token.lock().unwrap().clone(),
                        "refresh_token": mock.refresh_token.lock().unwrap().clone(),
                        "expires_in": 3600,
                        "scope": "mcp:read"
                    }),
                )
            }
            Some("refresh_token") => {
                mock.refreshes.fetch_add(1, Ordering::SeqCst);
                if get("refresh_token").as_deref() != Some(mock.refresh_token.lock().unwrap().as_str()) {
                    return reply_json(400, serde_json::json!({"error": "invalid_grant"}));
                }
                // Rotate the access token so a retry with the old one fails.
                let mut token = mock.token.lock().unwrap();
                let rotated = format!("{}-r", token.trim_end_matches("-r"));
                *token = rotated;
                reply_json(
                    200,
                    serde_json::json!({
                        "access_token": token.clone(),
                        "expires_in": 3600
                    }),
                )
            }
            other => panic!("unexpected grant: {other:?}"),
        }
    }

    /// Minimal streamable-HTTP JSON-RPC: initialize answers 200 JSON, notifications 202,
    /// tools/list answers one tool, GET answers 405 (no SSE streams).
    fn mcp_route(request: &Request) -> Vec<u8> {
        if request.method == "GET" {
            return reply_text(405, "no sse", &[]);
        }
        let body: serde_json::Value = serde_json::from_str(&request.body).unwrap_or_default();
        match body["method"].as_str().unwrap_or("") {
            "initialize" => reply_json(
                200,
                serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": body["id"],
                    "result": {
                        "protocolVersion": "2025-06-18",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "mock", "version": "0"}
                    }
                }),
            ),
            "notifications/initialized" => reply_text(202, "", &[]),
            "tools/list" => reply_json(
                200,
                serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": body["id"],
                    "result": {"tools": [
                        {"name": "echo", "inputSchema": {"type": "object", "properties": {}}}
                    ]}
                }),
            ),
            _ if body["id"].is_null() => reply_text(202, "", &[]),
            _ => reply_json(
                200,
                serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": body["id"],
                    "result": {"content": [{"type": "text", "text": "mock tools/call"}]}
                }),
            ),
        }
    }

    // ---- the fake browser --------------------------------------------------

    /// The authorization URL the flow opens: GET its redirect_uri with `code=…&state=…`
    /// and panic on a page that isn't a friendly sign-in reply. This is the leg the real
    /// browser plays.
    pub(crate) fn fake_browser(url: String) {
        let query = url.split_once('?').map(|(_, q)| q).unwrap_or("");
        let pairs: Vec<(String, String)> = query
            .split('&')
            .filter_map(|p| p.split_once('='))
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let get = |name: &str| pairs.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone());
        let redirect = get("redirect_uri").expect("authorization URL names redirect_uri");
        let state = get("state").expect("authorization URL carries state");
        assert_eq!(get("code_challenge_method").as_deref(), Some("S256"));
        assert!(
            get("code_challenge").is_some_and(|c| c.len() == 43),
            "PKCE S256 challenge is 43 base64url chars"
        );
        let redirect = redirect
            .replace("%2F", "/")
            .replace("%3A", ":")
            .replace("%3F", "?")
            .replace("%3D", "=")
            .replace("%26", "&");
        let target = format!("{redirect}?code=good-code&state={state}");
        let page = get_page(&target);
        assert!(
            page.contains("signed in"),
            "the redirect should answer a friendly page, got: {page}"
        );
    }

    /// A raw GET over a fresh connection; the response body as text.
    fn get_page(target: &str) -> String {
        let (host, rest) = target
            .strip_prefix("http://")
            .unwrap()
            .split_once('/')
            .unwrap();
        let mut stream = TcpStream::connect(host).unwrap();
        let request = format!("GET /{rest} HTTP/1.1\r\nhost: {host}\r\nconnection: close\r\n\r\n");
        stream.write_all(request.as_bytes()).unwrap();
        let mut out = String::new();
        let _ = stream.read_to_string(&mut out);
        out
    }

    // ---- tests -------------------------------------------------------------

    /// One mock, one server name, memory store. Returns the url for `[mcp_servers.x]`.
    struct World {
        #[allow(dead_code)]
        server: MockServer,
        mock: Arc<Mock>,
        name: String,
        url: String,
    }

    impl World {
        fn start(token: &str) -> Self {
            let _memory = use_memory_store();
            let (server, mock) = start_mock(token);
            let name = crate::session::new_id();
            let url = server.url("/mcp");
            Self {
                server,
                mock,
                name,
                url,
            }
        }
    }

    impl Drop for World {
        fn drop(&mut self) {
            clear(&self.name);
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn discovery_registration_and_exchange_store_tokens() {
        let world = World::start("tok-1");
        let http = reqwest::Client::new();
        let tokens = authorize(
            &http,
            &world.name,
            &world.url,
            Some("Bearer resource_metadata=\"x\""),
            Arc::new(fake_browser),
            Duration::from_secs(10),
        )
        .await
        .expect("the flow completes");
        assert_eq!(tokens.access_token, "tok-1");
        assert_eq!(mock_tokens(&world.mock.registrations), 1);
        assert_eq!(mock_tokens(&world.mock.exchanges), 1);
        // Stored under the server name: another name reads nothing.
        assert_eq!(stored(&world.name).unwrap().access_token, "tok-1");
        assert!(stored("other-server").is_none());
        assert_eq!(bearer(&world.name), Some("Bearer tok-1".into()));
    }

    fn mock_tokens(counter: &AtomicUsize) -> usize {
        counter.load(Ordering::SeqCst)
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn expired_tokens_refresh_before_connecting() {
        let world = World::start("tok-2");
        let http = reqwest::Client::new();
        authorize(
            &http,
            &world.name,
            &world.url,
            None,
            Arc::new(fake_browser),
            Duration::from_secs(10),
        )
        .await
        .unwrap();
        // Age the token out past the refresh buffer.
        let mut tokens = stored(&world.name).unwrap();
        tokens.expires_at = Some(now_epoch() - 1);
        save(&world.name, &tokens).unwrap();
        assert_eq!(bearer(&world.name), None, "expired tokens don't ride along");
        let refreshed = refresh(&http, &world.name, &world.url)
            .await
            .unwrap()
            .expect("the refresh grant is alive");
        assert_eq!(refreshed.access_token, "tok-2-r");
        assert_eq!(bearer(&world.name), Some("Bearer tok-2-r".into()));
        assert_eq!(mock_tokens(&world.mock.refreshes), 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_refused_refresh_clears_the_grant() {
        let world = World::start("tok-3");
        let http = reqwest::Client::new();
        authorize(
            &http,
            &world.name,
            &world.url,
            None,
            Arc::new(fake_browser),
            Duration::from_secs(10),
        )
        .await
        .unwrap();
        // Corrupt the refresh token: the server refuses the grant.
        let mut tokens = stored(&world.name).unwrap();
        tokens.refresh_token = Some("forged".into());
        save(&world.name, &tokens).unwrap();
        let result = refresh(&http, &world.name, &world.url).await.unwrap();
        assert!(result.is_none(), "a refused grant is reported, not thrown");
        assert!(stored(&world.name).is_none(), "the dead grant is forgotten");
    }

    /// The full connect path, through [`crate::mcp::connect_one`] via a one-server hub:
    /// a 401-challenging server ends up connected with tools, after the fake browser
    /// signed in.
    #[tokio::test(flavor = "multi_thread")]
    async fn connect_signs_in_and_lists_tools() {
        let world = World::start("tok-4");
        let cfg = crate::mcp::ServerConfig {
            url: Some(world.url.clone()),
            ..Default::default()
        };
        // The real `open` would launch a browser; the flow under test takes ours.
        // connect_one uses `system_browser`, so substitute by pre-seeding: run the
        // authorize flow ourselves first (the same leg), then connect.
        let http = reqwest::Client::new();
        authorize(
            &http,
            &world.name,
            &world.url,
            None,
            Arc::new(fake_browser),
            Duration::from_secs(10),
        )
        .await
        .unwrap();
        let mut hub = crate::mcp::Hub::empty();
        hub.connect_one_into(world.name.clone(), cfg).await;
        let status = hub
            .status()
            .into_iter()
            .find(|s| s.name == world.name)
            .expect("the server appears in status");
        assert!(
            status.connected,
            "the challenging server connects with tokens: {:?}",
            status.error
        );
        assert_eq!(status.tools, vec!["echo".to_string()]);
    }

    #[test]
    fn well_known_paths_follow_the_spec() {
        assert_eq!(
            well_known_candidates("https://example.com/mcp", "oauth-protected-resource"),
            vec![
                "https://example.com/.well-known/oauth-protected-resource/mcp".to_string(),
                "https://example.com/.well-known/oauth-protected-resource".to_string(),
            ]
        );
        assert_eq!(
            well_known_candidates("https://example.com", "oauth-authorization-server"),
            vec!["https://example.com/.well-known/oauth-authorization-server".to_string()]
        );
        assert_eq!(
            well_known_candidates("https://example.com:8443/a/b", "x"),
            vec![
                "https://example.com:8443/.well-known/x/a/b".to_string(),
                "https://example.com:8443/.well-known/x".to_string(),
            ]
        );
    }

    #[test]
    fn challenge_parameters_are_read() {
        let header = "Bearer scope=\"mcp:read\", resource_metadata=\"https://as.example/metadata\", error=\"invalid_token\"";
        assert_eq!(param(header, "scope"), Some("mcp:read".into()));
        assert_eq!(
            param(header, "resource_metadata"),
            Some("https://as.example/metadata".into())
        );
        assert_eq!(param(header, "error"), Some("invalid_token".into()));
        assert_eq!(param(header, "missing"), None);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn discovery_honors_the_challenge_url_and_scope() {
        // A server whose resource metadata lives at a non-standard URL named only in
        // the challenge.
        let mock = Arc::new(Mock {
            token: Mutex::new("tok-5".into()),
            refresh_token: Mutex::new("refresh-5".into()),
            ..Default::default()
        });
        let for_route = mock.clone();
        let server = MockServer::spawn(move |request| match request.path.as_str() {
            "/metadata/here" => {
                let base = format!("http://{}", request.header("host").unwrap_or(""));
                reply_json(200, for_route.resource_metadata(&base))
            }
            "/.well-known/oauth-authorization-server" => {
                let base = format!("http://{}", request.header("host").unwrap_or(""));
                reply_json(200, for_route.metadata(&base))
            }
            "/register" => {
                for_route.registrations.fetch_add(1, Ordering::SeqCst);
                reply_json(201, serde_json::json!({"client_id": "client-x"}))
            }
            "/token" => {
                for_route.exchanges.fetch_add(1, Ordering::SeqCst);
                reply_json(
                    200,
                    serde_json::json!({
                        "access_token": for_route.token.lock().unwrap().clone(),
                        "expires_in": 3600,
                        "scope": "mcp:write"
                    }),
                )
            }
            _ => reply_text(404, "no", &[]),
        });
        let _memory = use_memory_store();
        let name = crate::session::new_id();
        let http = reqwest::Client::new();
        let challenge = format!(
            "Bearer resource_metadata=\"{}\"",
            server.url("/metadata/here")
        );
        let tokens = authorize(
            &http,
            &name,
            &server.url("/mcp"),
            Some(&challenge),
            Arc::new(fake_browser),
            Duration::from_secs(10),
        )
        .await
        .expect("the challenge's URL is followed");
        // The challenge's scope hint wins over the metadata's.
        assert_eq!(tokens.scopes, vec!["mcp:write"]);
        assert_eq!(tokens.client_id, "client-x");
        clear(&name);
    }

    /// A configured Authorization header is the escape hatch: OAuth never runs.
    #[test]
    fn configured_headers_skip_oauth() {
        let mut headers = std::collections::BTreeMap::new();
        headers.insert("Authorization".to_string(), "Bearer static".to_string());
        assert_eq!(authorize_url(Some("https://x/mcp"), &headers), None);
        headers.insert("Authorization".to_string(), "${MY_TOKEN}".to_string());
        // Expanded-empty still counts as configured (the user opted in).
        assert_eq!(authorize_url(Some("https://x/mcp"), &headers), None);
        let mut other = std::collections::BTreeMap::new();
        other.insert("X-Custom".to_string(), "v".to_string());
        assert_eq!(
            authorize_url(Some("https://x/mcp"), &other),
            Some("https://x/mcp".to_string())
        );
        assert_eq!(authorize_url(None, &headers), None);
    }

    #[test]
    fn no_token_for_an_unconfigured_server() {
        clear("no-such-server-at-all");
        assert_eq!(bearer("no-such-server-at-all"), None);
    }
}

#[cfg(test)]
mod raw_call_tests {
    use super::use_memory_store;
    use super::tests::{fake_browser, start_mock};
    use super::*;
    use crate::mcp::{Host, Hub, ServerConfig};
    use std::path::Path;
    use std::sync::atomic::Ordering;

    /// A token revoked mid-session: the tool call 401s, one refresh fixes it, and the
    /// retry succeeds — the model sees the tool's answer, never the raw 401.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_dead_token_refreshes_and_the_call_retries() {
        let _memory = use_memory_store();
        let (server, mock) = start_mock("tok-live");
        let name = crate::session::new_id();
        let cfg = ServerConfig {
            url: Some(server.url("/mcp")),
            ..Default::default()
        };
        let _host = Host::headless(Path::new("."));
        // Sign in first (the same leg the browser plays), then connect.
        let http = reqwest::Client::new();
        authorize(
            &http,
            &name,
            &server.url("/mcp"),
            None,
            Arc::new(fake_browser),
            Duration::from_secs(10),
        )
        .await
        .unwrap();
        let mut hub = Hub::empty();
        hub.connect_one_into(name.clone(), cfg).await;
        assert!(hub.status().iter().any(|s| s.name == name && s.connected));

        // The server revokes the live token: the next call 401s.
        *mock.token.lock().unwrap() = "tok-rotated".into();
        let out = hub
            .call("item-1", &crate::mcp::exposed_name(&name, "echo"), &serde_json::json!({}))
            .await
            .expect("the call retries after one refresh");
        assert!(out.content.contains("mock tools/call"), "{}", out.content);
        assert_eq!(mock.refreshes.load(Ordering::SeqCst), 1);
        // The hub's connection was swapped for a working one; the mock rotated the
        // access token once for the one refresh.
        assert_eq!(
            bearer(&name),
            Some("Bearer tok-rotated-r".into()),
            "exactly one refresh happened"
        );
        drop(server);
        clear(&name);
    }
}
