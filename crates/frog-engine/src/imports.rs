//! What frog picks up from other tools on this Mac, and the report the app's first-run line
//! shows (docs/onboarding.md). Instruction files, skills, rules, a project's `.mcp.json` and
//! provider keys in the environment are used as they are; Claude Code's own MCP servers (in
//! `~/.claude.json`) are read only once you say so, recorded in `~/.config/frog/imports.json`.
//! frog reads them where they are rather than copying them, so edits in Claude Code carry over.

use crate::config::{Config, config_dir};
use crate::mcp::ServerConfig;
use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

#[derive(Default, Serialize, Deserialize)]
struct Choices {
    /// Read Claude Code's MCP servers.
    #[serde(default)]
    claude_mcp: bool,
}

fn choices_path() -> PathBuf {
    config_dir().join("imports.json")
}

fn load(file: &Path) -> Choices {
    std::fs::read(file)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

pub fn claude_mcp_on() -> bool {
    load(&choices_path()).claude_mcp
}

pub fn set_claude_mcp(on: bool) -> Result<()> {
    let file = choices_path();
    let mut c = load(&file);
    c.claude_mcp = on;
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::write(&file, serde_json::to_vec_pretty(&c)?)?;
    Ok(())
}

#[derive(Default, Deserialize)]
struct ClaudeJson {
    #[serde(rename = "mcpServers", default)]
    servers: BTreeMap<String, ServerConfig>,
    #[serde(default)]
    projects: BTreeMap<String, ClaudeProject>,
}

#[derive(Default, Deserialize)]
struct ClaudeProject {
    #[serde(rename = "mcpServers", default)]
    servers: BTreeMap<String, ServerConfig>,
}

fn claude_json() -> PathBuf {
    dirs::home_dir().unwrap_or_default().join(".claude.json")
}

/// Claude Code's MCP servers for a folder: its user-wide ones, then the ones it keeps for
/// this project (or the nearest folder above it that has some).
fn claude_servers_in(file: &Path, cwd: &Path) -> BTreeMap<String, ServerConfig> {
    let Some(j) = std::fs::read(file)
        .ok()
        .and_then(|b| serde_json::from_slice::<ClaudeJson>(&b).ok())
    else {
        return BTreeMap::new();
    };
    let mut all = j.servers;
    let cwd = cwd.canonicalize().unwrap_or_else(|_| cwd.to_path_buf());
    if let Some(p) = cwd
        .ancestors()
        .find_map(|a| j.projects.get(a.to_string_lossy().as_ref()))
    {
        for (name, s) in &p.servers {
            all.entry(name.clone()).or_insert_with(|| s.clone());
        }
    }
    all
}

pub fn claude_servers(cwd: &Path) -> BTreeMap<String, ServerConfig> {
    claude_servers_in(&claude_json(), cwd)
}

/// What frog found for a folder, for the first-run line.
#[derive(Debug, Default, Serialize)]
pub struct Setup {
    /// Instruction files in use (CLAUDE.md, AGENTS.md, FROG.md), by path.
    pub instructions: Vec<String>,
    pub skills: usize,
    pub rules: usize,
    /// Providers whose key comes from the environment, by name.
    pub env_keys: Vec<String>,
    /// Claude Code's MCP servers for this folder, by name, and whether frog reads them.
    pub claude_mcp: Vec<String>,
    pub claude_mcp_on: bool,
}

pub fn report(cfg: &Config, cwd: &Path) -> Setup {
    let state = crate::providers::State::load();
    Setup {
        instructions: crate::prompt::instruction_files(cwd, cfg)
            .into_iter()
            .map(|p| p.display().to_string())
            .collect(),
        skills: crate::skills::discover(cwd).len(),
        rules: crate::rules::discover(cwd).len(),
        env_keys: crate::providers::list(&state)
            .into_iter()
            .filter(|p| p.key == Some("env"))
            .map(|p| p.name)
            .collect(),
        claude_mcp: claude_servers(cwd).into_keys().collect(),
        claude_mcp_on: claude_mcp_on(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_servers_are_user_wide_then_the_projects() {
        let dir = std::env::temp_dir().join(format!("frog-imports-{}", std::process::id()));
        let project = dir.join("app");
        std::fs::create_dir_all(project.join("apps")).unwrap();
        let project = project.canonicalize().unwrap();
        let file = dir.join("claude.json");
        std::fs::write(
            &file,
            serde_json::json!({
                "mcpServers": { "fusion": { "type": "http", "url": "http://localhost:1/mcp" } },
                "projects": { project.to_string_lossy(): { "mcpServers": { "vcad": { "command": "vcad-mcp", "args": ["serve"] } } } },
                "theme": "dark"
            })
            .to_string(),
        )
        .unwrap();
        let here = claude_servers_in(&file, &project.join("apps"));
        assert_eq!(here.keys().collect::<Vec<_>>(), ["fusion", "vcad"]);
        assert_eq!(here["vcad"].args, ["serve"]);
        assert_eq!(
            claude_servers_in(&file, &dir).keys().collect::<Vec<_>>(),
            ["fusion"]
        );
        assert!(claude_servers_in(&dir.join("missing.json"), &dir).is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }
}
