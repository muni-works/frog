//! `[git] open_pr_when_done = "auto"`: the engine opens a **draft** PR itself when a session's
//! work is done (docs/plans/2026-11-13-open-pr-when-done.md).
//!
//! Cam's decisions (2026-11-15): `auto` is a standing grant for exactly two actions, a plain
//! push of the session's own branch and one `gh pr create --draft`; the PR is a draft (nobody
//! has read the diff); sessions started by an agent (workers) never open one. Nothing here runs
//! under `off` or `ask`, and the grant is no wider than those two commands: never `--force`,
//! never the base branch, never another ref, never a merge.
//!
//! The engine runs them itself, not the model: the decision is deterministic, costs no tokens,
//! and the commands can't drift into something the grant doesn't cover.
//!
//! [`should_open`] is the Mac's `OpenPR.shouldOpenPR` (FrogKit) plus the worker exclusion,
//! over facts the engine knows on its own.

use crate::prs::PrBinding;
use anyhow::{Context, Result, anyhow, bail};
use std::path::Path;
use std::time::Duration;

/// Everything the decision depends on. Each one is a reason not to open a PR on its own.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Facts {
    /// The session runs in a linked git worktree: its own branch.
    pub worktree: bool,
    /// Commits on that branch the remote's default branch doesn't have.
    pub ahead: u32,
    /// A PR is already bound to the session.
    pub has_pr: bool,
    /// The session started other sessions: a manager.
    pub manager: bool,
    /// An agent started the session (`--worker`, or it has a parent session).
    pub worker: bool,
    /// A read-only session (a subagent): it never writes, so never opens.
    pub read_only: bool,
    /// `open-pr: off` (or `never`) on a line of the first prompt.
    pub opted_out: bool,
}

/// The whole decision. Managers and workers are excluded because a tree of sessions makes a
/// branch per session: opening a PR for each would be dozens a night into one repo.
pub fn should_open(f: &Facts) -> bool {
    f.worktree
        && f.ahead > 0
        && !f.has_pr
        && !f.manager
        && !f.worker
        && !f.read_only
        && !f.opted_out
}

/// The first-prompt marker that turns opening a PR off for one session (FrogKit's
/// `OpenPR.optedOut`): a line of its own, `open-pr: off` or `open-pr: never`, any case.
pub fn opted_out(first_prompt: Option<&str>) -> bool {
    first_prompt.is_some_and(|p| {
        p.lines().any(|l| {
            let l = l.trim().to_ascii_lowercase();
            l.strip_prefix("open-pr:")
                .is_some_and(|v| matches!(v.trim(), "off" | "never"))
        })
    })
}

/// The session's branch and what it would be opened against.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Branch {
    /// The checked-out branch (`feat`), never detached.
    pub name: String,
    /// The remote's default branch (`main`), from `origin/HEAD`, else `origin/main` or
    /// `origin/master`.
    pub base: String,
    /// Commits on `name` that `origin/<base>` doesn't have.
    pub ahead: u32,
    /// `HEAD`'s sha: one attempt per head, so a failure isn't retried every turn.
    pub head: String,
}

