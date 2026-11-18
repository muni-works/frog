//! Models Frog offers to run on your own machines, and Frog Cloud's models with why they do or
//! don't run locally: `catalog/local-models.json`, the one file the engine, the Mac app (bundled)
//! and the web read. Where each comes from, how big it is, what it needs to load and what it's
//! for, so a machine's page can answer those without asking the network.

use serde::Deserialize;
use std::sync::OnceLock;

const JSON: &str = include_str!("../../../catalog/local-models.json");

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Source {
    /// "Hugging Face".
    pub host: String,
    /// `org/name` on that host.
    pub repo: String,
    /// One file in the repo, when the model is a single file (a GGUF).
    #[serde(default)]
    pub file: Option<String>,
}

impl Source {
    pub fn url(&self) -> String {
        format!("https://huggingface.co/{}", self.repo)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct LocalModel {
    pub id: String,
    /// The name the model menu shows; Frog Cloud's models carry Frog Cloud's names.
    pub name: String,
    /// Frog Cloud's id for it, when Frog Cloud serves it.
    #[serde(default)]
    pub cloud: Option<String>,
    pub source: Source,
    /// "mlx-4bit", "gguf UD-Q4_K_XL".
    pub format: String,
    pub download_bytes: u64,
    pub memory_bytes: u64,
    #[serde(default)]
    pub context: Option<u64>,
    pub capabilities: Vec<String>,
    /// Hardware kinds tang runs it on (a node's `hardware.kind`: "metal", "cuda").
    pub runs_on: Vec<String>,
    /// A paired machine (or This Mac) can download and load it.
    pub local: bool,
    #[serde(default)]
    pub local_note: Option<String>,
    /// Rank among Frog's picks for coding, 1 best.
    #[serde(default)]
    pub recommend: Option<u32>,
    #[serde(default)]
    pub menu: bool,
}

#[derive(Deserialize)]
struct File {
    schema: u32,
    models: Vec<LocalModel>,
}

/// Every model in the catalog, in the file's order.
pub fn all() -> &'static [LocalModel] {
    static ALL: OnceLock<Vec<LocalModel>> = OnceLock::new();
    ALL.get_or_init(|| {
        let f: File = serde_json::from_str(JSON).expect("catalog/local-models.json parses");
        assert_eq!(f.schema, 1, "catalog/local-models.json schema");
        f.models
    })
}

/// The catalog's entry for a repo (`mlx-community/Qwen3-8B-4bit`), as a node lists it.
pub fn by_repo(repo: &str) -> Option<&'static LocalModel> {
    all()
        .iter()
        .find(|m| m.source.repo.eq_ignore_ascii_case(repo))
}

const GIB: u64 = 1 << 30;

/// Memory a machine can give one model: all of a discrete GPU's (tang never takes memory
/// other processes hold, so this is the ceiling), and on unified memory what's left after
/// 16 GiB for macOS and your apps, at least half.
pub fn usable_bytes(total: u64, unified: bool) -> u64 {
    if !unified {
        return total;
    }
    (total / 2).max(total.saturating_sub(16 * GIB))
}

/// Whether tang can run the model on this machine at all.
pub fn fits(m: &LocalModel, kind: &str, total: u64, unified: bool) -> bool {
    m.local && m.runs_on.iter().any(|k| k == kind) && m.memory_bytes <= usable_bytes(total, unified)
}

