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
use std::sync::Arc;
use std::time::Duration;

/// How long the whole browser sign-in may take: the user finds the window, signs in,
/// maybe answers a second factor. Past this the server stays disconnected; the session
/// never waited on it (`connect_one` runs in the background).
pub const AUTH_TIMEOUT: Duration = Duration::from_secs(15 * 60);

/// Opens a URL in a browser; overridable so tests can skip the real browser.
pub type Browser = Arc<dyn Fn(String) + Send + Sync>;

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

/// One `key="value"` (or bare `key=value`) parameter of a challenge header.
fn param(header: &str, key: &str) -> Option<String> {
    for part in header.split(',') {
        let part = part.trim();
        let Some((k, v)) = part.split_once('=') else { continue };
        if k.trim().eq_ignore_ascii_case(key) {
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
    let response = http.get(url).send().await.ok()?;
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

/// Stored tokens for `server` (Keychain, keyed by the server's name).
pub fn stored(server: &str) -> Option<Tokens> {
    serde_json::from_str(&crate::mcp::keychain_get(&key(server))?).ok()
}

/// Remember `server`'s tokens.
pub fn save(server: &str, tokens: &Tokens) -> Result<()> {
    let text = serde_json::to_string(tokens).context("serializing tokens")?;
    crate::mcp::keychain_set(&key(server), &text)
}

/// Forget a server's tokens.
pub fn clear(server: &str) {
    crate::mcp::keychain_delete(&key(server));
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
    open(auth_url);

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
