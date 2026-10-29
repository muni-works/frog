//! One engine per linked git worktree.
//!
//! A worker session owns its worktree: its uncommitted work is its own. Two engines in one
//! worktree mix each other's edits (it happened: two sessions, one tree, nobody could tell
//! whose diff was whose). So an engine that starts in a linked worktree takes an exclusive
//! `flock` on a file in that worktree's private git dir (`.git/worktrees/<name>/frog-engine.lock`),
//! holds it for its life, and writes its session id there. A second engine there refuses,
//! naming the session that owns it. flock dies with its holder, so a crashed engine never
//! leaves the worktree stuck.
//!
//! Only linked worktrees (`.git` is a file): the main checkout is the user's, and they may run
//! as many sessions there as they like.

use anyhow::{Result, bail};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};

/// The lock file's name inside a worktree's git dir.
pub const LOCK_FILE: &str = "frog-engine.lock";

/// The linked worktree `dir` is in: (its top, its private git dir). `None` for the main
/// checkout, a plain folder, or anything git can't vouch for.
pub fn linked(dir: &Path) -> Option<(PathBuf, PathBuf)> {
    let mut at = dir;
    loop {
        let dot = at.join(".git");
        if dot.is_dir() {
            return None;
        }
        if dot.is_file() {
            let text = std::fs::read_to_string(&dot).ok()?;
            let gitdir = text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim();
            let gitdir = if Path::new(gitdir).is_relative() {
                at.join(gitdir)
            } else {
                PathBuf::from(gitdir)
            };
            // A linked worktree's git dir lives under the main repo's `.git/worktrees/`.
            // (A submodule's `.git` file points at `.git/modules/…`: not a worktree.)
            let is_worktree = gitdir
                .parent()
                .and_then(|p| p.file_name())
                .is_some_and(|n| n == "worktrees");
            return (is_worktree && gitdir.is_dir()).then(|| (at.to_path_buf(), gitdir));
        }
        at = at.parent()?;
    }
}

/// An engine's hold on its worktree, released when it drops (or the process dies).
#[derive(Debug)]
pub struct Lock {
    file: File,
    pub top: PathBuf,
}

impl Lock {
    /// Who's in it now: rewrite the owner line (a session `/clear`ed into a new id, say).
    pub fn set_owner(&mut self, session: &str) {
        let _ = self.file.set_len(0);
        let _ = self.file.seek(SeekFrom::Start(0));
        let _ = writeln!(self.file, "{session} {}", std::process::id());
        let _ = self.file.flush();
    }
}

impl Drop for Lock {
    /// Says it's free before letting go: a child forked elsewhere in this process, between its
    /// fork and exec, briefly holds a copy of the descriptor and so the flock. `acquire` reads
    /// an empty owner as "released, lingering" and waits that out instead of refusing.
    fn drop(&mut self) {
        let _ = self.file.set_len(0);
    }
}

/// The session (and pid) holding a worktree's lock, as its file says.
fn owner(file: &mut File) -> (String, String) {
    let mut text = String::new();
    let _ = file.seek(SeekFrom::Start(0));
    let _ = file.read_to_string(&mut text);
    let mut parts = text.split_whitespace();
    (
        parts.next().unwrap_or("").to_string(),
        parts.next().unwrap_or("?").to_string(),
    )
}