/// Frog's picks for a machine, best first: Frog Cloud's models it can run, then the best
/// coding model that fits and at most two smaller fallbacks.
pub fn recommended(kind: &str, total: u64, unified: bool) -> Vec<&'static LocalModel> {
    let mut cloud: Vec<_> = all()
        .iter()
        .filter(|m| m.cloud.is_some() && fits(m, kind, total, unified))
        .collect();
    let mut picks: Vec<_> = all()
        .iter()
        .filter(|m| m.cloud.is_none() && m.recommend.is_some() && fits(m, kind, total, unified))
        .collect();
    picks.sort_by_key(|m| m.recommend);
    cloud.extend(picks.into_iter().take(3));
    cloud
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers;

    #[test]
    fn every_offered_model_says_where_it_comes_from_how_big_it_is_and_what_it_does() {
        assert!(!all().is_empty());
        for m in all() {
            assert!(!m.name.is_empty() && !m.id.is_empty(), "{m:?}");
            assert_eq!(m.source.host, "Hugging Face", "{}", m.id);
            assert!(
                m.source.repo.split('/').count() == 2,
                "{}: repo is org/name",
                m.id
            );
            assert!(
                m.download_bytes > 0 && m.memory_bytes > 0,
                "{}: sizes",
                m.id
            );
            assert!(!m.capabilities.is_empty(), "{}: capabilities", m.id);
            assert!(!m.format.is_empty(), "{}: format", m.id);
            if m.local {
                assert!(!m.runs_on.is_empty(), "{}: runs somewhere", m.id);
                assert!(m.context.is_some(), "{}: context length", m.id);
                // A local model needs at least its weights in memory.
                assert!(
                    m.memory_bytes >= m.download_bytes,
                    "{}: memory under weights",
                    m.id
                );
            } else {
                assert!(
                    m.local_note.is_some(),
                    "{}: says why it doesn't run locally",
                    m.id
                );
            }
        }
        let ids: std::collections::HashSet<_> = all().iter().map(|m| &m.id).collect();
        assert_eq!(ids.len(), all().len(), "ids are unique");
    }

    #[test]
    fn frog_clouds_models_carry_frog_clouds_ids_and_names() {
        let served: Vec<&str> = providers::CLOUD_ALIASES.iter().map(|(_, id)| *id).collect();
        let cloud: Vec<_> = all().iter().filter(|m| m.cloud.is_some()).collect();
        assert_eq!(
            cloud.len(),
            served.len(),
            "every Frog Cloud model is in the catalog"
        );
        for m in cloud {
            let id = m.cloud.as_deref().unwrap();
            assert!(served.contains(&id), "{id} is a Frog Cloud id");
            assert_eq!(m.id, id, "same id locally and in the cloud");
        }
        let name = |id: &str| by_id(id).name.as_str();
        assert_eq!(name("qwen3-coder-next"), "Qwen3 Coder Next");
        assert_eq!(name("glm-5.3-flash"), "GLM-5.3 Flash");
        assert_eq!(name("deepseek-v4.1-flash"), "DeepSeek V4.1 Flash");
    }

    #[test]
    fn bundled_local_models_are_in_the_catalog() {
        for (short, repo) in providers::LOCAL_MODELS {
            let m = by_repo(repo).unwrap_or_else(|| panic!("{repo} in the catalog"));
            assert_eq!(&m.id, short);
        }
    }

    fn by_id(id: &str) -> &'static LocalModel {
        all().iter().find(|m| m.id == id).unwrap()
    }

    fn names(v: Vec<&LocalModel>) -> Vec<&str> {
        v.into_iter().map(|m| m.name.as_str()).collect()
    }

    #[test]
    fn the_default_list_per_machine() {
        // mew: an RTX 3090 node, 24 GiB of VRAM (as its /node reports it).
        assert_eq!(
            names(recommended("cuda", 25_295_257_600, false)),
            ["Qwen3 32B", "Qwen3 14B", "Qwen3 8B"]
        );
        // A 16 GB Mac: 8 GiB for a model.
        assert_eq!(
            names(recommended("metal", 16 * GIB, true)),
            ["Qwen3 8B", "Qwen3 4B", "Qwen3 1.7B"]
        );
        // A 64 GB Mac: 48 GiB.
        assert_eq!(
            names(recommended("metal", 64 * GIB, true)),
            ["Qwen3 32B", "Qwen3 14B", "Qwen3 8B"]
        );
        // An 8 GB Mac: only the small ones.
        assert_eq!(names(recommended("metal", 8 * GIB, true)), ["Qwen3 1.7B"]);
    }

    #[test]
    fn no_cloud_model_runs_on_these_machines_today() {
        for (kind, total, unified) in [
            ("cuda", 24 * GIB, false),
            ("metal", 16 * GIB, true),
            ("metal", 64 * GIB, true),
            ("metal", 128 * GIB, true),
            ("cuda", 96 * GIB, false),
        ] {
            assert!(
                all()
                    .iter()
                    .filter(|m| m.cloud.is_some())
                    .all(|m| !fits(m, kind, total, unified)),
                "{kind} {total}"
            );
        }
    }
}
