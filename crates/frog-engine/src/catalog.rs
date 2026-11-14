//! What each connected provider offers, with what's worth knowing to pick one: context size,
//! inputs, reasoning, tool use and price. Gateways describe their own models (OpenRouter and
//! Vercel's model lists are rich); for the rest, models.dev (the open catalog OpenCode uses)
//! fills in. Lists are cached per provider for a few hours.

use crate::config::{ProviderKind, data_dir};
use crate::protocol::ServedBy;
use crate::providers::{self, ProviderInfo};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const TTL: Duration = Duration::from_secs(6 * 3600);
const MODELS_DEV: &str = "https://models.dev/api.json";

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Model {
    /// `provider/model`, what `--model` takes.
    pub spec: String,
    pub provider: String,
    pub id: String,
    pub name: String,
    pub context: Option<u64>,
    pub max_output: Option<u64>,
    /// "text", "image", "audio", "video", "file".
    pub inputs: Vec<String>,
    pub reasoning: bool,
    pub tools: bool,
    /// Dollars per million tokens.
    pub cost_in: Option<f64>,
    pub cost_out: Option<f64>,
    /// Dollars per million cached input tokens read, and written to the cache, when listed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_cache_read: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_cache_write: Option<f64>,
    /// Who runs it for frog cloud: its own GPUs or a third party. Only frog cloud's models.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub served_by: Option<ServedBy>,
}

impl Model {
    pub fn vision(&self) -> bool {
        self.inputs.iter().any(|i| i == "image")
    }
}

#[derive(Serialize, Deserialize)]
struct Cached {
    fetched: u64,
    models: Vec<Model>,
}

fn cache_path(provider: &str) -> PathBuf {
    data_dir().join("catalog").join(format!("{provider}.json"))
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn read_cache(provider: &str) -> Option<Cached> {
    serde_json::from_slice(&std::fs::read(cache_path(provider)).ok()?).ok()
}

fn write_cache(provider: &str, models: &[Model]) {
    let path = cache_path(provider);
    let _ = std::fs::create_dir_all(path.parent().unwrap());
    let body = Cached {
        fetched: now(),
        models: models.to_vec(),
    };
    if let Ok(b) = serde_json::to_vec(&body) {
        let _ = std::fs::write(path, b);
    }
}

/// Tests seed this instead of the on-disk cache, so they don't read (or write) the real one.
#[cfg(test)]
pub static TEST_CACHE: std::sync::Mutex<Option<std::collections::HashMap<String, Model>>> =
    std::sync::Mutex::new(None);

/// What's known about one model, from the cache alone (no network): for `resolve`.
pub fn cached(spec: &str) -> Option<Model> {
    #[cfg(test)]
    if let Some(m) = TEST_CACHE
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|c| c.get(spec))
    {
        return Some(m.clone());
    }
    let (provider, _) = spec.split_once('/')?;
    let found = read_cache(provider).and_then(|c| c.models.into_iter().find(|m| m.spec == spec));
    if provider == "cloudflare" {
        return found.or_else(|| cf_models().into_iter().find(|m| m.spec == spec));
    }
    found
}

/// frog cloud's models, without the network: the last list `/v1/models` gave (empty when it
/// was never reached). frog cloud's own list is the only word on what it serves.
pub fn cloud_models() -> Vec<Model> {
    #[cfg(test)]
    {
        let seeded: Vec<Model> = TEST_CACHE
            .lock()
            .unwrap()
            .iter()
            .flat_map(|c| c.values())
            .filter(|m| m.provider == providers::CLOUD)
            .cloned()
            .collect();
        if !seeded.is_empty() {
            return seeded;
        }
    }
    read_cache(providers::CLOUD)
        .map(|c| c.models)
        .unwrap_or_default()
}

/// The Frog Cloud model to start on when nothing names one (new sessions, child sessions,
/// the Mac's "frog's own default"): `cloud/deepseek-v4.1-flash` while Frog Cloud lists it,
/// else the first model it lists. A gateway that still lists the old id (`bull`) counts.
/// Measured 2026-11-14 on one five-part agent task: deepseek-v4.1-flash 89 s, glm-5.3-flash
/// 179 s (81 s of it thinking).
pub fn cloud_default(models: &[Model]) -> Option<String> {
    models
        .iter()
        .find(|m| providers::cloud_model(&m.id) == "deepseek-v4.1-flash")
        .or_else(|| models.first())
        .map(|m| m.spec.clone())
}

