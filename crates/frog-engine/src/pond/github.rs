//! The GitHub sense: reviews waiting on you, your PRs that need something, and mentions.
//! Read through the `gh` CLI, so it uses the account you're already signed in with and frog
//! never holds a token. Two requests, both reads.

use super::{Item, Kind, Sent};
use anyhow::{Context, Result, bail};
use serde_json::Value;
use std::time::Duration;

pub struct Found {
    pub items: Vec<Item>,
    /// What was read, in words.
    pub what: String,
    pub sent: Sent,
}

const QUERY: &str = "query { viewer { pullRequests(first: 30, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number title url updatedAt isDraft reviewDecision repository { nameWithOwner } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } search(query: \"is:pr is:open review-requested:@me archived:false\", type: ISSUE, first: 30) { nodes { ... on PullRequest { number title url updatedAt author { login } repository { nameWithOwner } } } } }";

const NOTIFICATIONS: &str = "notifications?per_page=50";

pub async fn read() -> Result<Found> {
    let prs = gh(&["api", "graphql", "-f", &format!("query={QUERY}")]).await?;
    let notes = gh(&["api", NOTIFICATIONS]).await?;
    let mut items = from_graphql(&prs);
    items.extend(from_notifications(&notes));
    let note_count = notes.as_array().map_or(0, Vec::len);
    Ok(Found {
        what: format!(
            "{note_count} notification{}, open pull requests and review requests",
            if note_count == 1 { "" } else { "s" }
        ),
        sent: Sent {
            to: "api.github.com".into(),
            bytes: (QUERY.len() + NOTIFICATIONS.len()) as u64,
            what: "queries for your pull requests and notifications".into(),
            private: false,
        },
        items,
    })
}

async fn gh(args: &[&str]) -> Result<Value> {
    let out = tokio::time::timeout(
        Duration::from_secs(30),
        tokio::process::Command::new("gh")
            .args(args)
            .stdin(std::process::Stdio::null())
            .output(),
    )
    .await
    .context("gh timed out")?
    .context("running gh (is the GitHub CLI installed?)")?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        bail!("gh: {}", err.lines().next().unwrap_or("failed"));
    }
    Ok(serde_json::from_slice(&out.stdout)?)
}

fn from_graphql(v: &Value) -> Vec<Item> {
    let mut items = Vec::new();
    let data = &v["data"];
    for pr in data["search"]["nodes"].as_array().into_iter().flatten() {
        let Some(it) = pr_item(pr, Kind::Review) else { continue };
        items.push(Item {
            who: pr["author"]["login"].as_str().map(str::to_owned),
            ..it
        });
    }
    for pr in data["viewer"]["pullRequests"]["nodes"].as_array().into_iter().flatten() {
        if pr["isDraft"].as_bool() == Some(true) {
            continue;
        }
        let checks = pr["commits"]["nodes"][0]["commit"]["statusCheckRollup"]["state"].as_str();
        let review = pr["reviewDecision"].as_str();
        let kind = match (checks, review) {
            (Some("FAILURE" | "ERROR"), _) => Kind::Failing,
            (_, Some("CHANGES_REQUESTED")) => Kind::ChangesRequested,
            (Some("SUCCESS") | None, Some("APPROVED")) => Kind::Ready,
            _ => continue,
        };
        items.extend(pr_item(pr, kind));
    }
    items
}

fn pr_item(pr: &Value, kind: Kind) -> Option<Item> {
    let repo = pr["repository"]["nameWithOwner"].as_str()?;
    let n = pr["number"].as_u64()?;
    Some(Item {
        id: format!("gh:{}:{repo}#{n}", serde_json::to_value(kind).ok()?.as_str()?),
        source: "github".into(),
        kind,
        title: pr["title"].as_str()?.to_string(),
        url: pr["url"].as_str()?.to_string(),
        place: repo.to_string(),
        who: None,
        updated: pr["updatedAt"].as_str()?.parse().ok()?,
    })
}

