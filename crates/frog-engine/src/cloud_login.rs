//! `frog login` / `frog logout`: Frog Cloud sign-in from the terminal.
//!
//! The same flow as the Mac app's sign-in (apps/FrogKit/Core/CloudSignIn.swift): PKCE at the
//! edge's `/auth/web`, back to a one-shot listener on `127.0.0.1` (RFC 8252 §7.3), then
//! `POST /v1/auth/exchange` for this machine's own `frog_…` key, saved in the Keychain where
//! the app keeps it (service `frog`, account `cloud`).
//!
//! It needs a browser on this machine. A true device-code flow (RFC 8628, for SSH sessions)
//! would need the edge to grow `POST /v1/auth/device` and a page to enter the code on.

use crate::mcp_oauth::{
    Browser, Pkce, fill_random, join_query, parse_query, read_callback, write_page,
};
use anyhow::{Context, Result, anyhow, bail};
use base64::Engine;
use std::time::Duration;

/// How long `frog login` waits for the browser; the Mac app waits as long.
pub const TIMEOUT: Duration = Duration::from_secs(180);

/// The path the edge allows a native loopback redirect to (`nativeLoopback` in zest).
const PATH: &str = "/frog-signin";

/// The key's name in the account's key list: "frog CLI · <host>", at most 64 chars.
pub fn device_name() -> String {
    let host = std::process::Command::new("hostname")
        .arg("-s")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "this machine".into());
    let name = format!("frog CLI · {host}");
    name.chars().take(64).collect()
}