/// How long frog cloud's own list is trusted: it changes when frog cloud adds a model or moves
/// one to another server, and every app should show the change the same hour (the web app
/// reads `/v1/models` on every load).
const CLOUD_TTL: Duration = Duration::from_secs(10 * 60);

/// frog cloud's models as `/v1/models` lists them now: fetched when older than `CLOUD_TTL`,
/// else the cached list; unreachable, the last list (or none). Signed out, its public list.
pub async fn cloud_models_fresh() -> Vec<Model> {
    let cached = read_cache(providers::CLOUD);
    if let Some(c) = &cached
        && now().saturating_sub(c.fetched) < CLOUD_TTL.as_secs()
        && !c.models.is_empty()
    {
        return c.models.clone();
    }
    let info = providers::list(&providers::State::load())
        .into_iter()
        .find(|p| p.id == providers::CLOUD);
    if let Some(p) = info {
        let dev = std::sync::Arc::new(tokio::sync::OnceCell::new());
        if let Some(models) = fetch(&p, &dev).await.filter(|m| !m.is_empty()) {
            write_cache(providers::CLOUD, &models);
            return models;
        }
    }
    cached.map(|c| c.models).unwrap_or_default()
}

/// Gateways whose model lists are public: browsable before you connect them, and fetched
/// without a key (a wrong key would get the request refused).
fn public(provider: &str) -> bool {
    matches!(provider, "openrouter" | "vercel")
}

/// Providers listed before you connect them: the public gateways, and frog cloud, whose
/// `/v1/models` answers without a key (and with one, once connected).
fn listed_signed_out(provider: &str) -> bool {
    public(provider) || provider == providers::CLOUD
}

/// Cloudflare AI Gateway's suggested models, built in: the account id in the base URL means
/// the key alone can't list them yet. (id, name, context)
const STATIC_CF: &[(&str, &str, u64)] = providers::CF_MODELS;

fn static_cf_model(&(id, name, context): &(&str, &str, u64)) -> Model {
    Model {
        spec: format!("cloudflare/{id}"),
        provider: "cloudflare".into(),
        id: id.into(),
        name: name.into(),
        context: Some(context),
        tools: true,
        ..Default::default()
    }
}

/// Cloudflare's models, without the network: the last fetched list, else the built-in one.
fn cf_models() -> Vec<Model> {
    read_cache("cloudflare")
        .map(|c| c.models)
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| STATIC_CF.iter().map(static_cf_model).collect())
}

/// The models of every connected remote provider (and the public gateways and frog cloud,
/// listed without a key when not connected): cached, or fetched when stale (or when
/// `refresh`). A provider that can't be reached keeps its last list (none, if it never had one).
pub async fn all(refresh: bool) -> Vec<Model> {
    let state = providers::State::load();
    let all = providers::list(&state);
    let cf_connected = all.iter().any(|p| p.id == "cloudflare" && p.connected);
    let remote: Vec<ProviderInfo> = all
        .into_iter()
        .filter(|p| !p.local && (p.connected || listed_signed_out(&p.id)))
        .collect();
    let dev = std::sync::Arc::new(tokio::sync::OnceCell::new());
    let jobs = remote.into_iter().map(|p| {
        let dev = dev.clone();
        async move {
            let cached = read_cache(&p.id);
            let fresh = cached
                .as_ref()
                .is_some_and(|c| now().saturating_sub(c.fetched) < TTL.as_secs());
            if fresh && !refresh {
                return cached.map(|c| c.models).unwrap_or_default();
            }
            match fetch(&p, &dev).await {
                Some(models) if !models.is_empty() => {
                    write_cache(&p.id, &models);
                    models
                }
                _ => cached.map(|c| c.models).unwrap_or_default(),
            }
        }
    });
    let mut out: Vec<Model> = futures_util::future::join_all(jobs)
        .await
        .into_iter()
        .flatten()
        .collect();
    // Cloudflare's suggested models: its live list is fetched too, so only fill in
    // when the fetch (and cache) came back empty.
    if cf_connected && !out.iter().any(|m| m.provider == "cloudflare") {
        out.extend(cf_models());
    }
    out
}

