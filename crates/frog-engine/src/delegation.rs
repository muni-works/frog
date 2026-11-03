//! Delegated approvals (docs/design/delegation.md): which flagged calls may be decided
//! by someone other than the user, and which never may.
//!
//! Two kinds of class. **Hard** classes ([`hard_class`]) are fixed here, in code: a call
//! in one always reaches the user as a card, whatever a classifier said. No config can
//! touch them. **Soft** classes only route a call that is *still flagged* after the
//! second classifier pass: to the chief when `[delegation] chief` grants the class, to
//! the user otherwise.

use crate::approval::{created_here, expand, normalize, words};
use regex::Regex;
use serde_json::Value;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

/// Programs that delete what they name.
const DELETE: &[&str] = &["rm", "rmdir", "unlink", "shred", "srm", "trash"];

/// Wrappers that run the program after them.
const WRAPPERS: &[&str] = &["sudo", "doas", "command", "env", "nice", "nohup", "time"];

/// Why a call is never delegable, if it is: deletes outside the session's scratch,
/// force-pushes or history rewrites on a remote, production deploys, purchases, posts
/// or messages to people, credentials access. `cwd` is where the shell runs, `root`
/// the session's checkout, `created` what this session made.
pub fn hard_class(
    name: &str,
    input: &Value,
    cwd: &Path,
    root: &Path,
    created: &HashSet<PathBuf>,
) -> Option<&'static str> {
    match name {
        "Bash" | crate::panes::TERMINAL => {
            hard_command(input["command"].as_str().unwrap_or(""), cwd, root, created)
        }
        "Write" | "Edit" => input["file_path"]
            .as_str()
            .filter(|p| crate::shell::touches_credentials(p))
            .map(|_| "touches credentials"),
        _ if name.starts_with("mcp__") => hard_mcp(name),
        _ => None,
    }
}

fn hard_command(
    cmd: &str,
    cwd: &Path,
    root: &Path,
    created: &HashSet<PathBuf>,
) -> Option<&'static str> {
    static RULES: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
        [
            (
                r"git\s+push\b[^;&|]*(\s--force\b|\s--force-with-lease\b|\s--force-if-includes\b|\s-[a-zA-Z]*f[a-zA-Z]*\b|\s--mirror\b|\s--delete\b|\s-d\b|\s\+\S|\s:\S)",
                "force-pushes or rewrites a remote",
            ),
            (
                r"\b(wrangler\s+(deploy|publish)\b|vercel\b[^;&|]*--prod\b|netlify\s+deploy\b[^;&|]*--prod\b|fly(ctl)?\s+deploy\b|terraform\s+(apply|destroy)\b|pulumi\s+(up|destroy)\b|kubectl\s+(apply|delete|rollout)\b|helm\s+(install|upgrade|uninstall)\b|git\s+push\s+heroku\b)",
                "deploys to production",
            ),
            (
                r"\b(npm|cargo|gem|pnpm|yarn)\s+publish\b|\btwine\s+upload\b|\bgh\s+release\s+create\b|\bgh\s+(issue|pr)\s+(comment|review)\b|\bgh\s+issue\s+create\b|\bgh\s+gist\s+create\b|\b(sendmail|mailx?|mutt)\s|hooks\.slack\.com|discord(app)?\.com/api/webhooks|api\.(twitter|x)\.com",
                "posts or messages people",
            ),
            (
                r"\bgh\s+repo\s+delete\b|\bgh\s+api\b[^;&|]*-X\s*DELETE\b",
                "deletes outside the session's scratch",
            ),
        ]
        .into_iter()
        .map(|(p, why)| (Regex::new(p).unwrap(), why))
        .collect()
    });
    if cmd.trim().is_empty() {
        return None;
    }
    if crate::shell::touches_credentials(cmd) {
        return Some("touches credentials");
    }
    let segments = crate::shell::segments(cmd).unwrap_or_else(|| vec![cmd.to_string()]);
    let outside = |p: &Path| !in_scratch(p, root, created);
    for seg in &segments {
        match delete_targets(seg, cwd) {
            Targets::None => {}
            Targets::Unknown => return Some("deletes outside the session's scratch"),
            Targets::Paths(ps) if ps.iter().any(|p| outside(p)) => {
                return Some("deletes outside the session's scratch");
            }
            Targets::Paths(_) => {}
        }
    }
    if let Some((_, why)) = RULES.iter().find(|(re, _)| re.is_match(cmd)) {
        // A dry run deploys nothing.
        if !(*why == "deploys to production" && cmd.contains("--dry-run")) {
            return Some(why);
        }
    }
    None
}

