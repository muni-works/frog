//! Pull requests bound to a session (docs/plans/2026-11-12-composer-tray.md): the composer's
//! git line shows them, and the session log keeps them so every client and a replay agree.
//!
//! The engine owns the bindings, not the state: clients (the Mac's `gh pr view`, the gateway's
//! GitHub App) fetch title, state and checks, and may write what they saw back with
//! [`Op::BindPr`](crate::protocol::Op::BindPr) so a replay renders the last known state.

use regex::Regex;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::sync::LazyLock;

/// One bound PR. `repo` is `owner/name`; the pair (`repo`, `number`) is its identity.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct PrBinding {
    pub repo: String,
    pub number: u64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub title: String,
    /// `draft`, `checks`, `failing`, `approved`, `merged` or `closed`, as last seen; empty
    /// until a client has looked.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub state: String,
    /// Passing and total checks, as last seen.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checks: Option<(u32, u32)>,
    /// Bound by the engine because the session's branch opened it (vs. by hand).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub auto: bool,
}

impl PrBinding {
    pub fn new(repo: impl Into<String>, number: u64) -> Self {
        Self {
            repo: repo.into(),
            number,
            title: String::new(),
            state: String::new(),
            checks: None,
            auto: false,
        }
    }

    pub fn url(&self) -> String {
        format!("https://github.com/{}/pull/{}", self.repo, self.number)
    }
}

/// Insert or update `pr` (matched on repo and number). Fields the update leaves empty keep
/// what was known. Returns whether anything changed.
pub fn upsert(prs: &mut Vec<PrBinding>, pr: PrBinding) -> bool {
    let Some(have) = prs
        .iter_mut()
        .find(|p| p.repo == pr.repo && p.number == pr.number)
    else {
        prs.push(pr);
        return true;
    };
    let mut next = pr;
    if next.title.is_empty() {
        next.title = have.title.clone();
    }
    if next.state.is_empty() {
        next.state = have.state.clone();
    }
    if next.checks.is_none() {
        next.checks = have.checks;
    }
    next.auto |= have.auto;
    if *have == next {
        return false;
    }
    *have = next;
    true
}

/// Drop the binding for `repo#number`. Returns whether it was there.
pub fn remove(prs: &mut Vec<PrBinding>, repo: &str, number: u64) -> bool {
    let before = prs.len();
    prs.retain(|p| !(p.repo == repo && p.number == number));
    prs.len() != before
}

static PR_URL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"https://github\.com/([\w.-]+/[\w.-]+)/pull/(\d+)").unwrap());

/// The PR a shell command just opened: `gh pr create` prints its URL when it succeeds. Only
/// that command counts, so a PR the agent merely mentioned or viewed never binds itself.
pub fn created(command: &str, output: &str) -> Option<PrBinding> {
    if !command.contains("gh pr create") {
        return None;
    }
    let c = PR_URL.captures_iter(output).last()?;
    let mut pr = PrBinding::new(&c[1], c[2].parse().ok()?);
    pr.auto = true;
    Some(pr)
}

/// Parse what a person pastes into "Bind a PR…": a PR URL, `owner/name#12`, or `#12` / `12`
/// (resolved against `repo`, the session's own).
pub fn parse_ref(s: &str, repo: Option<&str>) -> Option<PrBinding> {
    let s = s.trim();
    if let Some(c) = PR_URL.captures(s) {
        return Some(PrBinding::new(&c[1], c[2].parse().ok()?));
    }
    if let Some((r, n)) = s.split_once('#')
        && !r.is_empty()
    {
        return Some(PrBinding::new(r, n.parse().ok()?));
    }
    let n: u64 = s.trim_start_matches('#').parse().ok()?;
    Some(PrBinding::new(repo?, n))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gh_pr_create_binds_its_url() {
        let out = "Creating pull request for me:feat into main\n\nhttps://github.com/muni-works/frog/pull/297\n";
        let pr = created("git push -u origin HEAD && gh pr create --fill", out).unwrap();
        assert_eq!(
            (pr.repo.as_str(), pr.number, pr.auto),
            ("muni-works/frog", 297, true)
        );
        assert!(created("gh pr view 297", out).is_none());
        assert!(created("gh pr create --fill", "error: no commits").is_none());
    }

    #[test]
    fn upsert_merges_and_keeps_known_fields() {
        let mut prs = vec![];
        let mut a = PrBinding::new("o/r", 1);
        a.title = "First".into();
        a.auto = true;
        assert!(upsert(&mut prs, a));
        let mut seen = PrBinding::new("o/r", 1);
        seen.state = "failing".into();
        assert!(upsert(&mut prs, seen.clone()));
        assert_eq!(prs[0].title, "First");
        assert!(prs[0].auto);
        assert_eq!(prs[0].state, "failing");
        assert!(!upsert(&mut prs, seen), "same state is no change");
        assert!(upsert(&mut prs, PrBinding::new("o/r", 2)));
        assert_eq!(prs.len(), 2);
        assert!(remove(&mut prs, "o/r", 1));
        assert!(!remove(&mut prs, "o/r", 1));
        assert_eq!(prs.len(), 1);
    }

    #[test]
    fn parse_ref_takes_urls_and_numbers() {
        assert_eq!(
            parse_ref("https://github.com/o/r/pull/12", None)
                .unwrap()
                .number,
            12
        );
        assert_eq!(parse_ref("x/y#3", None).unwrap().repo, "x/y");
        assert_eq!(parse_ref("#7", Some("o/r")).unwrap().repo, "o/r");
        assert!(parse_ref("#7", None).is_none());
        assert!(parse_ref("nope", Some("o/r")).is_none());
    }
}
