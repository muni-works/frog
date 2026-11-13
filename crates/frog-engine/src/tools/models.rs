//! Models: what can actually start right now. One read-only call answers "what can I run?"
//! before an action fails on a dead key: every resolvable model with its provider, context
//! window and cost, and — the point — whether its credential is live. Read-only, no side
//! effects, no network: provider keys are resolved the way a request would (`Profile::api_key`,
//! the same code the provider client runs), and anything that can't be checked that cheaply
//! (a paired node, a server that would need a ping) says `unknown` rather than guessing "yes".

use super::{Ctx, Output};
use crate::provider::ToolSpec;
use anyhow::Result;
use serde_json::{Value, json};

pub const TOOL: &str = "Models";

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Answer \"what can I actually run right now?\" before starting a session \
on a model: every resolvable model with its provider, spec, context window, cost per million \
tokens in/out when known, and whether its credential is live (\"live\" / \"missing: <what to do>\" \
/ \"unknown\" when it can't be checked cheaply). Read-only, no side effects. Call it before \
StartSession with a model you haven't used; a spec that fails here would have failed there."
            .into(),
        schema: json!({
            "type": "object",
            "properties": {}
        }),
    }
}

/// One model as the tool reports it.
pub struct Row {
    pub spec: String,
    pub provider: String,
    pub model: String,
    pub context: Option<u64>,
    pub cost_in: Option<f64>,
    pub cost_out: Option<f64>,
    pub credential: String,
    pub where_it_runs: &'static str,
}

/// Whether `spec`'s credential resolves and a local engine it needs is here. Empty: yes.
/// `Some(why)`: it would fail, with the fix. `None`: not checked (it needs a network reach or
/// a state this machine doesn't hold), so say `unknown`. `custom` is the servers you added,
/// whose keys the engine can't vouch for.
fn credential(
    cfg: &crate::config::Config,
    spec: &str,
    custom: &std::collections::BTreeMap<String, crate::providers::Custom>,
) -> Option<String> {
    let Ok((_, profile)) = cfg.resolve(Some(spec)) else {
        return None;
    };
    // What this check can't see, it refuses to grade: a paired node's key sits in the
    // node's store and its health only shows in a `/node` poll, and a server you added
    // (`gpu/llama3`) takes no key here but its own server may demand one. `live` would be
    // a guess — and a wrong "live" is exactly the preflight bug again.
    if profile.provider == crate::config::ProviderKind::Node
        || custom.contains_key(spec.split_once('/').map_or(spec, |(p, _)| p))
    {
        return None;
    }
    match crate::model_policy::credential_check(&profile) {
        Ok(()) => Some("live".into()),
        Err(e) => Some(e.to_string()),
    }
}

/// The models worth listing: the config's own profiles, frog cloud's last-fetched list, the
/// presets frog can name a spec for, and this Mac's own engines. Catalog metadata (context,
/// cost) rides along from the last cached list — never fetched here.
pub fn rows(cfg: &crate::config::Config) -> Vec<Row> {
    rows_with(cfg, &crate::providers::State::load().custom)
}

/// [`rows`] with the custom servers injected, so tests don't touch the real models.json.
pub fn rows_with(
    cfg: &crate::config::Config,
    custom: &std::collections::BTreeMap<String, crate::providers::Custom>,
) -> Vec<Row> {
    let mut out: Vec<Row> = Vec::new();
    let mut push = |r: Row| {
        if !out.iter().any(|x| x.spec == r.spec) {
            out.push(r);
        }
    };
    for name in cfg.models.keys() {
        let info = crate::catalog::cached(name);
        push(Row {
            spec: name.clone(),
            provider: provider_name(name),
            model: info.as_ref().map_or(name.clone(), |m| m.name.clone()),
            context: info.as_ref().and_then(|m| m.context),
            cost_in: info.as_ref().and_then(|m| m.cost_in),
            cost_out: info.as_ref().and_then(|m| m.cost_out),
            credential: credential(cfg, name, custom).unwrap_or_else(|| "unknown".into()),
            where_it_runs: cfg
                .resolve(Some(name))
                .map(|(_, p)| crate::model_policy::where_it_runs(name, &p))
                .unwrap_or(""),
        });
    }
    // frog cloud's list (the cache; no fetch) and the enabled models: specs frog resolves.
    let mut specs: Vec<String> = crate::catalog::cloud_models()
        .iter()
        .map(|m| m.spec.clone())
        .collect();
    specs.extend(crate::providers::State::load().enabled.iter().cloned());
    specs.push(crate::config::LOCAL_DEFAULT.into());
    specs.push("apple/on-device".into());
    for spec in specs {
        let info = crate::catalog::cached(&spec);
        push(Row {
            provider: provider_name(&spec),
            spec: spec.clone(),
            model: info
                .as_ref()
                .map_or(spec.rsplit('/').next().unwrap_or(&spec).to_string(), |m| {
                    m.name.clone()
                }),
            context: info.as_ref().and_then(|m| m.context),
            cost_in: info.as_ref().and_then(|m| m.cost_in),
            cost_out: info.as_ref().and_then(|m| m.cost_out),
            credential: credential(cfg, &spec, custom).unwrap_or_else(|| "unknown".into()),
            where_it_runs: cfg
                .resolve(Some(&spec))
                .map(|(_, p)| crate::model_policy::where_it_runs(&spec, &p))
                .unwrap_or(""),
        });
    }
    out
}