/// Whether `p` is the session's to delete: inside its checkout (but not the checkout
/// itself), something it created, or a path under the shared temp dir that doesn't
/// exist yet. An existing tree in the temp dir may be another session's or the user's.
pub fn in_scratch(p: &Path, root: &Path, created: &HashSet<PathBuf>) -> bool {
    let root = normalize(root);
    if created_here(p, created) {
        return true;
    }
    if p.starts_with(&root) && p != root {
        return true;
    }
    let temp = normalize(&std::env::temp_dir());
    let in_temp = p.starts_with(&temp) || p.starts_with("/private/tmp") || p.starts_with("/tmp");
    in_temp && !p.exists() && p != temp && p != Path::new("/private/tmp") && p != Path::new("/tmp")
}

enum Targets {
    /// Not a delete.
    None,
    /// A delete whose targets can't be pinned down (`xargs rm`, `rm $DIR`).
    Unknown,
    Paths(Vec<PathBuf>),
}

/// What a segment deletes: `rm`'s operands (globs cut back to the directory they
/// expand in), `find ROOT … -delete`'s roots.
fn delete_targets(seg: &str, cwd: &Path) -> Targets {
    let ws = words(seg);
    let mut i = 0;
    // Leading assignments and wrappers (`sudo`, `env X=1`).
    while i < ws.len() && (WRAPPERS.contains(&ws[i].as_str()) || is_assignment(&ws[i])) {
        i += 1;
    }
    let Some(prog) = ws.get(i) else {
        return Targets::None;
    };
    let prog = prog.rsplit('/').next().unwrap_or(prog);
    let rest = &ws[i + 1..];
    if prog == "xargs" {
        // xargs feeds names the command can't see.
        return match rest.iter().find(|w| !w.starts_with('-')) {
            Some(p) if DELETE.contains(&p.rsplit('/').next().unwrap_or(p)) => Targets::Unknown,
            _ => Targets::None,
        };
    }
    if prog == "find" {
        if !rest.iter().any(|w| w == "-delete") && !seg.contains("-exec rm") {
            return Targets::None;
        }
        let roots: Vec<&String> = rest.iter().take_while(|w| !w.starts_with('-')).collect();
        if roots.is_empty() {
            return Targets::Paths(vec![normalize(cwd)]);
        }
        return resolve(roots.into_iter(), cwd);
    }
    if !DELETE.contains(&prog) {
        return Targets::None;
    }
    let mut operands = Vec::new();
    let mut flags_done = false;
    for w in rest {
        if !flags_done && w == "--" {
            flags_done = true;
            continue;
        }
        if !flags_done && w.starts_with('-') {
            continue;
        }
        operands.push(w);
    }
    if operands.is_empty() {
        return Targets::None;
    }
    resolve(operands.into_iter(), cwd)
}

fn is_assignment(w: &str) -> bool {
    w.split_once('=')
        .is_some_and(|(k, _)| !k.is_empty() && k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'))
}

fn resolve<'a>(words: impl Iterator<Item = &'a String>, cwd: &Path) -> Targets {
    let mut out = Vec::new();
    for w in words {
        let w = w.as_str();
        // `$VAR` (other than `$HOME/`) and command substitutions hide the target.
        let var = w.contains('$') && !w.starts_with("$HOME/");
        if var || w.contains('`') {
            return Targets::Unknown;
        }
        // A glob deletes what matches in the directory before the first wildcard.
        let w = match w.find(['*', '?', '[']) {
            Some(i) => {
                let head = &w[..i];
                match head.rfind('/') {
                    Some(0) => "/",
                    Some(j) => &head[..j],
                    None => ".",
                }
            }
            None => w,
        };
        out.push(normalize(&expand(w, cwd)));
    }
    Targets::Paths(out)
}

