use crate::config::data_dir;
use crate::message::Message;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Serialize, Deserialize)]
pub struct Session {
    pub id: String,
    pub cwd: PathBuf,
    pub model: String,
    pub messages: Vec<Message>,
}

fn dir() -> PathBuf {
    data_dir().join("sessions")
}

impl Session {
    pub fn new_id() -> String {
        chrono::Local::now().format("%Y%m%d-%H%M%S").to_string()
    }

    pub fn save(&self) -> Result<()> {
        if self.messages.is_empty() {
            return Ok(());
        }
        std::fs::create_dir_all(dir())?;
        std::fs::write(
            dir().join(format!("{}.json", self.id)),
            serde_json::to_vec(self)?,
        )?;
        Ok(())
    }

    pub fn load(id: &str) -> Result<Self> {
        let path = dir().join(format!("{id}.json"));
        let bytes = std::fs::read(&path).with_context(|| format!("no session {id}"))?;
        Ok(serde_json::from_slice(&bytes)?)
    }

    /// Most recently modified session started in `cwd`.
    pub fn latest_for(cwd: &Path) -> Result<Self> {
        let mut entries: Vec<_> = std::fs::read_dir(dir())
            .context("no sessions yet")?
            .filter_map(|e| e.ok())
            .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
            .collect();
        entries.sort_by_key(|e| std::cmp::Reverse(e.0));
        for (_, path) in entries {
            if let Ok(s) = serde_json::from_slice::<Session>(&std::fs::read(&path)?)
                && s.cwd == cwd
            {
                return Ok(s);
            }
        }
        anyhow::bail!("no previous session in {}", cwd.display())
    }
}
