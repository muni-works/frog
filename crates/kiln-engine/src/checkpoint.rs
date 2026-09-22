//! Whole-working-tree checkpoints for git repos, so rewind also undoes what shell commands did.
//!
//! A checkpoint is a commit of the working tree (tracked and untracked files, minus ignored
//! ones) built through a private index, then pinned under `refs/kiln/` so git doesn't garbage-
//! collect it. The user's index, stash, branches and HEAD are never touched.

use anyhow::{Context, Result, bail};
use std::path::{Path, PathBuf};
use std::process::Command;

fn git(root: &Path, index: Option<&Path>, args: &[&str]) -> Result<String> {
    let mut cmd = Command::new("git");
    cmd.arg("-C").arg(root).args(args);
    if let Some(i) = index {
        cmd.env("GIT_INDEX_FILE", i);
    }
    let out = cmd.output().context("running git")?;
    if !out.status.success() {
        bail!(
            "git {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// The repository root containing `cwd`, if it's in a git work tree.
pub fn repo_root(cwd: &Path) -> Option<PathBuf> {
    git(cwd, None, &["rev-parse", "--show-toplevel"])
        .ok()
        .map(PathBuf::from)
}

/// A private index seeded from the real one, so `git add -A` only re-hashes changed files.
struct TempIndex(PathBuf);

impl TempIndex {
    fn new(root: &Path) -> Result<Self> {
        let path = std::env::temp_dir().join(format!(
            "kiln-index-{}-{}",
            std::process::id(),
            crate::session::new_id()
        ));
        let real = git(root, None, &["rev-parse", "--git-path", "index"])?;
        let real = if Path::new(&real).is_absolute() {
            PathBuf::from(real)
        } else {
            root.join(real)
        };
        if real.exists() {
            std::fs::copy(&real, &path)?;
        }
        Ok(Self(path))
    }
}

impl Drop for TempIndex {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn tree(root: &Path) -> Result<String> {
    let index = TempIndex::new(root)?;
    git(root, Some(&index.0), &["add", "-A"])?;
    git(root, Some(&index.0), &["write-tree"])
}

/// Snapshot the working tree and pin it as `refs/kiln/<name>`. Returns the commit.
pub fn snapshot(root: &Path, name: &str) -> Result<String> {
    let tree = tree(root)?;
    let commit = git(
        root,
        None,
        &[
            "commit-tree",
            &tree,
            "-m",
            &format!("kiln checkpoint {name}"),
        ],
    )?;
    git(
        root,
        None,
        &["update-ref", &format!("refs/kiln/{name}"), &commit],
    )?;
    Ok(commit)
}

/// Put the working tree back to `commit`: files changed since are restored, files created since
/// are deleted, ignored files are left alone. Returns the paths touched (relative to `root`).
pub fn restore(root: &Path, commit: &str) -> Result<Vec<PathBuf>> {
    let now = tree(root)?;
    let diff = git(
        root,
        None,
        &["diff", "--name-status", "--no-renames", "-z", commit, &now],
    )?;
    let mut fields = diff.split('\0').filter(|s| !s.is_empty());
    let (mut created, mut changed) = (Vec::new(), Vec::new());
    while let (Some(status), Some(path)) = (fields.next(), fields.next()) {
        if status.starts_with('A') {
            created.push(path.to_string());
        } else {
            changed.push(path.to_string());
        }
    }
    for p in &created {
        let _ = std::fs::remove_file(root.join(p));
    }
    if !changed.is_empty() {
        let index = TempIndex::new(root)?;
        git(root, Some(&index.0), &["read-tree", commit])?;
        let mut args = vec!["checkout-index", "-f", "--"];
        args.extend(changed.iter().map(String::as_str));
        git(root, Some(&index.0), &args)?;
    }
    Ok(created
        .into_iter()
        .chain(changed)
        .map(PathBuf::from)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo() -> PathBuf {
        let d = std::env::temp_dir().join(format!("kiln-git-{}", crate::session::new_id()));
        std::fs::create_dir_all(&d).unwrap();
        let run = |args: &[&str]| {
            assert!(
                Command::new("git")
                    .arg("-C")
                    .arg(&d)
                    .args(args)
                    .status()
                    .unwrap()
                    .success()
            )
        };
        run(&["init", "-q"]);
        std::fs::write(d.join("a.txt"), "one\n").unwrap();
        std::fs::write(d.join(".gitignore"), "ignored.log\n").unwrap();
        run(&["add", "-A"]);
        run(&[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "-qm",
            "init",
        ]);
        d
    }

    #[test]
    fn restore_undoes_edits_creations_and_deletions_but_not_ignored_files() {
        let root = repo();
        std::fs::write(root.join("a.txt"), "one (uncommitted)\n").unwrap();
        let cp = snapshot(&root, "test-1").unwrap();

        // What a shell command might do afterwards.
        std::fs::write(root.join("a.txt"), "mangled\n").unwrap();
        std::fs::write(root.join("new.txt"), "junk\n").unwrap();
        std::fs::write(root.join("ignored.log"), "keep me\n").unwrap();
        let staged_before = git(&root, None, &["diff", "--cached", "--name-only"]).unwrap();

        let touched = restore(&root, &cp).unwrap();
        assert_eq!(
            std::fs::read_to_string(root.join("a.txt")).unwrap(),
            "one (uncommitted)\n"
        );
        assert!(!root.join("new.txt").exists());
        assert!(
            root.join("ignored.log").exists(),
            "ignored files are left alone"
        );
        assert_eq!(touched.len(), 2);
        // The user's index and HEAD are untouched.
        assert_eq!(
            git(&root, None, &["diff", "--cached", "--name-only"]).unwrap(),
            staged_before
        );
        assert!(git(&root, None, &["show-ref", "refs/kiln/test-1"]).is_ok());
    }
}