/// Hard classes for MCP tools, by verb: deletes, deploys, purchases, posts.
fn hard_mcp(name: &str) -> Option<&'static str> {
    if crate::auto::mcp_read(name) {
        return None;
    }
    let (_, tool) = crate::auto::mcp_parts(name)?;
    let tool = tool.to_ascii_lowercase();
    let verbs: Vec<&str> = tool.split(['-', '_', '.']).collect();
    let any = |set: &[&str]| verbs.iter().any(|v| set.contains(v));
    if any(&["delete", "destroy", "remove", "terminate", "drop", "purge", "wipe"]) {
        return Some("deletes outside the session's scratch");
    }
    if any(&["buy", "purchase", "checkout", "order", "pay", "charge", "subscribe", "renew"]) {
        return Some("makes a purchase");
    }
    if any(&["deploy", "promote", "release"]) {
        return Some("deploys to production");
    }
    if any(&["send", "post", "publish", "tweet", "email", "reply", "comment", "notify"]) {
        return Some("posts or messages people");
    }
    None
}

/// The soft class of a still-flagged call — which shape of harm it is, from the
/// grant vocabulary (`config::grant`). Only soft classes route to the chief, and
/// only when `[delegation] chief_classes` grants them; a call with no class here
/// cards the user. The second pass's context, not parsing, says whether the shape
/// fits this session (its scratch, its pods). Callers check [`hard_class`] first.
pub fn soft_class(
    name: &str,
    input: &Value,
    cwd: &Path,
    root: &Path,
    created: &HashSet<PathBuf>,
    cfg: &crate::config::Config,
) -> Option<&'static str> {
    use crate::config::grant;
    if name.starts_with("mcp__") {
        // Only a server already granted writes in `[mcp_trust]`.
        let (server, _) = crate::auto::mcp_parts(name)?;
        return cfg.mcp_write_trusted(server).then_some(grant::MCP_WRITE_GRANTED);
    }
    match name {
        "Bash" | crate::panes::TERMINAL => {
            soft_command(input["command"].as_str().unwrap_or(""), cwd, root, created)
        }
        "Write" | "Edit" => {
            let p = normalize(&expand(input["file_path"].as_str()?, cwd));
            in_scratch(&p, root, created).then_some(grant::OWN_SCOPE_WRITES)
        }
        _ => None,
    }
}

/// The soft class for a call that widens the egress fence — `hosts` is what it asks
/// beyond the session's allow-list (empty: it leaves the sandbox the list is enforced
/// in). Never called for a hard class: deletes, credentials and deploys are checked
/// first and always card the user.
pub fn soft_egress(_hosts: &[String]) -> Option<&'static str> {
    Some(crate::config::grant::EGRESS)
}