type Dev = std::sync::Arc<tokio::sync::OnceCell<Option<Value>>>;

async fn models_dev(dev: &Dev) -> Option<&Value> {
    dev.get_or_init(|| async {
        let get = async {
            reqwest::get(MODELS_DEV)
                .await
                .ok()?
                .json::<Value>()
                .await
                .ok()
        };
        tokio::time::timeout(Duration::from_secs(15), get)
            .await
            .ok()
            .flatten()
    })
    .await
    .as_ref()
}

async fn fetch(p: &ProviderInfo, dev: &Dev) -> Option<Vec<Model>> {
    let http = reqwest::Client::builder()
        .timeout(Duration::from_secs(20))
        .build()
        .ok()?;
    let key = providers::key(&p.id).filter(|_| !public(&p.id));
    let base = p.base_url.trim_end_matches('/');
    let mut req = http.get(format!("{base}/models"));
    if let Some(k) = &key {
        req = match p.kind {
            ProviderKind::Anthropic => req
                .header("x-api-key", k)
                .header("anthropic-version", "2023-06-01"),
            _ => req.bearer_auth(k),
        };
    }
    let body: Value = req
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?
        .json()
        .await
        .ok()?;
    let data = body["data"].as_array()?;
    let mut models: Vec<Model> = match p.id.as_str() {
        "openrouter" => data.iter().filter_map(|m| openrouter(&p.id, m)).collect(),
        "vercel" => data.iter().filter_map(|m| vercel(&p.id, m)).collect(),
        providers::CLOUD => data.iter().filter_map(frog_cloud).collect(),
        _ => data
            .iter()
            .filter_map(|m| {
                let id = m["id"].as_str()?;
                Some(Model {
                    spec: format!("{}/{id}", p.id),
                    provider: p.id.clone(),
                    id: id.into(),
                    name: m["display_name"].as_str().unwrap_or(id).into(),
                    inputs: vec!["text".into()],
                    ..Default::default()
                })
            })
            .collect(),
    };
    // Fill the gaps from models.dev (context, inputs, reasoning, tools, price).
    if models.iter().any(|m| m.context.is_none())
        && let Some(dev) = models_dev(dev).await
    {
        for m in models.iter_mut().filter(|m| m.context.is_none()) {
            if let Some(d) = lookup(dev, &p.id, &m.id) {
                enrich(m, d);
            }
        }
    }
    models.sort_by_key(|m| m.name.to_lowercase());
    Some(models)
}

fn per_million(v: &Value) -> Option<f64> {
    let per_token: f64 = match v {
        Value::String(s) => s.parse().ok()?,
        Value::Number(n) => n.as_f64()?,
        _ => return None,
    };
    (per_token >= 0.0).then_some(per_token * 1_000_000.0)
}

/// A frog cloud `/v1/models` entry: OpenRouter's shape (context, input modalities, supported
/// parameters, dollars per token) plus its display name and who serves it.
fn frog_cloud(m: &Value) -> Option<Model> {
    let mut model = openrouter(providers::CLOUD, m)?;
    if let Some(name) = m["display_name"].as_str() {
        model.name = plain_name(name).into();
    }
    model.served_by = ServedBy::parse(&m["served_by"]);
    Some(model)
}

/// A display name without the old animal moniker: "Tree (GLM-5.3 Flash)" is "GLM-5.3 Flash".
fn plain_name(name: &str) -> &str {
    providers::CLOUD_ALIASES
        .iter()
        .find_map(|(old, _)| {
            let rest = name.get(old.len()..)?;
            name[..old.len()]
                .eq_ignore_ascii_case(old)
                .then_some(rest)?
                .strip_prefix(" (")?
                .strip_suffix(')')
        })
        .unwrap_or(name)
}

