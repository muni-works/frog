//! `--git-credential-gateway <url>`: git gets its tokens from Frog Cloud's gateway, never from
//! disk. frog points git (and every command it runs) at itself as the only credential helper;
//! `frog git-credential get` then asks `<url>/internal/git-credential?host=…`.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::io::Read;

const GATEWAY_ENV: &str = "FROG_GIT_CREDENTIAL_GATEWAY";

/// Make this process's children use `frog git-credential` as git's only credential helper.
/// Through the environment, so nothing is written to a git config.
pub fn install(gateway: &str) -> Result<()> {
    let exe = std::env::current_exe().context("finding frog's own path")?;
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
        std::env::set_var(GATEWAY_ENV, gateway.trim_end_matches('/'));
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

#[derive(Deserialize)]
struct Credential {
    username: String,
    password: String,
}

/// `frog git-credential <get|store|erase>`, as git runs a helper. Only `get` does anything.
pub async fn helper(action: Option<&str>) -> Result<()> {
    if action != Some("get") {
        return Ok(());
    }
    let gateway = std::env::var(GATEWAY_ENV).context("no credential gateway")?;
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input)?;
    let host = input
        .lines()
        .find_map(|l| l.strip_prefix("host="))
        .context("git sent no host")?;
    let url = reqwest::Url::parse_with_params(
        &format!("{gateway}/internal/git-credential"),
        &[("host", host)],
    )?;
    let c: Credential = reqwest::get(url).await?.error_for_status()?.json().await?;
    println!("username={}\npassword={}", c.username, c.password);
    Ok(())
}