fn soft_command(
    cmd: &str,
    cwd: &Path,
    root: &Path,
    created: &HashSet<PathBuf>,
) -> Option<&'static str> {
    use crate::config::grant;
    let segments = crate::shell::segments(cmd)?;
    let programs: Vec<String> = segments.iter().map(|s| crate::approval::program(s)).collect();
    if matches!(programs.first().map(String::as_str), Some("ssh" | "scp" | "sftp")) {
        return Some(grant::SSH_SCRATCH);
    }
    // Deletes, every target inside the session's scratch (anything else is hard).
    let deletes: Vec<Targets> = segments.iter().map(|s| delete_targets(s, cwd)).collect();
    if deletes.iter().any(|t| !matches!(t, Targets::None)) {
        let all_scratch = deletes.iter().all(|t| match t {
            Targets::None => true,
            Targets::Unknown => false,
            Targets::Paths(ps) => ps.iter().all(|p| in_scratch(p, root, created)),
        });
        return all_scratch.then_some(grant::SCRATCH_DELETES);
    }
    // Compute spend: containers, clusters and pods the org pays for.
    if programs
        .iter()
        .any(|p| matches!(p.as_str(), "docker" | "kubectl" | "helm" | "runpod" | "runpodctl" | "flyctl"))
    {
        return Some(grant::POD_SPEND);
    }
    // A push to a remote (a force push is a hard class, already checked).
    if segments
        .iter()
        .any(|seg| crate::approval::program(seg) == "git" && seg.contains("push"))
    {
        return Some(grant::NETWORK_READ_WRITES);
    }
    // Writes inside the project or the session's own scratch.
    if crate::approval::own_scope(cmd, cwd, root, created) {
        return Some(grant::OWN_SCOPE_WRITES);
    }
    // A long multi-step command whose segments are individually ordinary.
    if segments.len() >= 4 && segments.iter().all(|s| crate::approval::routine(s)) {
        return Some(grant::LONG_COMMANDS);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn bash(cmd: &str, root: &Path, created: &HashSet<PathBuf>) -> Option<&'static str> {
        hard_class("Bash", &json!({ "command": cmd }), root, root, created)
    }

    #[test]
    fn deletes_outside_scratch_are_hard_and_scratch_deletes_are_not() {
        let root = std::env::temp_dir().join(format!("deleg-hard-root-{}", crate::session::new_id()));
        std::fs::create_dir_all(root.join("target")).unwrap();
        let theirs =
            std::env::temp_dir().join(format!("deleg-hard-theirs-{}", crate::session::new_id()));
        std::fs::create_dir_all(&theirs).unwrap();
        let mine = std::env::temp_dir().join(format!("deleg-hard-mine-{}", crate::session::new_id()));
        std::fs::create_dir_all(&mine).unwrap();
        let created: HashSet<PathBuf> = [normalize(&mine)].into_iter().collect();
        let none = HashSet::new();

        // The session's own scratch and its checkout: not hard.
        assert_eq!(bash(&format!("rm -rf {}", mine.display()), &root, &created), None);
        assert_eq!(bash("rm -rf target", &root, &none), None);
        assert_eq!(bash(&format!("rm -rf {}/target", root.display()), &root, &none), None);
        // Everything else is.
        for cmd in [
            format!("rm -rf {}", theirs.display()),
            format!("rm -rf {}", mine.display()), // without provenance
            "rm -rf ~/Documents".to_string(),
            "rm -rf /".to_string(),
            "rm -rf ..".to_string(),
            format!("rm -rf {}", root.display()),
            "sudo rm -r /usr/local/x".to_string(),
            "rm -rf $DIR".to_string(),
            "ls | xargs rm".to_string(),
            "find ~/x -name '*.o' -delete".to_string(),
            "rm -rf /private/tmp/*".to_string(),
        ] {
            assert_eq!(
                bash(&cmd, &root, &none),
                Some("deletes outside the session's scratch"),
                "{cmd}"
            );
        }
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::remove_dir_all(&theirs);
        let _ = std::fs::remove_dir_all(&mine);
    }

    #[test]
    fn force_pushes_deploys_posts_and_credentials_are_hard() {
        let root = Path::new("/work/proj");
        let none = HashSet::new();
        for (cmd, why) in [
            ("git push --force origin main", "force-pushes or rewrites a remote"),
            ("git push -f", "force-pushes or rewrites a remote"),
            ("git push origin +main", "force-pushes or rewrites a remote"),
            ("git push --force-with-lease", "force-pushes or rewrites a remote"),
            ("wrangler deploy", "deploys to production"),
            ("vercel deploy --prod", "deploys to production"),
            ("npm publish", "posts or messages people"),
            ("gh pr comment 3 --body hi", "posts or messages people"),
            ("cat ~/.ssh/id_ed25519", "touches credentials"),
            ("security find-generic-password -s x -w", "touches credentials"),
        ] {
            assert_eq!(bash(cmd, root, &none), Some(why), "{cmd}");
        }
        for cmd in ["git push origin frog/x", "wrangler deploy --dry-run", "cargo build", "ssh pod uptime"] {
            assert_eq!(bash(cmd, root, &none), None, "{cmd}");
        }
    }

    #[test]
    fn soft_classes_follow_the_shape_and_the_config() {
        use crate::config::{Config, McpTrust};
        let root = std::env::temp_dir().join(format!("deleg-soft-root-{}", crate::session::new_id()));
        let mine = std::env::temp_dir().join(format!("deleg-soft-mine-{}", crate::session::new_id()));
        std::fs::create_dir_all(&mine).unwrap();
        let created: HashSet<PathBuf> = [normalize(&mine)].into_iter().collect();
        let mut cfg = Config::default();
        let soft = |cmd: &str, cfg: &Config| {
            soft_class("Bash", &json!({ "command": cmd }), &root, &root, &created, cfg)
        };
        assert_eq!(soft("ssh root@pod-1 uptime", &cfg), Some("ssh-scratch"));
        assert_eq!(soft(&format!("rm -rf {}", mine.display()), &cfg), Some("scratch-deletes"));
        assert_eq!(soft("rm -rf $X", &cfg), None);
        assert_eq!(soft("runpodctl create pod --gpu h200", &cfg), Some("pod-spend"));
        assert_eq!(soft("git push origin frog/x", &cfg), Some("network-read-writes"));
        // MCP writes only on a server granted in `[mcp_trust]`.
        let mcp = |cfg: &Config| soft_class("mcp__runpod__pod-action", &json!({}), &root, &root, &created, cfg);
        assert_eq!(mcp(&cfg), None);
        cfg.mcp_trust.insert("runpod".into(), McpTrust::Write);
        assert_eq!(mcp(&cfg), Some("mcp-write-granted"));
        let _ = std::fs::remove_dir_all(&mine);
    }

    #[test]
    fn mcp_hard_classes_go_by_verb() {
        assert_eq!(hard_mcp("mcp__runpod__delete-pod"), Some("deletes outside the session's scratch"));
        assert_eq!(hard_mcp("mcp__gmail__send-email"), Some("posts or messages people"));
        assert_eq!(hard_mcp("mcp__shop__create-order"), Some("makes a purchase"));
        assert_eq!(hard_mcp("mcp__runpod__create-pod"), None);
        assert_eq!(hard_mcp("mcp__runpod__list-pods"), None);
    }
}