fn openrouter(provider: &str, m: &Value) -> Option<Model> {
    let id = m["id"].as_str()?;
    let params: Vec<&str> = m["supported_parameters"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    let outputs = m["architecture"]["output_modalities"].as_array();
    if outputs.is_some_and(|o| !o.iter().any(|v| v == "text")) {
        return None;
    }
    Some(Model {
        spec: format!("{provider}/{id}"),
        provider: provider.into(),
        id: id.into(),
        name: m["name"].as_str().unwrap_or(id).into(),
        context: m["context_length"].as_u64(),
        max_output: m["top_provider"]["max_completion_tokens"].as_u64(),
        inputs: m["architecture"]["input_modalities"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_else(|| vec!["text".into()]),
        reasoning: params.contains(&"reasoning"),
        tools: params.contains(&"tools"),
        cost_in: per_million(&m["pricing"]["prompt"]),
        cost_out: per_million(&m["pricing"]["completion"]),
        cost_cache_read: per_million(&m["pricing"]["input_cache_read"]),
        cost_cache_write: per_million(&m["pricing"]["input_cache_write"]),
        served_by: None,
    })
}

fn vercel(provider: &str, m: &Value) -> Option<Model> {
    let id = m["id"].as_str()?;
    if m["type"].as_str().is_some_and(|t| t != "language") {
        return None;
    }
    let tags: Vec<&str> = m["tags"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str()).collect())
        .unwrap_or_default();
    // `modalities.input` when given; older entries only have tags.
    let inputs = match m["modalities"]["input"].as_array() {
        Some(a) => a
            .iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect(),
        None => {
            let mut v = vec!["text".to_string()];
            if tags.contains(&"vision") {
                v.push("image".into());
            }
            if tags.contains(&"file-input") {
                v.push("file".into());
            }
            v
        }
    };
    Some(Model {
        spec: format!("{provider}/{id}"),
        provider: provider.into(),
        id: id.into(),
        name: m["name"].as_str().unwrap_or(id).into(),
        context: m["context_window"].as_u64(),
        max_output: m["max_tokens"].as_u64(),
        inputs,
        reasoning: tags.contains(&"reasoning"),
        tools: tags.contains(&"tool-use"),
        cost_in: per_million(&m["pricing"]["input"]),
        cost_out: per_million(&m["pricing"]["output"]),
        cost_cache_read: per_million(&m["pricing"]["input_cache_read"]),
        cost_cache_write: per_million(&m["pricing"]["input_cache_write"]),
        served_by: None,
    })
}

/// A model's models.dev record: under its provider, or (for gateways and servers that name
/// models `vendor/model`) under the vendor.
fn lookup<'a>(dev: &'a Value, provider: &str, id: &str) -> Option<&'a Value> {
    let under = |p: &str, m: &str| dev.get(p)?.get("models")?.get(m);
    under(provider, id).or_else(|| {
        let (vendor, model) = id.split_once('/')?;
        under(vendor, model)
    })
}

fn enrich(m: &mut Model, d: &Value) {
    m.context = m.context.or(d["limit"]["context"].as_u64());
    m.max_output = m.max_output.or(d["limit"]["output"].as_u64());
    if let Some(inputs) = d["modalities"]["input"].as_array() {
        m.inputs = inputs
            .iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect();
    }
    m.reasoning |= d["reasoning"].as_bool().unwrap_or(false);
    m.tools |= d["tool_call"].as_bool().unwrap_or(false);
    m.cost_in = m.cost_in.or(d["cost"]["input"].as_f64());
    m.cost_out = m.cost_out.or(d["cost"]["output"].as_f64());
    m.cost_cache_read = m.cost_cache_read.or(d["cost"]["cache_read"].as_f64());
    m.cost_cache_write = m.cost_cache_write.or(d["cost"]["cache_write"].as_f64());
    if m.name == m.id
        && let Some(n) = d["name"].as_str()
    {
        m.name = n.into();
    }
}

