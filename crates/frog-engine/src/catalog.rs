//! What each connected provider offers, with what's worth knowing to pick one: context size,
//! inputs, reasoning, tool use and price. Gateways describe their own models (OpenRouter and
//! Vercel's model lists are rich); for the rest, models.dev (the open catalog OpenCode uses)
//! fills in. Lists are cached per provider for a few hours.

use crate::config::{ProviderKind, data_dir};
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

/// What's known about one model, from the cache alone (no network): for `resolve`.
pub fn cached(spec: &str) -> Option<Model> {
    let (provider, _) = spec.split_once('/')?;
    let found = read_cache(provider).and_then(|c| c.models.into_iter().find(|m| m.spec == spec));
    found.or_else(|| {
        (provider == providers::CLOUD)
            .then(|| {
                STATIC_CLOUD
                    .iter()
                    .map(static_model)
                    .find(|m| m.spec == spec)
            })
            .flatten()
    })
}

/// frog cloud's models, built in: what the picker shows before you connect, so nothing calls
/// frog cloud while you're logged out. (id, name, context)
const STATIC_CLOUD: &[(&str, &str, u64)] = &[("qwen3-coder-next", "Qwen3 Coder Next", 65_536)];

fn static_model(&(id, name, context): &(&str, &str, u64)) -> Model {
    Model {
        spec: format!("{}/{id}", providers::CLOUD),
        provider: providers::CLOUD.into(),
        id: id.into(),
        name: name.into(),
        context: Some(context),
        inputs: vec!["text".into()],
        tools: true,
        ..Default::default()
    }
}

/// frog cloud's models, without the network: the last fetched list, else the built-in one.
pub fn cloud_models() -> Vec<Model> {
    read_cache(providers::CLOUD)
        .map(|c| c.models)
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| STATIC_CLOUD.iter().map(static_model).collect())
}

/// Gateways whose model lists are public: browsable before you connect them, and fetched
/// without a key (a wrong key would get the request refused).
fn public(provider: &str) -> bool {
    matches!(provider, "openrouter" | "vercel")
}

/// The models of every connected remote provider (and the public gateways): cached, or
/// fetched when stale (or when `refresh`). A provider that can't be reached keeps its last list.
pub async fn all(refresh: bool) -> Vec<Model> {
    let state = providers::State::load();
    let all = providers::list(&state);
    // Logged out, frog cloud is its built-in list: never fetched without a key.
    let cloud_static = all
        .iter()
        .any(|p| p.id == providers::CLOUD && !p.connected)
        .then(|| STATIC_CLOUD.iter().map(static_model).collect::<Vec<_>>())
        .unwrap_or_default();
    let remote: Vec<ProviderInfo> = all
        .into_iter()
        .filter(|p| !p.local && (p.connected || public(&p.id)))
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
                _ => cached
                    .map(|c| c.models)
                    .filter(|m| !m.is_empty())
                    .unwrap_or_else(|| {
                        if p.id == providers::CLOUD {
                            STATIC_CLOUD.iter().map(static_model).collect()
                        } else {
                            Vec::new()
                        }
                    }),
            }
        }
    });
    let mut out: Vec<Model> = futures_util::future::join_all(jobs)
        .await
        .into_iter()
        .flatten()
        .collect();
    out.extend(cloud_static);
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
    // frog cloud's own models: the built-in list knows them.
    if p.id == providers::CLOUD {
        for m in models.iter_mut() {
            if let Some(s) = STATIC_CLOUD.iter().map(static_model).find(|s| s.id == m.id) {
                m.context = m.context.or(s.context);
                m.tools = true;
                if m.name == m.id {
                    m.name = s.name;
                }
            }
        }
    }
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
        assert!(vercel("vercel", &json!({"id": "e", "type": "embedding"})).is_none());
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
    fn cloud_has_a_built_in_list() {
        let m = cached("cloud/qwen3-coder-next").unwrap();
        assert_eq!(m.context, Some(65_536));
        assert!(cloud_models().iter().any(|m| m.id == "qwen3-coder-next"));
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
}