/// The chief's reply, parsed: `Some((allowed, note))` when it says yes or no.
/// Plain text ("approve …" / "deny …") or JSON (`{"decision": "allow"|"deny",
/// "note": …}`). Anything else — silence, chatter, a question — is `None`, and
/// the card falls back to the user.
pub fn parse_reply(reply: &Value) -> Option<(bool, Option<String>)> {
    let text = match reply {
        Value::String(s) => s.clone(),
        Value::Object(o) => {
            let field = |k: &str| o.get(k).and_then(|v| v.as_str()).map(str::trim);
            if let Some(d) = field("decision") {
                let note = field("note").filter(|n| !n.is_empty()).map(String::from);
                return match d.to_ascii_lowercase().as_str() {
                    "allow" | "approve" => Some((true, note)),
                    "deny" | "decline" => Some((false, note)),
                    _ => None,
                };
            }
            field("text")?.to_string()
        }
        _ => return None,
    };
    let lowered = text.trim().to_ascii_lowercase();
    let (yes, cut) = if lowered.starts_with("approve") {
        (true, 7)
    } else if lowered.starts_with("allow") {
        (true, 5)
    } else if lowered.starts_with("deny") {
        (false, 4)
    } else if lowered.starts_with("decline") {
        (false, 7)
    } else {
        return None;
    };
    let note = text
        .trim()
        .get(cut..)
        .map(|n| n.trim().to_string())
        .filter(|n| !n.is_empty());
    Some((yes, note))
}

#[cfg(test)]
mod reply_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn chief_replies_parse_as_text_or_json() {
        assert_eq!(parse_reply(&json!("approve — infra")), Some((true, Some("— infra".into()))));
        assert_eq!(parse_reply(&json!("deny")), Some((false, None)));
        assert_eq!(
            parse_reply(&json!({"decision": "allow", "note": "its own pod"})),
            Some((true, Some("its own pod".into())))
        );
        assert_eq!(parse_reply(&json!({"decision": "deny"})), Some((false, None)));
        assert_eq!(parse_reply(&json!({"decision": "maybe"})), None);
        assert_eq!(parse_reply(&json!("sure, why not?")), None);
        assert_eq!(parse_reply(&Value::Null), None);
    }
}
