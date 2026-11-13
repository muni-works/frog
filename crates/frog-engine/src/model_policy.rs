//! The two-tier model policy (docs/design/model-policy.md).
//!
//! **Tier 1** is frog cloud (`cloud/*`): the platform's own models, for workers and classifiers.
//! A fresh install starts on this machine (`local/qwen3-4b`, or Apple Intelligence in the Mac
//! app), never on a billed model. **Tier 2** is BYOK: the user's own provider account or machine, for the interactive
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

/// Where `spec` runs and who pays, in words: the first-run banner and `frog account` say it.
pub fn where_it_runs(spec: &str, profile: &Profile) -> &'static str {
    if spec.starts_with("node/") {
        return "on your own machines, free";
    }
    match tier(spec, profile) {
        Tier::Platform => "Frog Cloud, billed per token",
        Tier::Byok => "your own provider account, billed by them",
        Tier::OnDevice => "on this machine, free",
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

/// Whether a session started on `profile` would get past its first model call: the provider's
/// credential resolves, and any local engine it needs is here. Reads only what frog already
/// reads (`Profile::api_key`, `providers::key_source`) — the same code a call would run — so
/// "yes" means the key exists where the request would find it. It doesn't call the provider:
/// a revoked key, an empty wallet and a wrong URL are for the first call to report.
pub fn credential_check(profile: &Profile) -> Result<()> {
    // The same resolution a provider client would do (`Provider::new` reads `p.api_key()`);
    // failing here, before a session row exists, is the point.
    //
    // Only a hosted preset frog can name is checked. A profile pointing at a URL frog doesn't
    // recognize is the user's own gateway: whether it wants a key is that gateway's business
    // (many local ones take none), and auth may ride in a header `extra` sends, which
    // `api_key()` cannot see. Refusing those refused working setups.
    let recognized = profile
        .base_url
        .as_deref()
        .filter(|u| !u.is_empty())
        .is_none_or(|url| {
            crate::providers::PRESETS.iter().any(|p| {
                !p.local
                    && ((p.kind == profile.provider && url.is_empty())
                        || (!p.base_url.is_empty()
                            && url.starts_with(p.base_url.trim_end_matches('/'))))
            })
        });
    let need_key = profile.sidecar.is_none()
        && !matches!(profile.provider, ProviderKind::Ollama | ProviderKind::Codex)
        && profile.provider != ProviderKind::Node
        && crate::policy::is_cloud(profile)
        && recognized;
    if need_key && profile.api_key().is_none() {
        // The spec may be a profile name, so the subject is the provider (kind or gateway),
        // and the fix names its usual variable or key page when frog knows them.
        let env = crate::policy::is_cloud(profile)
            .then(|| {
                let url = profile.base_url.as_deref().unwrap_or("");
                // Hosted presets only (`local` ones take no key), by the provider kind
                // first — an Anthropic profile is Anthropic's however it's configured —
                // then by base URL for the OpenAI-compatible gateways. A preset with no
                // static base URL (cloudflare, built per-request from the account id)
                // can't be recognized here, so it just isn't matched.
                crate::providers::PRESETS
                    .iter()
                    .filter(|p| !p.local)
                    .find(|p| {
                        (p.kind == profile.provider && url.is_empty())
                            || (!p.base_url.is_empty()
                                && url.starts_with(p.base_url.trim_end_matches('/')))
                    })
                    .map(|p| (p.id, p.key_env.first(), p.key_url))
            })
            .flatten();
        bail!(
            "{}",
            match env {
                Some((id, Some(e), page)) => format!(
                    "{id} has no key frog could send: set {e} or reconnect it in Settings ({page})"
                ),
                Some((id, None, _)) => format!("{id} has no key frog could send"),
                None => format!(
                    "{} has no key frog could send",
                    profile.model.rsplit('/').next().unwrap_or(&profile.model)
                ),
            }
        );
    }
    // This Mac's own engines: startable, or not (a missing binary is a setup step, not a key).
    if let Some(sidecar) = &profile.sidecar {
        if !crate::sidecar::available(sidecar) {
            bail!(
                "{} isn't available on this machine; run `frog setup`",
                if sidecar == crate::sidecar::APPLE { "the Apple Intelligence sidecar" } else { "frog's engine (tang-llm)" }
            );
        }
        // A tang model must be downloaded (`ensure` would refuse at start; same words).
        if sidecar != crate::sidecar::APPLE && !crate::setup::model_present(&profile.model) {
            bail!(
                "{} isn't downloaded; run `frog setup` (or `frog setup {}`)",
                profile.model,
                profile.model
            );
        }
    }
    Ok(())
}

/// [`credential_check`] for a spec a client named, in one place with [`check_spawn_spec`] so
/// both run before any session row exists (the real bug that asked for this: a session was
/// created, then its first call died on `ANTHROPIC_API_KEY not set`).
pub async fn check_credential_spec(cfg: &crate::config::Config, spec: &str) -> Result<()> {
    let (_, profile) = cfg.resolve(Some(spec))?;
    if let Err(e) = credential_check(&profile) {
        // The refusal carries what IS usable, so the next attempt names a model that works
        // instead of repeating the failure (a session row was never created).
        let err = match crate::models::usable_summary(cfg).await {
            Some(list) => anyhow::anyhow!("{e}.\nUsable right now: {list}"),
            None => anyhow::anyhow!(
                "{e}.\nNothing is usable right now: no local model is installed and no provider key is set (see `frog --models` and `frog account`)."
            ),
        };
        return Err(err);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn first_run_says_where_the_model_runs() {
        let cfg = crate::config::Config::default();
        let say = |spec: &str| where_it_runs(spec, &cfg.resolve(Some(spec)).unwrap().1);
        assert_eq!(say("local/qwen3-4b"), "on this machine, free");
        assert_eq!(
            say("cloud/qwen3-coder-next"),
            "Frog Cloud, billed per token"
        );
        assert_eq!(
            say("anthropic/claude-sonnet-5"),
            "your own provider account, billed by them"
        );
        assert_eq!(say("node/qwen3-8b"), "on your own machines, free");
    }

    fn profile(kind: ProviderKind, base: Option<&str>) -> Profile {
        let mut p = Profile::new(kind, "m");
        p.base_url = base.map(str::to_owned);
        p
    }

    #[test]
    fn the_tiers_are_frog_cloud_this_machine_and_your_own_accounts() {
        let cloud = profile(ProviderKind::Openai, Some("https://api.frog.toys/v1"));
        assert_eq!(tier("cloud/deepseek-v4.1-flash", &cloud), Tier::Platform);
        assert_eq!(tier("frog/deepseek-v4.1-flash", &cloud), Tier::Platform);
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
        let cloud = fix_line("cloud/deepseek-v4.1-flash", Failure::Credits).unwrap();
        assert!(cloud.starts_with("frog cloud credits are out"), "{cloud}");
    }

    #[test]
    fn an_error_carries_its_own_fix() {
        let e: anyhow::Error = HttpError {
            status: 402,
            body: json!({"error": {"message": "insufficient credits"}}).to_string(),
            billing: None,
            retry_after: None,
        }
        .into();
        assert!(fix_for("vercel/openai/gpt-5", &e).unwrap().contains("credits are out"));
        let ok: anyhow::Error = HttpError { status: 429, body: String::new(), billing: None, retry_after: None }.into();
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
        assert!(check_spawn("cloud/deepseek-v4.1-flash", &cloud).await.is_ok());
        // This machine's models have no gateway list.
        let ollama = profile(ProviderKind::Ollama, Some("http://localhost:11434"));
        assert!(check_spawn("ollama/qwen3", &ollama).await.is_ok());
        // A gateway with no list (unreachable) isn't a rejection.
        TEST_LISTS.with(|l| *l.borrow_mut() = Some(HashMap::new()));
        assert!(check_spawn("vercel/openai/gpt-9", &gone).await.is_ok());
        TEST_LISTS.with(|l| *l.borrow_mut() = None);
    }

    /// `StartSession`'s `model` goes through [`check_spawn_spec`]: resolved first (an unknown
    /// spec fails before any session starts), then listed (a BYOK gateway's model the gateway
    /// doesn't serve is refused with the fix, not turned into a session that dies on call 1).
    #[tokio::test]
    async fn spawn_spec_resolves_then_checks_a_named_models_gateway() {
        let base = "https://gateway.test/v1";
        TEST_LISTS.with(|l| {
            *l.borrow_mut() = Some(HashMap::from([(
                base.to_string(),
                vec!["openai/gpt-5".to_string()],
            )]))
        });
        let mut cfg = crate::config::Config::default();
        for model in ["openai/gpt-5", "openai/gpt-9"] {
            let mut p = Profile::new(ProviderKind::Openai, model);
            p.base_url = Some(base.into());
            cfg.models.insert(format!("gateway/{model}"), p);
        }
        // A listed profile starts.
        assert!(check_spawn_spec(&cfg, "gateway/openai/gpt-5").await.is_ok());
        // An unlisted one is refused with the fix.
        let refused = check_spawn_spec(&cfg, "gateway/openai/gpt-9").await.unwrap_err();
        assert!(format!("{refused}").contains("model not listed"), "{refused}");
        // An unknown spec is refused before anything else (resolved first).
        let unknown = check_spawn_spec(&cfg, "no-such-provider/x").await.unwrap_err();
        assert!(format!("{unknown}").contains("unknown provider"), "{unknown}");
        TEST_LISTS.with(|l| *l.borrow_mut() = None);
    }

    /// The credential check says what IS usable, not only what failed (the real bug: a session
    /// was created and then died on `ANTHROPIC_API_KEY not set`).
    #[tokio::test]
    async fn spawn_credential_refusal_names_what_is_usable() {
        // A cloud profile with no key anywhere: refused, and the refusal says something is
        // usable anyway (a test config's own model: frog's engine or the env key).
        let cfg = crate::config::Config::default();
        let e = check_credential_spec(&cfg, "anthropic/claude-opus-5-5")
            .await
            .unwrap_err()
            .to_string();
        assert!(e.contains("no key frog could send"), "{e}");
        assert!(e.contains("Usable right now") || e.contains("Nothing is usable"), "{e}");
        // One with a key: starts.
        let mut cfg = crate::config::Config::default();
        let mut p = Profile::new(ProviderKind::Anthropic, "claude-sonnet-5");
        p.api_key = Some("k".into());
        cfg.models.insert("mine".into(), p);
        assert!(check_credential_spec(&cfg, "mine").await.is_ok());
        // The refusal names the right provider: Anthropic (ANTHROPIC_API_KEY, its key page),
        // not whichever gateway is first in the preset list.
        let mut cfg = crate::config::Config::default();
        let p = Profile::new(ProviderKind::Anthropic, "claude-sonnet-5");
        cfg.models.insert("anth".into(), p);
        let e = check_credential_spec(&cfg, "anth").await.unwrap_err().to_string();
        assert!(e.contains("anthropic has no key"), "{e}");
        assert!(e.contains("ANTHROPIC_API_KEY"), "{e}");
        assert!(e.contains("console.anthropic.com"), "{e}");
        // A gateway profile names that gateway's variable.
        let mut p = Profile::new(ProviderKind::Openai, "openai/gpt-5");
        p.base_url = Some("https://openrouter.ai/api/v1".into());
        cfg.models.insert("orn".into(), p);
        let e = check_credential_spec(&cfg, "orn").await.unwrap_err().to_string();
        assert!(e.contains("openrouter has no key") && e.contains("OPENROUTER_API_KEY"), "{e}");
    }

    /// A local model is never asked for a key; a sidecar model needs its binary and weights.
    #[tokio::test]
    async fn local_models_need_no_key_and_a_sidecar_needs_its_setup() {
        let mut sidecar = Profile::new(ProviderKind::Openai, "mlx-community/Qwen3-4B-4bit");
        sidecar.sidecar = Some("mlx-community/Qwen3-4B-4bit".into());
        if crate::sidecar::available("tang") && crate::setup::model_present("mlx-community/Qwen3-4B-4bit") {
            assert!(credential_check(&sidecar).is_ok());
        } else {
            assert!(credential_check(&sidecar).is_err(), "missing setup says so");
        }
        // ollama is keyless by design.
        let ollama = profile(ProviderKind::Ollama, Some("http://localhost:11434"));
        assert!(credential_check(&ollama).is_ok());
    }
}
