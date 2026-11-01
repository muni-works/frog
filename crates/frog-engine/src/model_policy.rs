//! The two-tier model policy (docs/design/model-policy.md).
//!
//! **Tier 1** is frog cloud (`cloud/*`): the platform's own models, for workers, classifiers and
//! the Mac. **Tier 2** is BYOK: the user's own provider account or machine, for the interactive
//! session its owner sits in. Nothing hops between them, every retried call uses the same
//! numbers, and a session only starts on a model its gateway currently lists.

use crate::config::{Profile, ProviderKind};
use crate::provider::HttpError;
use crate::providers::{self, CLOUD};
use anyhow::{Result, bail};
use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

/// Retries one call may spend on a busy provider: waits of 1 s, 2 s and 4 s.
pub const MAX_RETRIES: u32 = 3;

/// How long a gateway's `/v1/models` list is trusted for a spawn check.
pub const LIST_TTL: Duration = Duration::from_secs(60);

/// How long a spawn waits for that list before treating the gateway as unreachable.
const LIST_TIMEOUT: Duration = Duration::from_secs(3);

/// Which tier a model belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tier {
    /// frog cloud: the platform's own models.
    Platform,
    /// The user's own provider account or gateway (vercel, anthropic, openai, openrouter,
    /// cloudflare, a server they added).
    Byok,
    /// This machine (apple/on-device, `local/`, ollama, LM Studio): no key, nothing leaves.
    OnDevice,
}

/// The tier `spec` runs on. Anything that isn't frog cloud and doesn't leave this machine is
/// BYOK.
pub fn tier(spec: &str, profile: &Profile) -> Tier {
    let id = spec
        .split_once('/')
        .map_or(spec, |(p, _)| providers::canonical(p));
    if id == CLOUD {
        Tier::Platform
    } else if crate::policy::is_cloud(profile) {
        Tier::Byok
    } else {
        Tier::OnDevice
    }
}

/// What a provider's error means for the policy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    /// 401: the key is wrong, missing or revoked.
    Auth,
    /// 402: the account is out of credits.
    Credits,
    /// 404: the gateway doesn't serve that model.
    Missing,
    /// 429, 5xx, an overloaded upstream: worth another try.
    Transient,
    /// A 400 or anything else: the same request fails the same way, so it doesn't retry.
    Other,
}

/// The class of a provider status. The first three fail fast; only [`Failure::Transient`]
/// retries.
pub fn class(status: u16) -> Failure {
    match status {
        401 | 403 => Failure::Auth,
        402 => Failure::Credits,
        404 => Failure::Missing,
        429 | 500..=599 => Failure::Transient,
        _ => Failure::Other,
    }
}

/// How long to wait before attempt `attempt + 1` (1 s, 2 s, 4 s).
pub fn retry_wait(attempt: u32) -> Duration {
    Duration::from_secs(1 << attempt.saturating_sub(1).min(2))
}

/// The provider's name as a person knows it (`vercel` → "Vercel AI Gateway").
fn name(id: &str) -> &str {
    providers::preset(id).map_or(id, |p| p.name)
}

/// The provider id `spec` names, when it names a known one.
fn provider_of(spec: &str) -> Option<&str> {
    let id = spec
        .split_once('/')
        .map_or(spec, |(p, _)| providers::canonical(p));
    providers::preset(id).map(|p| p.id)
}