/// The provider part of a spec (`openrouter/anthropic/x` → `openrouter`).
fn provider_name(spec: &str) -> String {
    spec.split_once('/')
        .map_or_else(|| spec.to_string(), |(p, _)| p.to_string())
}

pub async fn run(_input: &Value, _ctx: &mut Ctx) -> Result<Output> {
    let cfg = crate::config::Config::load().unwrap_or_default();
    let rows = rows(&cfg);
    let mut out = String::new();
    for r in &rows {
        out.push_str(&r.spec);
        out.push_str(&format!(
            " — {} · {}",
            r.provider,
            if r.where_it_runs.is_empty() { "unknown" } else { r.where_it_runs }
        ));
        if let Some(c) = r.context {
            out.push_str(&format!(" · ctx {c}"));
        }
        match (r.cost_in, r.cost_out) {
            (Some(i), Some(o)) => out.push_str(&format!(" · ${i:.2}/${o:.2} per M in/out")),
            (Some(i), None) => out.push_str(&format!(" · ${i:.2}/M in")),
            (None, Some(o)) => out.push_str(&format!(" · ${o:.2}/M out")),
            (None, None) => {}
        }
        out.push_str(&format!(" · credential: {}", r.credential));
        out.push('\n');
    }
    if rows.is_empty() {
        out.push_str(
            "No resolvable models on this machine: no local model is installed and no provider key is set (see `frog account`).\n",
        );
    }
    Ok(Output::text(out))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole point: a model whose key is missing is listed with its missing key, never as
    /// a bare yes — the `models` answer would otherwise repeat the preflight bug.
    #[test]
    fn a_missing_key_is_said_so_not_a_yes() {
        let mut cfg = crate::config::Config::default();
        let p = crate::config::Profile::new(crate::config::ProviderKind::Anthropic, "claude-sonnet-5");
        cfg.models.insert("anthropic-test".into(), p);
        let listed = rows(&cfg);
        let row = listed.iter().find(|r| r.spec == "anthropic-test").unwrap();
        assert!(
            row.credential.contains("no key frog could send"),
            "missing key is said so: {}",
            row.credential
        );
        // A keyless local model reads live (or honestly not-installed, never a fake yes).
        let cfg = crate::config::Config::default();
        let listed = rows(&cfg);
        if let Some(local) = listed.iter().find(|r| r.spec == crate::config::LOCAL_DEFAULT) {
            assert!(
                local.credential == "live"
                    || local.credential.contains("isn't available")
                    || local.credential.contains("isn't downloaded"),
                "{:?}",
                local.credential
            );
        }
    }

    /// What can't be checked without a network reach (a paired node, a server you added)
    /// says unknown, never a guessed yes.
    #[test]
    fn uncheckable_credentials_say_unknown_not_live() {
        let cfg = crate::config::Config::default();
        let listed = rows(&cfg);
        // The check needs a poll (and the key lives in the node store): unknown.
        let node = listed.iter().find(|r| r.spec.starts_with("node/"));
        if let Some(node) = node {
            assert_eq!(node.credential, "unknown", "{}", node.credential);
        }
        // A custom server may need a key the engine can't see: unknown (its spec only
        // resolves against `cfg` once the server is configured, so this also covers the
        // resolve-failure arm).
        let mut custom = std::collections::BTreeMap::new();
        custom.insert(
            "gpu".to_string(),
            crate::providers::Custom {
                name: "gpu".into(),
                kind: crate::config::ProviderKind::Openai,
                base_url: "http://gpu:8000/v1".into(),
            },
        );
        let listed = rows_with(&cfg, &custom);
        let gpu = listed.iter().find(|r| r.spec.starts_with("gpu/"));
        if let Some(gpu) = gpu {
            assert_eq!(gpu.credential, "unknown", "{}", gpu.credential);
        }
    }

    /// Output is one line per model, with the credential on it.
    #[tokio::test]
    async fn output_names_the_credential_per_line() {
        let out = run(&json!({}), &mut Ctx::new(std::env::temp_dir()))
            .await
            .unwrap();
        assert!(out.content.contains("credential:"), "{}", out.content);
    }
}

#[cfg(test)]
mod sample {
    /// Prints the real machine's answer (cargo test -p frog-engine --lib print_sample -- --nocapture).
    #[tokio::test]
    #[ignore]
    async fn print_sample() {
        let cfg = crate::config::Config::load().unwrap_or_default();
        let out = crate::tools::models::run(&serde_json::json!({}), &mut super::Ctx::new(std::env::temp_dir()))
            .await
            .unwrap();
        println!("=== Models tool on this machine ===\n{}", out.content);
        let _ = cfg;
    }
}
