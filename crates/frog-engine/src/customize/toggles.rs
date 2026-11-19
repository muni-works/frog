//! What the person switched off in Customize: skills, whole connections, single tools. Frog's
//! own choice, kept in `~/.config/frog/customize.json` beside `imports.json`, never written
//! into a Claude Code file or a project's `.mcp.json` (those are read in place). Everything is
//! on unless listed here.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::SystemTime;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Toggles {
    /// Skill ids: the `SKILL.md` path, or `frog-builtin:<name>`.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub skills_off: BTreeSet<String>,
    /// Connection (MCP server) names.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub servers_off: BTreeSet<String>,
    /// Tools by exposed name, `mcp__<server>__<tool>`.
    #[serde(default, skip_serializing_if = "BTreeSet::is_empty")]
    pub tools_off: BTreeSet<String>,
}

impl Toggles {
    pub fn path() -> PathBuf {
        if cfg!(test) {
            // Tests never read or write your real choices; this file is never written.
            return std::env::temp_dir()
                .join(format!("frog-customize-test-{}.json", std::process::id()));
        }
        crate::config::config_dir().join("customize.json")
    }

    pub fn load() -> Self {
        Self::load_from(&Self::path())
    }

    pub fn load_from(file: &Path) -> Self {
        std::fs::read(file)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    pub fn save_to(&self, file: &Path) -> Result<()> {
        if let Some(dir) = file.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = file.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec_pretty(self)?)?;
        std::fs::rename(&tmp, file)?;
        Ok(())
    }

    /// Change the saved choices: read, change, write.
    pub fn update(f: impl FnOnce(&mut Self)) -> Result<()> {
        Self::update_in(&Self::path(), f)
    }

    pub fn update_in(file: &Path, f: impl FnOnce(&mut Self)) -> Result<()> {
        let mut t = Self::load_from(file);
        f(&mut t);
        t.save_to(file)
    }

    pub fn skill_on(&self, id: &str) -> bool {
        !self.skills_off.contains(id)
    }

    pub fn server_on(&self, name: &str) -> bool {
        !self.servers_off.contains(name)
    }

    pub fn tool_on(&self, exposed: &str) -> bool {
        !self.tools_off.contains(exposed)
    }

    pub fn set(set: &mut BTreeSet<String>, key: &str, on: bool) {
        if on {
            set.remove(key);
        } else {
            set.insert(key.to_string());
        }
    }
}

/// The saved choices, for `mcp::Hub::catalog`, which runs on every tool call: re-read only
/// when the file changes, so a switch made in Customize (or another session) applies at the
/// next call without a restart.
pub fn current() -> Arc<Toggles> {
    static CACHE: Mutex<Option<(Option<SystemTime>, Arc<Toggles>)>> = Mutex::new(None);
    let file = Toggles::path();
    let stamp = std::fs::metadata(&file).and_then(|m| m.modified()).ok();
    let mut cache = CACHE.lock().unwrap();
    if let Some((s, t)) = cache.as_ref()
        && *s == stamp
    {
        return t.clone();
    }
    let t = Arc::new(Toggles::load_from(&file));
    *cache = Some((stamp, t.clone()));
    t
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn everything_is_on_until_switched_off_and_back() {
        let dir = std::env::temp_dir().join(format!("frog-toggles-{}", crate::session::new_id()));
        let file = dir.join("customize.json");
        assert!(Toggles::load_from(&file).skill_on("x"));
        Toggles::update_in(&file, |t| {
            Toggles::set(&mut t.skills_off, "x", false);
            Toggles::set(&mut t.tools_off, "mcp__a__b", false);
        })
        .unwrap();
        let t = Toggles::load_from(&file);
        assert!(!t.skill_on("x") && !t.tool_on("mcp__a__b") && t.server_on("a"));
        Toggles::update_in(&file, |t| Toggles::set(&mut t.skills_off, "x", true)).unwrap();
        assert!(Toggles::load_from(&file).skill_on("x"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