/// The one-line fix for a fail-fast error, or `None` for anything that isn't one. This is what
/// the transcript shows instead of a retry card: what went wrong, and the one thing to do.
pub fn fix_line(spec: &str, failure: Failure) -> Option<String> {
    let id = provider_of(spec);
    let page = id.and_then(providers::preset).map(|p| p.key_url).unwrap_or("");
    let provider = id.map_or_else(
        || spec.split_once('/').map_or(spec, |(p, _)| p).to_string(),
        |id| name(id).to_string(),
    );
    match failure {
        Failure::Auth => Some(match id.and_then(providers::preset).and_then(|p| p.key_env.first()) {
            Some(env) if !page.is_empty() => {
                format!("{provider} rejected the key: set {env} or reconnect it in Settings ({page})")
            }
            Some(env) => format!("{provider} rejected the key: set {env}"),
            None if !page.is_empty() => {
                format!("{provider} rejected the key: reconnect it in Settings ({page})")
            }
            None => format!("{provider} rejected the key: reconnect it in Settings"),
        }),
        Failure::Credits => Some(if page.is_empty() {
            format!("{provider} credits are out: add credits in {provider}'s dashboard")
        } else {
            format!("{provider} credits are out: add credits at {page}")
        }),
        Failure::Missing => Some(format!(
            "model not listed: {spec} isn't in the gateway's /v1/models — pick one from that list"
        )),
        Failure::Transient | Failure::Other => None,
    }
}

/// The fix for an error that already happened, if it's a fail-fast one.
pub fn fix_for(spec: &str, e: &anyhow::Error) -> Option<String> {
    let h = e.downcast_ref::<HttpError>()?;
    fix_line(spec, class(h.status))
}

/// Whether `e` is the first and only answer: a wrong key, an empty wallet or a model the
/// gateway doesn't serve. Retrying it only spends time, so it never does.
pub fn is_fail_fast(e: &anyhow::Error) -> bool {
    e.downcast_ref::<HttpError>()
        .is_some_and(|h| matches!(class(h.status), Failure::Auth | Failure::Credits | Failure::Missing))
}

/// The line that says how to connect `spec`'s provider, for errors that aren't the provider's
/// own (a worker that can't run on rules alone, say).
pub fn connect_line(spec: &str) -> String {
    let id = provider_of(spec);
    let page = id.and_then(providers::preset).map(|p| p.key_url).unwrap_or("");
    let provider = id.map_or_else(|| spec.to_string(), |id| name(id).to_string());
    match id.and_then(providers::preset).and_then(|p| p.key_env.first()) {
        Some(env) if !page.is_empty() => format!("set {env} or connect {provider} in Settings ({page})"),
        Some(env) => format!("set {env}"),
        None if !page.is_empty() => format!("connect {provider} in Settings ({page})"),
        None => format!("connect {provider} in Settings"),
    }
}

/// Tests seed this instead of the network: `Some(map)` means the test owns every gateway's
/// list (a key with no entry is an unreachable gateway), `None` means fetch for real. Per
/// thread, so parallel tests never see each other's gateways (tokio's test runtimes are
/// single-threaded, so a test's own awaits stay on its thread).
#[cfg(test)]
thread_local! {
    pub static TEST_LISTS: std::cell::RefCell<Option<HashMap<String, Vec<String>>>> =
        const { std::cell::RefCell::new(None) };
}

/// The gateway lists fetched this process, by base URL, with when they were fetched.
static LISTS: LazyLock<Mutex<HashMap<String, (Instant, Vec<String>)>>> =
    LazyLock::new(Default::default);

/// A gateway's model ids as its `/v1/models` lists them now: the cached list while it's under
/// [`LIST_TTL`] old, else a fetch. `None` when the gateway can't be reached (which is not a
/// rejection: the first call reports the real problem).
async fn gateway_models(profile: &Profile) -> Option<Vec<String>> {
    let base = profile.base_url.as_deref()?.trim_end_matches('/').to_string();
    #[cfg(test)]
    if let Some(lists) = TEST_LISTS.with(|l| l.borrow().clone()) {
        return lists.get(&base).cloned();
    }
    if let Some((at, list)) = LISTS.lock().unwrap().get(&base)
        && at.elapsed() < LIST_TTL
    {
        return Some(list.clone());
    }
    let list = fetch_models(profile, &base).await?;
    LISTS.lock()
        .unwrap()
        .insert(base, (Instant::now(), list.clone()));
    Some(list)
}