/// Run `git` in `root`; its trimmed stdout, or an error with its stderr.
fn git(root: &Path, args: &[&str]) -> Result<String> {
    let out = std::process::Command::new("git")
        .args(args)
        .current_dir(root)
        .env("GIT_TERMINAL_PROMPT", "0")
        .output()
        .with_context(|| format!("running git {}", args.join(" ")))?;
    if !out.status.success() {
        bail!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Where `root`'s branch stands against the remote's default branch. `Ok(None)`: nothing to
/// open from here (detached, no `origin`, no default branch, or on the default branch itself).
pub fn branch(root: &Path) -> Result<Option<Branch>> {
    let Ok(name) = git(root, &["symbolic-ref", "--quiet", "--short", "HEAD"]) else {
        return Ok(None);
    };
    let base = git(
        root,
        &[
            "symbolic-ref",
            "--quiet",
            "--short",
            "refs/remotes/origin/HEAD",
        ],
    )
    .ok()
    .and_then(|b| b.strip_prefix("origin/").map(str::to_string))
    .or_else(|| {
        ["main", "master"]
            .into_iter()
            .find(|b| {
                git(
                    root,
                    &[
                        "rev-parse",
                        "--verify",
                        "--quiet",
                        &format!("refs/remotes/origin/{b}"),
                    ],
                )
                .is_ok()
            })
            .map(str::to_string)
    });
    let Some(base) = base else {
        return Ok(None);
    };
    if name == base {
        return Ok(None);
    }
    let ahead = git(
        root,
        &["rev-list", "--count", &format!("origin/{base}..HEAD")],
    )?
    .parse()
    .unwrap_or(0);
    let head = git(root, &["rev-parse", "HEAD"])?;
    Ok(Some(Branch {
        name,
        base,
        ahead,
        head,
    }))
}

/// Run `program args` in `root` with a time limit; stdout and stderr together on success.
async fn run(root: &Path, program: &Path, args: &[&str], limit: Duration) -> Result<String> {
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(args)
        .current_dir(root)
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GH_PROMPT_DISABLED", "1")
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    let shown = format!("{} {}", program.display(), args.join(" "));
    let out = tokio::time::timeout(limit, cmd.output())
        .await
        .map_err(|_| anyhow!("`{shown}` took longer than {}s", limit.as_secs()))?
        .with_context(|| format!("running `{shown}`"))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    if !out.status.success() {
        bail!("`{shown}` failed: {}", text.trim());
    }
    Ok(text)
}

/// The two granted commands: push the branch (no force, its own ref only) and open a draft PR
/// against the default branch. The PR `gh` printed, bound as the session's own.
pub async fn open(root: &Path, b: &Branch, gh: &Path) -> Result<PrBinding> {
    let refspec = format!("refs/heads/{0}:refs/heads/{0}", b.name);
    run(
        root,
        Path::new("git"),
        &["push", "--set-upstream", "origin", &refspec],
        Duration::from_secs(120),
    )
    .await?;
    let out = run(
        root,
        gh,
        &[
            "pr", "create", "--draft", "--fill", "--base", &b.base, "--head", &b.name,
        ],
        Duration::from_secs(60),
    )
    .await?;
    crate::prs::created("gh pr create", &out)
        .ok_or_else(|| anyhow!("gh pr create printed no PR link: {}", out.trim()))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn every_reason_to_say_no_is_enough_on_its_own() {
        let yes = Facts {
            worktree: true,
            ahead: 2,
            ..Facts::default()
        };
        assert!(should_open(&yes));
        let noes = [
            Facts {
                worktree: false,
                ..yes.clone()
            },
            Facts {
                ahead: 0,
                ..yes.clone()
            },
            Facts {
                has_pr: true,
                ..yes.clone()
            },
            Facts {
                manager: true,
                ..yes.clone()
            },
            Facts {
                worker: true,
                ..yes.clone()
            },
            Facts {
                read_only: true,
                ..yes.clone()
            },
            Facts {
                opted_out: true,
                ..yes.clone()
            },
        ];
        for f in noes {
            assert!(!should_open(&f), "{f:?}");
        }
    }

    #[test]
    fn the_opt_out_is_a_line_of_its_own_in_the_first_prompt() {
        assert!(opted_out(Some("fix the thing\nOpen-PR: off\n")));
        assert!(opted_out(Some("  open-pr:never")));
        assert!(!opted_out(Some("please open-pr: off for me")));
        assert!(!opted_out(Some("open-pr: on")));
        assert!(!opted_out(None));
    }

    /// A repo with a bare `origin` whose default branch is `main`, and a linked worktree on
    /// branch `feat` with one commit `main` doesn't have. Returns (base dir, worktree, origin).
    pub(crate) fn repo_with_feature() -> (PathBuf, PathBuf, PathBuf) {
        let base = std::env::temp_dir().join(format!("frog-open-pr-{}", crate::session::new_id()));
        let (origin, repo, wt) = (base.join("origin.git"), base.join("repo"), base.join("wt"));
        std::fs::create_dir_all(&repo).unwrap();
        let sh = |dir: &Path, args: &[&str]| {
            let out = std::process::Command::new("git")
                .args([
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t@t",
                    "-c",
                    "init.defaultBranch=main",
                ])
                .args(args)
                .current_dir(dir)
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "git {args:?}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
        };
        sh(&base, &["init", "--bare", "-q", origin.to_str().unwrap()]);
        sh(&repo, &["init", "-q"]);
        std::fs::write(repo.join("a.txt"), "a\n").unwrap();
        sh(&repo, &["add", "."]);
        sh(&repo, &["commit", "-qm", "base"]);
        sh(
            &repo,
            &["remote", "add", "origin", origin.to_str().unwrap()],
        );
        sh(&repo, &["push", "-q", "origin", "main"]);
        sh(&repo, &["remote", "set-head", "origin", "main"]);
        sh(
            &repo,
            &["worktree", "add", "-q", "-b", "feat", wt.to_str().unwrap()],
        );
        std::fs::write(wt.join("b.txt"), "b\n").unwrap();
        sh(&wt, &["add", "."]);
        sh(&wt, &["commit", "-qm", "add b"]);
        (base, wt, origin)
    }

    /// A stand-in `gh` that records its arguments next to itself and prints a PR link.
    pub(crate) fn fake_gh(dir: &Path) -> PathBuf {
        let gh = dir.join("gh");
        let log = dir.join("gh.args");
        std::fs::write(
            &gh,
            format!(
                "#!/bin/sh\necho \"$@\" >> '{}'\necho https://github.com/o/r/pull/41\n",
                log.display()
            ),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
        gh
    }

    /// The branch `origin` has for `name`, if any.
    pub(crate) fn remote_branch(origin: &Path, name: &str) -> Option<String> {
        git(
            origin,
            &[
                "rev-parse",
                "--verify",
                "--quiet",
                &format!("refs/heads/{name}"),
            ],
        )
        .ok()
    }

    #[tokio::test]
    async fn pushes_its_own_branch_and_opens_a_draft_against_the_default_branch() {
        let (base, wt, origin) = repo_with_feature();
        let b = branch(&wt).unwrap().expect("a branch to open");
        assert_eq!(
            (b.name.as_str(), b.base.as_str(), b.ahead),
            ("feat", "main", 1)
        );
        let gh = fake_gh(&base);
        let pr = open(&wt, &b, &gh).await.unwrap();
        assert_eq!((pr.repo.as_str(), pr.number, pr.auto), ("o/r", 41, true));
        assert_eq!(
            remote_branch(&origin, "feat").as_deref(),
            Some(b.head.as_str())
        );
        let args = std::fs::read_to_string(base.join("gh.args")).unwrap();
        assert_eq!(
            args.trim(),
            "pr create --draft --fill --base main --head feat"
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn nothing_to_open_on_the_default_branch_or_detached() {
        let (base, wt, _) = repo_with_feature();
        assert!(
            branch(&base.join("repo")).unwrap().is_none(),
            "on main itself"
        );
        git(&wt, &["checkout", "-q", "--detach"]).unwrap();
        assert!(branch(&wt).unwrap().is_none(), "detached");
        let _ = std::fs::remove_dir_all(&base);
    }
}
