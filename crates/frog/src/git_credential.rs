//! `--git-credential-gateway <url>`: git gets its tokens from Frog Cloud's gateway, never from
//! disk. frog points git (and every command it runs) at itself as the only credential helper;
//! `frog git-credential get` then asks the frog process that started it, over a unix socket in
//! a private directory, and that process asks `<url>/internal/git-credential?host=…`.
//!
//! The gateway's URL stays in frog's own memory: the agent's tools inherit only the socket's
//! path, so all they can get from it is what git could anyway, a credential for a host, not
//! the rest of the gateway's internal API.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::io::Read;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

const SOCKET_ENV: &str = "FROG_GIT_CREDENTIAL_SOCKET";
/// What an older frog exported; cleared so a stale one from a parent never leaks through.
const OLD_GATEWAY_ENV: &str = "FROG_GIT_CREDENTIAL_GATEWAY";

#[derive(Deserialize)]
struct Credential {
    username: String,
    password: String,
}

/// Start the credential broker and make this process's children use `frog git-credential` as
/// git's only credential helper. Through the environment, so nothing is written to a git
/// config.
pub fn install(gateway: &str) -> Result<()> {
    let exe = std::env::current_exe().context("finding frog's own path")?;
    let gateway = gateway.trim_end_matches('/').to_string();
    let socket = bind_private()?;
    let listener = UnixListener::bind(&socket).with_context(|| format!("binding {socket:?}"))?;
    tokio::spawn(broker(listener, move |host| fetch(gateway.clone(), host)));
    let n: usize = std::env::var("GIT_CONFIG_COUNT")
        .ok()
        .and_then(|n| n.parse().ok())
        .unwrap_or(0);
    let helper = format!(
        "!'{}' git-credential",
        exe.display().to_string().replace('\'', r"'\''")
    );
    // SAFETY: called from `run` before the engine or any other task that reads the
    // environment starts.
    unsafe {
        std::env::remove_var(OLD_GATEWAY_ENV);
        std::env::set_var(SOCKET_ENV, &socket);
        // An empty helper first clears any configured one (a `store` helper would write the
        // token to disk).
        std::env::set_var(format!("GIT_CONFIG_KEY_{n}"), "credential.helper");
        std::env::set_var(format!("GIT_CONFIG_VALUE_{n}"), "");
        std::env::set_var(format!("GIT_CONFIG_KEY_{}", n + 1), "credential.helper");
        std::env::set_var(format!("GIT_CONFIG_VALUE_{}", n + 1), helper);
        std::env::set_var("GIT_CONFIG_COUNT", (n + 2).to_string());
    }
    Ok(())
}

/// A fresh socket path in a directory only this user can enter.
fn bind_private() -> Result<PathBuf> {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos();
    let dir = std::env::temp_dir().join(format!("frog-cred-{}-{nonce:x}", std::process::id()));
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(&dir)
        .with_context(|| format!("creating {dir:?}"))?;
    Ok(dir.join("s"))
}

async fn fetch(gateway: String, host: String) -> Result<Credential> {
    let url = reqwest::Url::parse_with_params(
        &format!("{gateway}/internal/git-credential"),
        &[("host", host)],
    )?;
    Ok(reqwest::get(url).await?.error_for_status()?.json().await?)
}

/// A host name as git sends it, maybe with a port: nothing that could reshape the request.
fn valid_host(host: &str) -> bool {
    !host.is_empty()
        && host.len() <= 253
        && host
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | ':' | '[' | ']'))
}

/// Answer each connection's one `host\n` with `username=…\npassword=…\n`, or nothing.
async fn broker<F, Fut>(listener: UnixListener, fetch: F)
where
    F: Fn(String) -> Fut + Send + Sync + Clone + 'static,
    Fut: std::future::Future<Output = Result<Credential>> + Send,
{
    loop {
        let Ok((sock, _)) = listener.accept().await else {
            continue;
        };
        let fetch = fetch.clone();
        tokio::spawn(async move {
            if let Err(e) = answer(sock, fetch).await {
                eprintln!("git-credential: {e:#}");
            }
        });
    }
}

async fn answer<F, Fut>(mut sock: UnixStream, fetch: F) -> Result<()>
where
    F: Fn(String) -> Fut,
    Fut: std::future::Future<Output = Result<Credential>>,
{
    let mut line = String::new();
    BufReader::new((&mut sock).take(512))
        .read_line(&mut line)
        .await?;
    let host = line.trim_end().to_string();
    anyhow::ensure!(valid_host(&host), "bad host {host:?}");
    let c = fetch(host).await?;
    sock.write_all(format!("username={}\npassword={}\n", c.username, c.password).as_bytes())
        .await?;
    Ok(())
}

/// Ask the broker at `socket` for `host`'s credential, in git's helper format.
async fn ask(socket: &Path, host: &str) -> Result<String> {
    let mut s = UnixStream::connect(socket)
        .await
        .with_context(|| format!("connecting {socket:?}"))?;
    s.write_all(format!("{host}\n").as_bytes()).await?;
    let mut out = String::new();
    s.read_to_string(&mut out).await?;
    anyhow::ensure!(!out.is_empty(), "no credential for {host}");
    Ok(out)
}

/// `frog git-credential <get|store|erase>`, as git runs a helper. Only `get` does anything.
pub async fn helper(action: Option<&str>) -> Result<()> {
    if action != Some("get") {
        return Ok(());
    }
    let socket = std::env::var_os(SOCKET_ENV).context("no credential broker")?;
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input)?;
    let host = input
        .lines()
        .find_map(|l| l.strip_prefix("host="))
        .context("git sent no host")?;
    print!("{}", ask(Path::new(&socket), host).await?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hosts_are_plain() {
        assert!(valid_host("github.com"));
        assert!(valid_host("git.example.com:8443"));
        for bad in ["", "a b", "x&y=1", "evil/path", "h\nx"] {
            assert!(!valid_host(bad), "{bad:?}");
        }
    }

    #[tokio::test]
    async fn broker_answers_over_the_socket() {
        let socket = bind_private().unwrap();
        let listener = UnixListener::bind(&socket).unwrap();
        tokio::spawn(broker(listener, |host: String| async move {
            Ok(Credential {
                username: "x-access-token".into(),
                password: format!("tok-for-{host}"),
            })
        }));
        let out = ask(&socket, "github.com").await.unwrap();
        assert_eq!(
            out,
            "username=x-access-token\npassword=tok-for-github.com\n"
        );
        assert!(ask(&socket, "x&y").await.is_err());
        let mode = std::fs::metadata(socket.parent().unwrap()).unwrap();
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(mode.permissions().mode() & 0o777, 0o700);
    }

    /// The gateway's URL never reaches the environment the agent's tools inherit.
    #[tokio::test]
    async fn gateway_url_stays_out_of_the_environment() {
        install("http://gateway.internal:9000/").unwrap();
        let leaked: Vec<_> = std::env::vars()
            .filter(|(_, v)| v.contains("gateway.internal"))
            .collect();
        assert!(leaked.is_empty(), "{leaked:?}");
        assert!(std::env::var_os(SOCKET_ENV).is_some());
    }
}