async fn fetch_models(profile: &Profile, base: &str) -> Option<Vec<String>> {
    let url = if profile.provider == ProviderKind::Anthropic && !base.ends_with("/v1") {
        format!("{base}/v1/models")
    } else {
        format!("{base}/models")
    };
    let http = reqwest::Client::builder()
        .timeout(LIST_TIMEOUT)
        .build()
        .ok()?;
    let mut req = http.get(url);
    if let Some(k) = profile.api_key() {
        req = match profile.provider {
            ProviderKind::Anthropic => req
                .header("x-api-key", k)
                .header("anthropic-version", "2023-06-01"),
            _ => req.bearer_auth(k),
        };
    }
    let v: serde_json::Value = req
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?
        .json()
        .await
        .ok()?;
    Some(
        v["data"]
            .as_array()?
            .iter()
            .filter_map(|m| m["id"].as_str().map(str::to_owned))
            .collect(),
    )
}

/// Whether a session may start on `spec` right now. `cloud/*` and this machine always may
/// (the platform serves one, nothing lists the other); a hosted BYOK model only while its
/// gateway lists it. The check is at spawn, from a list cached for a minute — never per call.
pub async fn check_spawn(spec: &str, profile: &Profile) -> Result<()> {
    if tier(spec, profile) != Tier::Byok {
        return Ok(());
    }
    let Some(list) = gateway_models(profile).await else {
        // Unreachable: not a rejection. The first call says what's actually wrong.
        return Ok(());
    };
    if list.iter().any(|id| *id == profile.model) {
        return Ok(());
    }
    bail!(
        "{}",
        fix_line(spec, Failure::Missing).unwrap_or_else(|| "model not listed".into())
    )
}

