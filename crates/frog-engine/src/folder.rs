//! `UseFolder`: move the conversation into a folder on the user's computer. A plain chat has no
//! files or shell; this is how it gets them, and how a project conversation moves to another
//! project. The engine re-roots in place (see `Agent::use_folder`), so the turn carries on with
//! the folder's tools, and the session's header moves with it.

use std::path::{Path, PathBuf};

use anyhow::{Result, bail};

use crate::provider::ToolSpec;

pub const TOOL: &str = "UseFolder";

pub fn spec() -> ToolSpec {
    ToolSpec {
        name: TOOL.into(),
        description: "Move this conversation into a folder on the user's computer, so you can read and edit files and run shell commands there. Use it when the user wants something that needs their files or a command run and this conversation has no folder, or to switch to a different project. The user approves the move. If you don't know which folder, ask first.".into(),
        schema: serde_json::json!({
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "The folder: an absolute path, or one starting with ~"}
            },
            "required": ["path"]
        }),
    }
}

/// The folder `raw` names: `~` expanded, relative paths taken from `base`, symlinks resolved.
pub fn resolve(raw: &str, base: &Path) -> Result<PathBuf> {
    let raw = raw.trim();
    if raw.is_empty() {
        bail!("`path` is empty: say which folder");
    }
    let home = dirs::home_dir().unwrap_or_default();
    let path = if raw == "~" {
        home
    } else if let Some(rest) = raw.strip_prefix("~/") {
        home.join(rest)
    } else {
        base.join(raw)
    };
    let path = path
        .canonicalize()
        .map_err(|_| anyhow::anyhow!("no folder at {}", path.display()))?;
    if !path.is_dir() {
        bail!("{} is a file, not a folder", path.display());
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_home_relative_and_absolute() {
        let home = dirs::home_dir().unwrap().canonicalize().unwrap();
        assert_eq!(resolve("~", Path::new("/")).unwrap(), home);
        let tmp = std::env::temp_dir().canonicalize().unwrap();
        assert_eq!(resolve(tmp.to_str().unwrap(), Path::new("/")).unwrap(), tmp);
        let parent = tmp.parent().unwrap();
        let name = tmp.file_name().unwrap().to_str().unwrap();
        assert_eq!(resolve(name, parent).unwrap(), tmp);
    }

    #[test]
    fn refuses_missing_and_files() {
        assert!(resolve("", Path::new("/")).is_err());
        assert!(resolve("/definitely/not/here", Path::new("/")).is_err());
        let file = std::env::temp_dir().join(format!("frog-folder-test-{}", std::process::id()));
        std::fs::write(&file, "x").unwrap();
        assert!(resolve(file.to_str().unwrap(), Path::new("/")).is_err());
        std::fs::remove_file(file).unwrap();
    }
}