/// Group by provider for display, in the shared rank (This Mac, your servers, frog cloud,
/// other clouds), then by id.
pub fn by_provider(models: &[Model]) -> Vec<(&str, Vec<&Model>)> {
    let mut out: Vec<(&str, Vec<&Model>)> = Vec::new();
    for m in models {
        match out.iter_mut().find(|(p, _)| *p == m.provider) {
            Some((_, v)) => v.push(m),
            None => out.push((m.provider.as_str(), vec![m])),
        }
    }
    out.sort_by(|a, b| (providers::rank(a.0), a.0).cmp(&(providers::rank(b.0), b.0)));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_openrouter_and_vercel_entries() {
        let or = json!({
            "id": "anthropic/claude-sonnet-5", "name": "Anthropic: Claude Sonnet 5",
            "context_length": 1000000,
            "architecture": {"input_modalities": ["text", "image"], "output_modalities": ["text"]},
            "pricing": {"prompt": "0.000003", "completion": "0.000015"},
            "supported_parameters": ["tools", "reasoning", "temperature"],
            "top_provider": {"max_completion_tokens": 64000}
        });
        let m = openrouter("openrouter", &or).unwrap();
        assert_eq!(m.spec, "openrouter/anthropic/claude-sonnet-5");
        assert!(m.vision() && m.tools && m.reasoning);
        assert_eq!(m.context, Some(1_000_000));
        assert!((m.cost_in.unwrap() - 3.0).abs() < 1e-9);

        let image_only = json!({"id": "x/img", "architecture": {"output_modalities": ["image"]}});
        assert!(openrouter("openrouter", &image_only).is_none());

        let v = json!({
            "id": "openai/gpt-5", "name": "GPT-5", "type": "language",
            "context_window": 400000, "max_tokens": 128000,
            "tags": ["reasoning", "tool-use", "vision"],
            "pricing": {"input": "0.00000125", "output": "0.00001"}
        });
        let m = vercel("vercel", &v).unwrap();
        assert_eq!(m.spec, "vercel/openai/gpt-5");
        assert!(m.vision() && m.tools && m.reasoning);
        assert!(m.cost_cache_read.is_none());
        assert!(vercel("vercel", &json!({"id": "e", "type": "embedding"})).is_none());

        let v = json!({
            "id": "anthropic/claude-opus-5.5", "type": "language",
            "pricing": {"input": "0.000004", "output": "0.00002",
                        "input_cache_read": "0.0000004", "input_cache_write": "0.000005"}
        });
        let m = vercel("vercel", &v).unwrap();
        assert!((m.cost_cache_read.unwrap() - 0.4).abs() < 1e-9);
        assert!((m.cost_cache_write.unwrap() - 5.0).abs() < 1e-9);
    }

    #[test]
    fn by_provider_follows_the_rank() {
        let m = |p: &str| Model {
            spec: format!("{p}/x"),
            provider: p.into(),
            id: "x".into(),
            ..Default::default()
        };
        let models = vec![
            m("anthropic"),
            m("openrouter"),
            m("cloud"),
            m("gpu"),
            m("ollama"),
        ];
        let order: Vec<&str> = by_provider(&models).iter().map(|(p, _)| *p).collect();
        assert_eq!(order, ["ollama", "gpu", "cloud", "anthropic", "openrouter"]);
    }

    #[test]
    fn frog_cloud_entries_describe_themselves() {
        let entry = json!({
            "id": "glm-5.3-flash", "object": "model", "display_name": "GLM-5.3 Flash",
            "context_length": 1048576,
            "architecture": {"input_modalities": ["text", "image"]},
            "supported_parameters": ["tools", "reasoning"],
            "served_by": {"id": "workers-ai", "name": "Cloudflare Workers AI", "third_party": true},
            "pricing": {"prompt": "0.00000018", "completion": "0.0000006",
                        "input_cache_read": "0.000000036", "request": "0", "image": "0"}
        });
        let m = frog_cloud(&entry).unwrap();
        assert_eq!(m.spec, format!("{}/glm-5.3-flash", providers::CLOUD));
        assert_eq!(m.name, "GLM-5.3 Flash");
        assert_eq!(m.context, Some(1_048_576));
        assert!(m.vision() && m.reasoning && m.tools);
        assert!((m.cost_in.unwrap() - 0.18).abs() < 1e-9);
        assert!((m.cost_out.unwrap() - 0.6).abs() < 1e-9);
        assert!((m.cost_cache_read.unwrap() - 0.036).abs() < 1e-9);
        assert_eq!(m.served_by.unwrap().id, "workers-ai");

        // An older gateway's moniker never reaches a name.
        let m = frog_cloud(&json!({"id": "tree", "display_name": "Tree (GLM-5.3 Flash)"})).unwrap();
        assert_eq!(m.name, "GLM-5.3 Flash");
        assert_eq!(plain_name("Treehouse (x)"), "Treehouse (x)");

        // A bare entry: text only, no reasoning or tools claimed, named by its id.
        let m = frog_cloud(&json!({"id": "qwen3-coder-next"})).unwrap();
        assert_eq!(m.name, "qwen3-coder-next");
        assert_eq!(m.inputs, ["text"]);
        assert!(!m.reasoning && !m.tools && m.served_by.is_none());
    }

    #[test]
    fn the_default_frog_cloud_model_is_deepseek_flash_else_the_first_listed() {
        let m = |id: &str| Model {
            spec: format!("{}/{id}", providers::CLOUD),
            id: id.into(),
            ..Default::default()
        };
        let cloud = providers::CLOUD;
        assert_eq!(
            cloud_default(&[m("glm-5.3-flash"), m("qwen3-coder-next"), m("deepseek-v4.1-flash")]),
            Some(format!("{cloud}/deepseek-v4.1-flash"))
        );
        // An older gateway still listing the old id.
        assert_eq!(
            cloud_default(&[m("tree"), m("bull")]),
            Some(format!("{cloud}/bull"))
        );
        assert_eq!(
            cloud_default(&[m("glm-5.3-flash"), m("qwen3-coder-next")]),
            Some(format!("{cloud}/glm-5.3-flash"))
        );
        assert_eq!(cloud_default(&[]), None);
    }

    #[test]
    fn models_dev_fills_gaps_by_vendor() {
        let dev = json!({"anthropic": {"models": {"claude-sonnet-5": {
            "name": "Claude Sonnet 5", "reasoning": true, "tool_call": true,
            "modalities": {"input": ["text", "image"]}, "limit": {"context": 200000, "output": 64000},
            "cost": {"input": 3.0, "output": 15.0}
        }}}});
        let mut m = Model {
            id: "anthropic/claude-sonnet-5".into(),
            name: "anthropic/claude-sonnet-5".into(),
            ..Default::default()
        };
        let id = m.id.clone();
        enrich(&mut m, lookup(&dev, "gpu", &id).unwrap());
        assert_eq!(m.context, Some(200_000));
        assert_eq!(m.name, "Claude Sonnet 5");
        assert!(m.vision());
    }

    #[test]
    fn frog_cloud_entries_say_who_serves_them() {
        let entry = json!({
            "id": "glm-5.3-flash", "context_length": 1048576,
            "served_by": {"id": "workers-ai", "name": "Cloudflare Workers AI", "third_party": true}
        });
        let s = ServedBy::parse(&entry["served_by"]).unwrap();
        assert_eq!(s.id, "workers-ai");
        assert_eq!(s.name, "Cloudflare Workers AI");
        assert!(s.third_party);
        let frog = ServedBy::parse(&json!({"id": "frog"})).unwrap();
        assert_eq!((frog.name.as_str(), frog.third_party), ("Frog Cloud", false));
        assert!(ServedBy::parse(&json!(null)).is_none());
    }

    #[test]
    fn the_upstream_header_wins_and_only_frog_cloud_has_one() {
        let cloud = providers::CLOUD;
        // No header: frog cloud's (cached) list says.
        let listed = format!("{cloud}/resolve-test");
        TEST_CACHE
            .lock()
            .unwrap()
            .get_or_insert_with(Default::default)
            .insert(
                listed.clone(),
                Model {
                    spec: listed.clone(),
                    served_by: Some(ServedBy::from_id("workers-ai")),
                    ..Default::default()
                },
            );
        let s = ServedBy::resolve(&listed, None).unwrap();
        assert!(s.third_party);
        // The header overrides it.
        let s = ServedBy::resolve(&listed, Some("frog")).unwrap();
        assert_eq!((s.id.as_str(), s.name.as_str(), s.third_party), ("frog", "Frog Cloud", false));
        // Unknown to the list and no header: unknown.
        assert!(ServedBy::resolve(&format!("{cloud}/no-such-model"), None).is_none());
        // The user's own providers never get one, even if a server sent the header.
        assert!(ServedBy::resolve("openrouter/x", Some("workers-ai")).is_none());
        assert!(ServedBy::resolve("ollama/qwen3", None).is_none());
        if let Some(c) = TEST_CACHE.lock().unwrap().as_mut() {
            c.remove(&listed);
        }
    }
}