/// [`check_spawn`] for a spec a client named (`StartSession`'s `model`, `SetSessionModel`'s):
/// resolved first, so an unknown provider fails here rather than in a session that then dies.
pub async fn check_spawn_spec(cfg: &crate::config::Config, spec: &str) -> Result<()> {
    let (name, profile) = cfg.resolve(Some(spec))?;
    check_spawn(&name, &profile).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn profile(kind: ProviderKind, base: Option<&str>) -> Profile {
        let mut p = Profile::new(kind, "m");
        p.base_url = base.map(str::to_owned);
        p
    }

    #[test]
    fn the_tiers_are_frog_cloud_this_machine_and_your_own_accounts() {
        let cloud = profile(ProviderKind::Openai, Some("https://api.frog.toys/v1"));
        assert_eq!(tier("cloud/bull", &cloud), Tier::Platform);
        assert_eq!(tier("frog/bull", &cloud), Tier::Platform);
        let vercel = profile(ProviderKind::Openai, Some("https://ai-gateway.vercel.sh/v1"));
        assert_eq!(tier("vercel/openai/gpt-5", &vercel), Tier::Byok);
        let anthropic = profile(ProviderKind::Anthropic, None);
        assert_eq!(tier("anthropic/claude-sonnet-5", &anthropic), Tier::Byok);
        let ollama = profile(ProviderKind::Ollama, Some("http://localhost:11434"));
        assert_eq!(tier("ollama/qwen3", &ollama), Tier::OnDevice);
        let apple = profile(ProviderKind::Openai, Some("http://127.0.0.1:9000/v1"));
        assert_eq!(tier("apple/on-device", &apple), Tier::OnDevice);
        // A named profile is whatever it actually points at.
        let named = profile(ProviderKind::Openai, Some("https://openrouter.ai/api/v1"));
        assert_eq!(tier("my-gateway", &named), Tier::Byok);
    }

    #[test]
    fn only_a_busy_provider_retries() {
        assert_eq!(class(401), Failure::Auth);
        assert_eq!(class(403), Failure::Auth);
        assert_eq!(class(402), Failure::Credits);
        assert_eq!(class(404), Failure::Missing);
        assert_eq!(class(429), Failure::Transient);
        assert_eq!(class(500), Failure::Transient);
        assert_eq!(class(529), Failure::Transient);
        assert_eq!(class(400), Failure::Other);
        // 1 s, 2 s, 4 s, and never longer.
        let waits: Vec<u64> = (1..=5).map(|a| retry_wait(a).as_secs()).collect();
        assert_eq!(waits, [1, 2, 4, 4, 4]);
    }

    #[test]
    fn the_fix_lines_name_the_provider_and_the_one_thing_to_do() {
        let credits = fix_line("vercel/openai/gpt-5", Failure::Credits).unwrap();
        assert!(credits.starts_with("Vercel AI Gateway credits are out: add credits at "), "{credits}");
        assert!(credits.contains("vercel.com/d"), "{credits}");
        let auth = fix_line("anthropic/claude-sonnet-5", Failure::Auth).unwrap();
        assert!(auth.contains("ANTHROPIC_API_KEY"), "{auth}");
        assert!(auth.contains("console.anthropic.com"), "{auth}");
        let missing = fix_line("openrouter/x/y", Failure::Missing).unwrap();
        assert!(missing.starts_with("model not listed:"), "{missing}");
        assert!(missing.contains("/v1/models"), "{missing}");
        // A busy provider has no fix to give: the retry says it.
        assert!(fix_line("vercel/x", Failure::Transient).is_none());
        // frog cloud's own key page.
        let cloud = fix_line("cloud/bull", Failure::Credits).unwrap();
        assert!(cloud.starts_with("frog cloud credits are out"), "{cloud}");
    }

    #[test]
    fn an_error_carries_its_own_fix() {
        let e: anyhow::Error = HttpError {
            status: 402,
            body: json!({"error": {"message": "insufficient credits"}}).to_string(),
            billing: None,
        }
        .into();
        assert!(fix_for("vercel/openai/gpt-5", &e).unwrap().contains("credits are out"));
        let ok: anyhow::Error = HttpError { status: 429, body: String::new(), billing: None }.into();
        assert!(fix_for("vercel/openai/gpt-5", &ok).is_none());
    }

    #[tokio::test]
    async fn spawn_takes_cloud_and_this_machine_but_only_a_listed_byok_model() {
        let base = "https://gateway.test/v1";
        TEST_LISTS.with(|l| {
            *l.borrow_mut() = Some(HashMap::from([(
                base.to_string(),
                vec!["openai/gpt-5".to_string()],
            )]))
        });
        let listed = {
            let mut p = Profile::new(ProviderKind::Openai, "openai/gpt-5");
            p.base_url = Some(base.into());
            p
        };
        // A listed model starts; one the gateway doesn't serve doesn't, with the fix.
        assert!(check_spawn("vercel/openai/gpt-5", &listed).await.is_ok());
        let mut gone = listed.clone();
        gone.model = "openai/gpt-9".into();
        let refused = check_spawn("vercel/openai/gpt-9", &gone).await.unwrap_err();
        assert!(format!("{refused}").contains("model not listed"), "{refused}");
        // cloud/* is the platform's to serve: always valid, no list needed.
        let cloud = profile(ProviderKind::Openai, Some("https://api.frog.toys/v1"));
        assert!(check_spawn("cloud/bull", &cloud).await.is_ok());
        // This machine's models have no gateway list.
        let ollama = profile(ProviderKind::Ollama, Some("http://localhost:11434"));
        assert!(check_spawn("ollama/qwen3", &ollama).await.is_ok());
        // A gateway with no list (unreachable) isn't a rejection.
        TEST_LISTS.with(|l| *l.borrow_mut() = Some(HashMap::new()));
        assert!(check_spawn("vercel/openai/gpt-9", &gone).await.is_ok());
        TEST_LISTS.with(|l| *l.borrow_mut() = None);
    }
}