/// Take `dir`'s worktree for `session`. `Ok(None)`: not a linked worktree, nothing to hold.
/// When the holder is this same session (an engine from before a relaunch still on its way
/// out), waits up to `same_session_wait` for it to go. Any other holder is an error naming it.
pub fn acquire(
    dir: &Path,
    session: &str,
    same_session_wait: std::time::Duration,
) -> Result<Option<Lock>> {
    let Some((top, gitdir)) = linked(dir) else {
        return Ok(None);
    };
    let mut file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(gitdir.join(LOCK_FILE))?;
    let deadline = std::time::Instant::now() + same_session_wait;
    let lingering = std::time::Instant::now() + std::time::Duration::from_secs(2);
    loop {
        // SAFETY: flock on a valid fd we own; released when `file` closes.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
            let mut lock = Lock { file, top };
            lock.set_owner(session);
            return Ok(Some(lock));
        }
        let (holder, pid) = owner(&mut file);
        let now = std::time::Instant::now();
        // Released, but a forked child's copy of the descriptor still holds it for a moment.
        if holder.is_empty() && now < lingering {
            std::thread::sleep(std::time::Duration::from_millis(10));
            continue;
        }
        let holder = if holder.is_empty() { "an unknown session".to_string() } else { holder };
        if holder != session || now >= deadline {
            bail!(
                "this worktree ({}) already has an engine: session {holder} (pid {pid}) is running in it. \
One engine per worktree, so two sessions never mix uncommitted work: stop or archive {holder}, \
or start this one in its own worktree (StartSession with worktree:true).",
                top.display()
            );
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::process::Command;
    use std::time::Duration;

    /// A temp repo with one commit and a linked worktree: (repo, worktree).
    pub(crate) fn repo_with_worktree(tag: &str) -> (PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!("frog-wt-{tag}-{}", crate::session::new_id()));
        let repo = root.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        let git = |dir: &Path, args: &[&str]| {
            let out = Command::new("git")
                .args(["-c", "user.email=t@t", "-c", "user.name=t", "-c", "commit.gpgsign=false"])
                .args(args)
                .current_dir(dir)
                .output()
                .unwrap();
            assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        };
        git(&repo, &["init", "-q"]);
        std::fs::write(repo.join("a.txt"), "a").unwrap();
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "-qm", "init"]);
        let wt = repo.join(".frog/worktrees/w");
        git(&repo, &["worktree", "add", "-q", "-b", "frog/w", wt.to_str().unwrap()]);
        (repo, wt)
    }

    #[test]
    fn only_linked_worktrees_count() {
        let (repo, wt) = repo_with_worktree("linked");
        assert!(linked(&repo).is_none(), "the main checkout is the user's");
        // From anywhere inside it.
        let sub = wt.join("sub/dir");
        std::fs::create_dir_all(&sub).unwrap();
        let (top, gitdir) = linked(&sub).unwrap();
        assert_eq!(top, wt);
        assert!(gitdir.ends_with("worktrees/w"), "{}", gitdir.display());
        assert!(linked(&std::env::temp_dir()).is_none());
        let _ = std::fs::remove_dir_all(repo.parent().unwrap());
    }

    /// The macOS CI flake: a child forked elsewhere in the process, between fork and exec,
    /// holds a copy of the lock's descriptor, so the flock outlives the `Lock` for a moment.
    /// Re-taking it waits that out (the owner line is already empty) instead of refusing.
    #[test]
    fn a_released_lock_held_a_moment_by_a_forked_copy_is_waited_out() {
        let (repo, wt) = repo_with_worktree("linger");
        let first = acquire(&wt, "s-first", Duration::ZERO).unwrap().unwrap();
        // SAFETY: dup of a valid fd we own; the copy is closed on the thread below.
        let copy = unsafe { libc::dup(first.file.as_raw_fd()) };
        assert!(copy >= 0);
        drop(first);
        let closer = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(150));
            // SAFETY: closing the copy made above, once.
            unsafe { libc::close(copy) };
        });
        let t0 = std::time::Instant::now();
        let next = acquire(&wt, "s-next", Duration::ZERO).unwrap();
        assert!(next.is_some(), "a released lock is taken once its copy closes");
        assert!(t0.elapsed() >= Duration::from_millis(100), "it waited for the copy");
        closer.join().unwrap();
        let _ = std::fs::remove_dir_all(repo.parent().unwrap());
    }

    #[test]
    fn a_second_engine_in_a_worktree_is_refused_by_name() {
        let (repo, wt) = repo_with_worktree("lock");
        // The main checkout never locks.
        assert!(acquire(&repo, "s-main", Duration::ZERO).unwrap().is_none());
        let first = acquire(&wt, "s-first", Duration::ZERO).unwrap().unwrap();
        let err = acquire(&wt, "s-second", Duration::ZERO).unwrap_err().to_string();
        assert!(err.contains("session s-first"), "{err}");
        assert!(err.contains("worktree:true"), "{err}");
        // Released with its holder: the next engine gets in.
        drop(first);
        assert!(acquire(&wt, "s-second", Duration::ZERO).unwrap().is_some());
        let _ = std::fs::remove_dir_all(repo.parent().unwrap());
    }
}