/// Mentions and assignments. Review requests come from the search, which knows when you've
/// already reviewed; the rest (subscriptions, CI chatter, your own threads) is noise here.
fn from_notifications(v: &Value) -> Vec<Item> {
    v.as_array()
        .into_iter()
        .flatten()
        .filter_map(|n| {
            let kind = match n["reason"].as_str()? {
                "mention" | "team_mention" => Kind::Mention,
                "assign" => Kind::Assigned,
                _ => return None,
            };
            let repo = n["repository"]["full_name"].as_str()?;
            Some(Item {
                id: format!("gh:note:{}", n["id"].as_str()?),
                source: "github".into(),
                kind,
                title: n["subject"]["title"].as_str()?.to_string(),
                url: web_url(n["subject"]["url"].as_str().unwrap_or(""), repo),
                place: repo.to_string(),
                who: None,
                updated: n["updated_at"].as_str()?.parse().ok()?,
            })
        })
        .collect()
}

/// The page for an API URL: `api.github.com/repos/o/r/pulls/8` → `github.com/o/r/pull/8`.
fn web_url(api: &str, repo: &str) -> String {
    let Some(rest) = api.strip_prefix("https://api.github.com/repos/") else {
        return format!("https://github.com/{repo}");
    };
    format!("https://github.com/{}", rest.replacen("/pulls/", "/pull/", 1))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_reviews_and_what_your_prs_need() {
        let v = json!({"data": {
            "viewer": {"pullRequests": {"nodes": [
                {"number": 1, "title": "red", "url": "u1", "updatedAt": "2026-09-30T00:00:00Z", "isDraft": false, "reviewDecision": null, "repository": {"nameWithOwner": "o/r"}, "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE"}}}]}},
                {"number": 2, "title": "fine", "url": "u2", "updatedAt": "2026-09-30T00:00:00Z", "isDraft": false, "reviewDecision": null, "repository": {"nameWithOwner": "o/r"}, "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}},
                {"number": 3, "title": "go", "url": "u3", "updatedAt": "2026-09-30T00:00:00Z", "isDraft": false, "reviewDecision": "APPROVED", "repository": {"nameWithOwner": "o/r"}, "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "SUCCESS"}}}]}},
                {"number": 4, "title": "draft", "url": "u4", "updatedAt": "2026-09-30T00:00:00Z", "isDraft": true, "reviewDecision": null, "repository": {"nameWithOwner": "o/r"}, "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "FAILURE"}}}]}}
            ]}},
            "search": {"nodes": [
                {"number": 9, "title": "look", "url": "u9", "updatedAt": "2026-09-29T00:00:00Z", "author": {"login": "alex"}, "repository": {"nameWithOwner": "o/s"}}
            ]}
        }});
        let items = from_graphql(&v);
        let ids: Vec<_> = items.iter().map(|i| (i.id.as_str(), i.kind)).collect();
        assert_eq!(ids, [("gh:review:o/s#9", Kind::Review), ("gh:failing:o/r#1", Kind::Failing), ("gh:ready:o/r#3", Kind::Ready)]);
        assert_eq!(items[0].who.as_deref(), Some("alex"));
    }

    #[test]
    fn keeps_mentions_and_assignments_only() {
        let v = json!([
            {"id": "1", "reason": "mention", "updated_at": "2026-09-30T00:22:45Z", "subject": {"title": "Add vcad", "url": "https://api.github.com/repos/AppImage/x/pulls/8671"}, "repository": {"full_name": "AppImage/x"}},
            {"id": "2", "reason": "subscribed", "updated_at": "2026-09-30T00:00:00Z", "subject": {"title": "noise", "url": null}, "repository": {"full_name": "p/q"}}
        ]);
        let items = from_notifications(&v);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].url, "https://github.com/AppImage/x/pull/8671");
    }
}
