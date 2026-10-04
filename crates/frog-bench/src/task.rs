//! Bench tasks: a directory with `task.toml` and a `repo/` that seeds each run's workspace.

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Spec {
    prompt: String,
    /// Shell command run in the workspace afterwards; exit 0 means the task passed.
    check: String,
    #[serde(default = "default_timeout")]
    timeout_secs: u64,
    /// More prompts after the first, each its own turn (`[[then]]` tables).
    #[serde(default)]
    then: Vec<Turn>,
}

fn default_timeout() -> u64 {
    300
}

/// Which conversation a turn goes to.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Conversation {
    /// The one the previous turn ran in.
    #[default]
    Same,
    /// The same one, reopened from its session log by a new engine (quit and `--resume`).
    Resume,
    /// A new conversation in the same workspace.
    New,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Turn {
    pub prompt: String,
    #[serde(default)]
    pub conversation: Conversation,
}

#[derive(Debug, Clone)]
pub struct Task {
    pub name: String,
    pub prompt: String,
    pub check: String,
    pub timeout_secs: u64,
    pub repo: PathBuf,
    /// Every turn in order, the first being `prompt`.
    pub turns: Vec<Turn>,
}

fn parse(name: String, text: &str, repo: PathBuf) -> Result<Task> {
    let spec: Spec = toml::from_str(text)?;
    let mut turns = vec![Turn {
        prompt: spec.prompt.clone(),
        conversation: Conversation::Same,
    }];
    turns.extend(spec.then);
    Ok(Task {
        name,
        prompt: spec.prompt,
        check: spec.check,
        timeout_secs: spec.timeout_secs,
        repo,
        turns,
    })
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
        let text = std::fs::read_to_string(&spec_path)?;
        tasks.push(
            parse(name, &text, path.join("repo"))
                .with_context(|| format!("parsing {}", spec_path.display()))?,
        );
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn follow_up_turns_say_which_conversation_they_go_to() {
        let t = parse(
            "t".into(),
            r#"
prompt = "one"
check = "true"
[[then]]
prompt = "two"
[[then]]
prompt = "three"
conversation = "resume"
[[then]]
prompt = "four"
conversation = "new"
"#,
            PathBuf::new(),
        )
        .unwrap();
        let turns: Vec<_> = t
            .turns
            .iter()
            .map(|t| (t.prompt.as_str(), t.conversation))
            .collect();
        use Conversation::*;
        assert_eq!(
            turns,
            [
                ("one", Same),
                ("two", Same),
                ("three", Resume),
                ("four", New)
            ]
        );
        let single = parse(
            "s".into(),
            "prompt = \"p\"\ncheck = \"true\"",
            PathBuf::new(),
        );
        assert_eq!(single.unwrap().turns.len(), 1);
        // A misspelled key is an error, not a silently single-turn task.
        let typo = "prompt = \"p\"\ncheck = \"c\"\n[[than]]\nprompt = \"q\"";
        assert!(parse("x".into(), typo, PathBuf::new()).is_err());
    }
}
