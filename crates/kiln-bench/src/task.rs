//! Bench tasks: a directory with `task.toml` and a `repo/` that seeds each run's workspace.

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
struct Spec {
    prompt: String,
    /// Shell command run in the workspace afterwards; exit 0 means the task passed.
    check: String,
    #[serde(default = "default_timeout")]
    timeout_secs: u64,
}

fn default_timeout() -> u64 {
    300
}

#[derive(Debug, Clone)]
pub struct Task {
    pub name: String,
    pub prompt: String,
    pub check: String,
    pub timeout_secs: u64,
    pub repo: PathBuf,
}

pub fn load_all(dir: &Path, filter: Option<&str>) -> Result<Vec<Task>> {
    let mut tasks = Vec::new();
    for entry in
        std::fs::read_dir(dir).with_context(|| format!("reading tasks from {}", dir.display()))?
    {
        let path = entry?.path();
        let spec_path = path.join("task.toml");
        if !spec_path.is_file() {
            continue;
        }
        let name = path
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();
        if filter.is_some_and(|f| !name.contains(f)) {
            continue;
        }
        let spec: Spec = toml::from_str(&std::fs::read_to_string(&spec_path)?)
            .with_context(|| format!("parsing {}", spec_path.display()))?;
        tasks.push(Task {
            name,
            prompt: spec.prompt,
            check: spec.check,
            timeout_secs: spec.timeout_secs,
            repo: path.join("repo"),
        });
    }
    tasks.sort_by(|a, b| a.name.cmp(&b.name));
    if tasks.is_empty() {
        bail!("no tasks found in {}", dir.display());
    }
    Ok(tasks)
}

/// Copy the task's repo into a fresh workspace.
pub fn seed(task: &Task, workspace: &Path) -> Result<()> {
    std::fs::create_dir_all(workspace)?;
    if task.repo.is_dir() {
        copy_dir(&task.repo, workspace)?;
    }
    Ok(())
}

fn copy_dir(from: &Path, to: &Path) -> Result<()> {
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let dest = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            std::fs::create_dir_all(&dest)?;
            copy_dir(&entry.path(), &dest)?;
        } else {
            std::fs::copy(entry.path(), dest)?;
        }
    }
    Ok(())
}
