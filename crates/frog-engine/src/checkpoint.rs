//! Whole-working-tree checkpoints for git repos, so rewind also undoes what shell commands did.
//!
//! A checkpoint is a commit of the working tree (tracked and untracked files, minus ignored
//! ones) built through a private index, then pinned under `refs/frog/` so git doesn't garbage-
//! collect it. The user's index, stash, branches and HEAD are never touched.

use anyhow::{Context, Result, bail};
use std::path::{Path, PathBuf};
use std::process::Command;

/// Overrides for every git frog runs here, outside the sandbox: a repo's own config or hooks
/// (which a sandboxed command or a cloned repo may have planted) never run a command.
const SAFE: &[&str] = &[
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
];

fn git(root: &Path, index: Option<&Path>, args: &[&str]) -> Result<String> {
    let mut cmd = Command::new("git");
    cmd.args(SAFE).arg("-C").arg(root).args(args);
    // Checkpoint commits need an identity even where none is configured (CI runners, fresh
    // containers); only fill in what the environment doesn't already provide.
    for (k, v) in [
        ("GIT_AUTHOR_NAME", "frog"),
        ("GIT_AUTHOR_EMAIL", "frog@localhost"),
        ("GIT_COMMITTER_NAME", "frog"),
        ("GIT_COMMITTER_EMAIL", "frog@localhost"),
    ] {
        if std::env::var_os(k).is_none() {
            cmd.env(k, v);
        }
    }
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
            "frog-index-{}-{}",
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

/// Snapshot the working tree and pin it as `refs/frog/<name>`. Returns the commit.
pub fn snapshot(root: &Path, name: &str) -> Result<String> {
    let tree = tree(root)?;
    let commit = git(
        root,
        None,
        &[
            "commit-tree",
            &tree,
            "-m",
            &format!("frog checkpoint {name}"),
        ],
    )?;
    git(
        root,
        None,
        &["update-ref", &format!("refs/frog/{name}"), &commit],
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

/// Parallel attempts: worktrees that all start from the same snapshot of the working tree.
#[derive(Debug, serde::Serialize)]
pub struct Attempts {
    /// The snapshot commit every attempt starts from.
    pub base: String,
    pub dirs: Vec<PathBuf>,
}

/// Snapshot the working tree (uncommitted changes included) and check it out into `n` detached
/// worktrees under `parent`.
pub fn create_attempts(root: &Path, name: &str, n: usize, parent: &Path) -> Result<Attempts> {
    let base = snapshot(root, &format!("attempts/{name}"))?;
    std::fs::create_dir_all(parent)?;
    let mut dirs = Vec::new();
    for i in 1..=n {
        let dir = parent.join(format!("{name}-{i}"));
        let d = dir.to_string_lossy().to_string();
        git(
            root,
            None,
            &["worktree", "add", "--detach", "--quiet", &d, &base],
        )?;
        dirs.push(dir);
    }
    Ok(Attempts { base, dirs })
}

/// What an attempt changed relative to `base`, as a binary-safe patch.
pub fn attempt_patch(worktree: &Path, base: &str) -> Result<String> {
    let now = tree(worktree)?;
    let mut patch = git(worktree, None, &["diff", "--binary", base, &now])?;
    if !patch.is_empty() {
        patch.push('\n');
    }
    Ok(patch)
}

/// Apply an attempt's changes to the main working tree. Refuses (changing nothing) if they
/// don't apply cleanly, e.g. because the same lines were edited in the meantime.
pub fn apply_attempt(root: &Path, worktree: &Path, base: &str) -> Result<Vec<String>> {
    use std::io::Write;
    let patch = attempt_patch(worktree, base)?;
    if patch.trim().is_empty() {
        return Ok(Vec::new());
    }
    let run = |args: &[&str]| -> Result<String> {
        let mut child = Command::new("git")
            .args(SAFE)
            .arg("-C")
            .arg(root)
            .args(args)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()?;
        child
            .stdin
            .take()
            .context("stdin")?
            .write_all(patch.as_bytes())?;
        let out = child.wait_with_output()?;
        if !out.status.success() {
            bail!("{}", String::from_utf8_lossy(&out.stderr).trim());
        }
        Ok(String::from_utf8_lossy(&out.stdout).to_string())
    };
    run(&["apply", "--check", "-"])
        .context("the attempt doesn't apply cleanly to the current files")?;
    let files = run(&["apply", "--numstat", "-"])?
        .lines()
        .filter_map(|l| l.split('\t').nth(2).map(String::from))
        .collect();
    run(&["apply", "-"])?;
    Ok(files)
}

/// Remove attempt worktrees.
pub fn remove_attempts(root: &Path, dirs: &[PathBuf]) {
    for d in dirs {
        let _ = git(
            root,
            None,
            &["worktree", "remove", "--force", &d.to_string_lossy()],
        );
    }
    let _ = git(root, None, &["worktree", "prune"]);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn repo() -> PathBuf {
        let d = std::env::temp_dir().join(format!("frog-git-{}", crate::session::new_id()));
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
        assert!(git(&root, None, &["show-ref", "refs/frog/test-1"]).is_ok());
    }

    #[test]
    fn attempts_start_from_the_dirty_tree_and_apply_back() {
        let root = repo();
        std::fs::write(root.join("a.txt"), "uncommitted work\n").unwrap();
        let parent =
            std::env::temp_dir().join(format!("frog-attempts-{}", crate::session::new_id()));
        let a = create_attempts(&root, "t", 2, &parent).unwrap();
        assert_eq!(a.dirs.len(), 2);
        // Each attempt sees the uncommitted state.
        assert_eq!(
            std::fs::read_to_string(a.dirs[0].join("a.txt")).unwrap(),
            "uncommitted work\n"
        );

        // Attempt 2 edits a file and adds one; applying it lands both in the main tree.
        std::fs::write(a.dirs[1].join("a.txt"), "attempt two\n").unwrap();
        std::fs::write(a.dirs[1].join("b.txt"), "new\n").unwrap();
        let mut files = apply_attempt(&root, &a.dirs[1], &a.base).unwrap();
        files.sort();
        assert_eq!(files, ["a.txt", "b.txt"]);
        assert_eq!(
            std::fs::read_to_string(root.join("a.txt")).unwrap(),
            "attempt two\n"
        );

        // A conflicting attempt is refused without touching anything.
        std::fs::write(a.dirs[0].join("a.txt"), "attempt one\n").unwrap();
        assert!(apply_attempt(&root, &a.dirs[0], &a.base).is_err());
        assert_eq!(
            std::fs::read_to_string(root.join("a.txt")).unwrap(),
            "attempt two\n"
        );

        remove_attempts(&root, &a.dirs);
        assert!(!a.dirs[0].exists());
    }
}