/// Sign in at `origin` (`https://api.frog.toys`) with `provider` ("github" or "google") and
/// return the new key. `open` opens the browser; tests pass their own and follow the redirect.
/// Storing the key is the caller's ([`crate::providers::set_key`]).
pub async fn sign_in(
    http: &reqwest::Client,
    origin: &str,
    provider: &str,
    device: &str,
    open: Browser,
    timeout: Duration,
) -> Result<String> {
    if provider != "github" && provider != "google" {
        bail!("sign in with github or google, not `{provider}`");
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .context("opening a loopback listener")?;
    let port = listener.local_addr()?.port();
    let pkce = Pkce::new()?;
    let mut state = [0u8; 16];
    fill_random(&mut state)?;
    let state = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(state);
    let url = join_query(
        &format!("{}/auth/web", origin.trim_end_matches('/')),
        &[
            ("challenge", pkce.challenge.clone()),
            ("state", state.clone()),
            ("device", device.to_string()),
            ("return", format!("http://127.0.0.1:{port}{PATH}")),
            ("provider", provider.to_string()),
        ],
    );
    let shown = url.clone();
    tokio::task::spawn_blocking(move || open(shown));

    let deadline = tokio::time::Instant::now() + timeout;
    let code = loop {
        let (mut stream, _) = tokio::time::timeout_at(deadline, listener.accept())
            .await
            .map_err(|_| anyhow!("sign-in didn't finish within {}s", timeout.as_secs()))?
            .context("waiting for the browser")?;
        let Some(target) = read_callback(&mut stream).await else {
            continue;
        };
        let (path, query) = target.split_once('?').unwrap_or((&target, ""));
        let pairs = parse_query(query);
        let get = |k: &str| pairs.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        // A favicon fetch or a stray tab: not ours, keep listening.
        if path != PATH || get("state").as_deref() != Some(state.as_str()) {
            write_page(&mut stream, "frog: stray request").await;
            continue;
        }
        let Some(code) = get("code") else {
            write_page(&mut stream, "Sign-in didn't finish. Run frog login again.").await;
            bail!("Frog Cloud didn't sign you in");
        };
        write_page(
            &mut stream,
            "Signed in. You can close this tab and go back to frog.",
        )
        .await;
        break code;
    };

    #[derive(serde::Deserialize)]
    struct Exchange {
        key: String,
    }
    let reply = http
        .post(format!("{}/v1/auth/exchange", origin.trim_end_matches('/')))
        .json(&serde_json::json!({
            "code": code, "verifier": pkce.verifier, "device_name": device,
        }))
        .send()
        .await
        .context("reaching Frog Cloud")?;
    let status = reply.status();
    if !status.is_success() {
        bail!("Frog Cloud refused the sign-in (HTTP {})", status.as_u16());
    }
    let key = reply
        .json::<Exchange>()
        .await
        .context("reading Frog Cloud's reply")?
        .key;
    if !key.starts_with("frog_") {
        bail!("Frog Cloud sent back something that isn't a frog key");
    }
    Ok(key)
}

/// What `frog logout` did.
#[derive(Debug, PartialEq, Eq)]
pub enum Logout {
    /// The saved key is gone.
    Removed,
    /// There was no saved key.
    NothingSaved,
}

/// Remove the saved Frog Cloud key. `saved` and `delete` are the Keychain's (injectable for
/// tests). An environment key is untouched: it isn't frog's to delete.
pub fn logout(saved: &dyn Fn() -> bool, delete: &dyn Fn() -> Result<()>) -> Result<Logout> {
    if !saved() {
        return Ok(Logout::NothingSaved);
    }
    delete()?;
    Ok(Logout::Removed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    /// A fake edge: answers `POST /v1/auth/exchange` with `reply` after checking the PKCE
    /// verifier against the challenge the browser was sent. Returns its origin.
    async fn edge(challenge: Arc<Mutex<String>>, status: u16, reply: &'static str) -> String {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", l.local_addr().unwrap());
        tokio::spawn(async move {
            let (mut s, _) = l.accept().await.unwrap();
            let mut buf = vec![0u8; 8192];
            let mut n = 0;
            // Read until the JSON body has arrived.
            loop {
                n += s.read(&mut buf[n..]).await.unwrap();
                let text = String::from_utf8_lossy(&buf[..n]);
                if text.contains("\r\n\r\n") && text.trim_end().ends_with('}') {
                    break;
                }
            }
            let text = String::from_utf8_lossy(&buf[..n]).to_string();
            assert!(text.starts_with("POST /v1/auth/exchange "), "{text}");
            let body: serde_json::Value =
                serde_json::from_str(text.split("\r\n\r\n").nth(1).unwrap()).unwrap();
            let verifier = body["verifier"].as_str().unwrap();
            let want = base64::engine::general_purpose::URL_SAFE_NO_PAD
                .encode(Sha256::digest(verifier.as_bytes()));
            assert_eq!(
                *challenge.lock().unwrap(),
                want,
                "verifier must match the challenge"
            );
            assert_eq!(body["code"], "the-code");
            assert_eq!(body["device_name"], "frog CLI · test");
            let resp = format!(
                "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{reply}",
                reply.len()
            );
            s.write_all(resp.as_bytes()).await.unwrap();
        });
        origin
    }

    /// A browser that checks the sign-in URL and follows the edge's redirect: first a stray
    /// request (which must be ignored), then the real one with `code` and `state`.
    fn browser(challenge: Arc<Mutex<String>>, seen: Arc<Mutex<String>>) -> Browser {
        Arc::new(move |url: String| {
            *seen.lock().unwrap() = url.clone();
            let q: Vec<(String, String)> = parse_query(url.split_once('?').unwrap().1);
            let get = |k: &str| q.iter().find(|(n, _)| n == k).unwrap().1.clone();
            *challenge.lock().unwrap() = get("challenge");
            let back = get("return");
            let state = get("state");
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            rt.block_on(async {
                let http = reqwest::Client::new();
                let stray = http
                    .get(format!("{back}?code=x&state=wrong"))
                    .send()
                    .await
                    .unwrap();
                assert!(stray.text().await.unwrap().contains("stray"));
                let ok = http
                    .get(format!("{back}?code=the-code&state={state}"))
                    .send()
                    .await
                    .unwrap();
                assert!(ok.text().await.unwrap().contains("Signed in"));
            });
        })
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn login_gets_a_key_through_the_loopback() {
        let challenge = Arc::new(Mutex::new(String::new()));
        let seen = Arc::new(Mutex::new(String::new()));
        let origin = edge(challenge.clone(), 200, r#"{"key":"frog_abc","account":{}}"#).await;
        let key = sign_in(
            &reqwest::Client::new(),
            &origin,
            "github",
            "frog CLI · test",
            browser(challenge, seen.clone()),
            Duration::from_secs(10),
        )
        .await
        .unwrap();
        assert_eq!(key, "frog_abc");
        let url = seen.lock().unwrap().clone();
        assert!(url.starts_with(&format!("{origin}/auth/web?")), "{url}");
        assert!(url.contains("provider=github"));
        assert!(url.contains("return=http%3A%2F%2F127.0.0.1%3A"));
        assert!(url.contains("%2Ffrog-signin"));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn login_reports_a_refused_exchange() {
        let challenge = Arc::new(Mutex::new(String::new()));
        let origin = edge(challenge.clone(), 400, r#"{"error":"bad code"}"#).await;
        let err = sign_in(
            &reqwest::Client::new(),
            &origin,
            "google",
            "frog CLI · test",
            browser(challenge, Arc::default()),
            Duration::from_secs(10),
        )
        .await
        .unwrap_err();
        assert!(err.to_string().contains("HTTP 400"), "{err}");
    }

    #[tokio::test]
    async fn login_times_out_without_a_browser() {
        let err = sign_in(
            &reqwest::Client::new(),
            "http://127.0.0.1:9",
            "github",
            "d",
            Arc::new(|_| {}),
            Duration::from_millis(50),
        )
        .await
        .unwrap_err();
        assert!(err.to_string().contains("didn't finish"), "{err}");
    }

    #[tokio::test]
    async fn login_takes_github_or_google_only() {
        let err = sign_in(
            &reqwest::Client::new(),
            "x",
            "gitlab",
            "d",
            Arc::new(|_| {}),
            TIMEOUT,
        )
        .await
        .unwrap_err();
        assert!(err.to_string().contains("github or google"));
    }

    #[test]
    fn logout_removes_a_saved_key() {
        let gone = Mutex::new(false);
        let r = logout(&|| true, &|| {
            *gone.lock().unwrap() = true;
            Ok(())
        });
        assert_eq!(r.unwrap(), Logout::Removed);
        assert!(*gone.lock().unwrap());
    }

    #[test]
    fn logout_without_a_key_deletes_nothing() {
        let r = logout(&|| false, &|| panic!("nothing to delete"));
        assert_eq!(r.unwrap(), Logout::NothingSaved);
    }

    #[test]
    fn logout_passes_a_keychain_error_on() {
        assert!(logout(&|| true, &|| Err(anyhow!("locked"))).is_err());
    }

    #[test]
    fn device_name_fits_the_edge() {
        let d = device_name();
        assert!(d.starts_with("frog CLI · "));
        assert!(d.chars().count() <= 64);
    }
}
