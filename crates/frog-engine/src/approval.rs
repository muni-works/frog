//! The approval card: what a permission prompt for a shell command shows so the
//! user can decide in a glance (and a parent session can decide for them): what
//! the command touches, how big it is, whether this session made it, the risk,
//! and frog's recommendation. Also the bookkeeping behind provenance (which
//! paths this session created) and prefix-scoped allows.

use crate::protocol::{ApprovalCard, Touch};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Files counted before a directory's size is reported as "at least".
const SIZE_CAP: usize = 5_000;

/// The program a command runs first, for prefix allows (`rm`, `cargo`, ...).
pub fn program(cmd: &str) -> String {
    words(cmd)
        .into_iter()
        .find(|w| !w.contains('='))
        .unwrap_or_default()
}

/// Shell words, best effort: whitespace split with quotes stripped. Enough to
/// find path arguments; the permission logic itself never relies on it.
fn words(cmd: &str) -> Vec<String> {
    cmd.split(|c: char| c.is_whitespace() || matches!(c, ';' | '|' | '&' | '(' | ')'))
        .map(|w| w.trim_matches(|c| c == '\'' || c == '"' || c == '`'))
        .filter(|w| !w.is_empty())
        .map(String::from)
        .collect()
}

fn expand(word: &str, cwd: &Path) -> PathBuf {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let p = if let Some(rest) = word.strip_prefix("~/") {
        home.join(rest)
    } else if let Some(rest) = word.strip_prefix("$HOME/") {
        home.join(rest)
    } else {
        PathBuf::from(word)
    };
    if p.is_absolute() { p } else { cwd.join(p) }
}

/// One spelling per path, so prefixes and provenance compare the same on every
/// platform: `.` and `..` resolved lexically, then the deepest existing ancestor
/// canonicalized (macOS's `/tmp` is `/private/tmp`, its temp dir sits under
/// `/private/var`) with the not-yet-existing rest appended.
pub fn normalize(p: &Path) -> PathBuf {
    use std::path::Component;
    let mut clean = PathBuf::new();
    for c in p.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir => {
                clean.pop();
            }
            c => clean.push(c),
        }
    }
    let mut rest: Vec<std::ffi::OsString> = Vec::new();
    let mut base = clean.clone();
    loop {
        if let Ok(real) = base.canonicalize() {
            return rest.iter().rev().fold(real, |acc, part| acc.join(part));
        }
        match (base.file_name().map(|n| n.to_os_string()), base.parent()) {
            (Some(name), Some(parent)) => {
                rest.push(name);
                base = parent.to_path_buf();
            }
            _ => return clean,
        }
    }
}

/// Paths a command names: arguments that look like paths (contain `/`, start
/// with `~` or `.`), `VAR=path` assignments, and redirect targets. Flags,
/// globs and URLs are skipped.
pub fn paths(cmd: &str, cwd: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = Vec::new();
    for w in words(cmd) {
        // A redirect's target (`>out`, `2>/dev/null`): the part after the operator.
        let w = w.rsplit(['>', '<']).next().unwrap_or(&w);
        let candidate = match w.split_once('=') {
            Some((name, value)) if !name.is_empty() && !name.starts_with('-') => value,
            _ => w,
        };
        let looks = candidate.contains('/') || candidate.starts_with('~') || candidate == ".";
        if !looks
            || candidate.starts_with('-')
            || candidate.contains("://")
            || candidate.contains(['*', '?', '$'])
                && !candidate.starts_with("$HOME/")
            || candidate == "/dev/null"
        {
            continue;
        }
        let p = normalize(&expand(candidate, cwd));
        if !out.contains(&p) {
            out.push(p);
        }
    }
    out
}

/// Bytes under `p` (a file's size, a directory's total up to `SIZE_CAP` files).
fn size(p: &Path) -> Option<u64> {
    let meta = std::fs::symlink_metadata(p).ok()?;
    if !meta.is_dir() {
        return Some(meta.len());
    }
    let (mut total, mut seen) = (0u64, 0usize);
    let mut stack = vec![p.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for e in entries.flatten() {
            seen += 1;
            if seen > SIZE_CAP {
                return Some(total);
            }
            match e.metadata() {
                Ok(m) if m.is_dir() => stack.push(e.path()),
                Ok(m) => total += m.len(),
                Err(_) => {}
            }
        }
    }
    Some(total)
}

/// Whether this session created `p` or a directory containing it.
pub fn created_here(p: &Path, created: &HashSet<PathBuf>) -> bool {
    p.ancestors().any(|a| created.contains(a))
}

/// Programs that destroy or relocate what already exists: on paths under the
/// shared temp dir these may only touch what this session created.
const DESTRUCTIVE: &[&str] = &["rm", "rmdir", "unlink", "mv", "dd", "truncate"];

/// Whether `p` is in the session's own scope: inside the project, or something
/// this session created, or a fresh path under the shared temp dir. Used for
/// the Write/Edit outside-project check and `own_scope` below.
pub fn path_in_own_scope(p: &Path, root: &Path, created: &HashSet<PathBuf>) -> bool {
    if p.starts_with(root) || created_here(p, created) {
        return true;
    }
    // The shared temp dir is scratch space, but only for *creating*: an
    // existing tree there may belong to another session or the user.
    let temp = normalize(&std::env::temp_dir());
    let in_temp = p.starts_with(&temp) || p.starts_with("/private/tmp") || p.starts_with("/tmp");
    in_temp && !p.exists()
}

/// Whether a command writes only inside the project or the session's own
/// scratch space: every path it names is in-project or session-created, or —
/// under the shared temp dir — fresh, or existing but this session's own,
/// unless a destructive program acts on it (then provenance is required).
/// Credential paths never pass; the caller checks those first.
pub fn own_scope(cmd: &str, cwd: &Path, root: &Path, created: &HashSet<PathBuf>) -> bool {
    let found = paths(cmd, cwd);
    let destructive = destructive_anywhere(cmd);
    if found.is_empty() {
        // No path arguments: it acts where the shell is. Deleting or moving
        // what it can't name never passes.
        return !destructive && normalize(cwd).starts_with(normalize(root));
    }
    found.iter().all(|p| {
        // Deleting or moving needs provenance everywhere, the project included:
        // only what this session made is disposable.
        if destructive {
            return created_here(p, created);
        }
        if p.starts_with(root) {
            return true;
        }
        let temp = normalize(&std::env::temp_dir());
        let in_temp =
            p.starts_with(&temp) || p.starts_with("/private/tmp") || p.starts_with("/tmp");
        // Fresh scratch (a build's own target dir, a log file) or the session's
        // own existing scratch — but a destructive program anywhere in the
        // command needs provenance, not freshness.
        in_temp && (!p.exists() || created_here(p, created))
    })
}

/// Whether any segment of `cmd` runs a destructive program (`&& rm -rf …`
/// sneaks past the first program's check). Unparsable counts as destructive.
fn destructive_anywhere(cmd: &str) -> bool {
    match crate::shell::segments(cmd) {
        Some(segs) => segs.iter().any(|seg| DESTRUCTIVE.contains(&program(seg).as_str())),
        None => true,
    }
}

/// Whether `cmd` is a routine build/test step: every top-level segment is a
/// known build or test tool (with a build/test subcommand), a plain file
/// operation, or a command the read-only parser proves harmless. Anything the
/// path check can't see through (substitutions, heredocs, newlines, URLs,
/// interpreters, installers, network tools) isn't routine. This is what keeps
/// the provenance layer from passing `cd proj && curl -d @f https://…`.
pub fn routine(cmd: &str) -> bool {
    if cmd.contains('\n')
        || cmd.contains("<<")
        || cmd.contains("$(")
        || cmd.contains('`')
        || cmd.contains("://")
    {
        return false;
    }
    let Some(segs) = crate::shell::segments(cmd) else {
        return false;
    };
    !segs.is_empty() && segs.iter().all(|seg| routine_segment(seg))
}

fn routine_segment(seg: &str) -> bool {
    if crate::shell::read_only(seg) {
        return true;
    }
    let ws = words(seg);
    // Skip `VAR=value` assignments, `env` and `timeout N`; `export` of plain
    // assignments is itself routine.
    let mut rest: &[String] = &ws;
    loop {
        match rest.first().map(String::as_str) {
            Some(w) if w.contains('=') && !w.starts_with('-') => rest = &rest[1..],
            Some("export") => return rest.len() > 1 && rest[1..].iter().all(|w| w.contains('=')),
            Some("env") => rest = &rest[1..],
            Some("timeout") if rest.len() > 1 => rest = &rest[2..],
            _ => break,
        }
    }
    let Some(prog) = rest.first().map(String::as_str) else {
        return true; // bare assignments
    };
    let sub = rest.get(1).map(String::as_str).unwrap_or("");
    match prog {
        "cargo" => matches!(
            sub,
            "build" | "test" | "check" | "clippy" | "fmt" | "run" | "bench" | "doc" | "nextest"
        ),
        "xcodebuild" => {
            rest[1..].iter().any(|w| {
                matches!(
                    w.as_str(),
                    "build" | "test" | "test-without-building" | "build-for-testing" | "-list"
                )
            }) && !rest
                .iter()
                .any(|w| matches!(w.as_str(), "archive" | "-exportArchive" | "install"))
        }
        "swift" => matches!(sub, "build" | "test"),
        "xcodegen" => matches!(sub, "generate" | ""),
        "npm" => matches!(sub, "test" | "run" | "run-script")
            || (sub == "run" && rest.get(2).map(String::as_str) == Some("dev"))
            || sub == "start"
            || sub == "dev",
        "cd" | "mkdir" | "touch" | "true" | "cp" | "mv" | "rm" | "tee" => true,
        // A local dev server serving the project: python's http.server binds localhost,
        // and the dev-server subcommands of the JS toolchains do too. Only the module
        // form (no script files, no -c code) and no extra hosts/ports beyond the well-
        // known local flags. Interpreters with scripts, -c code or args stay asking.
        "python3" | "python" => {
            rest.len() == 3 && rest[1] == "-m" && rest[2] == "http.server"
                || (rest.len() == 4 && rest[1] == "-m" && rest[2] == "http.server"
                    && rest[3].chars().all(|c| c.is_ascii_digit()))
        }
        "vite" | "next" | "astro" => {
            matches!(sub, "dev" | "")
                && !rest.iter().any(|w| w.starts_with("--host") && !w.contains("localhost"))
        }
        // In-place edits (an Edit by another name): the script must pass the
        // read-only sed checks (no w/W/e/r commands) once -i is set aside.
        "sed" => {
            let kept: Vec<&String> = rest
                .iter()
                .filter(|w| !w.starts_with("-i") && !w.is_empty())
                .collect();
            !kept.iter().any(|w| w.contains('\''))
                && crate::shell::read_only(
                    &kept.iter().map(|w| format!("'{w}'")).collect::<Vec<_>>().join(" "),
                )
        }
        _ => false,
    }
}

/// Which of a command's paths don't exist yet: checked before it runs, so the
/// ones that exist afterwards were made by it.
pub fn missing(cmd: &str, cwd: &Path) -> Vec<PathBuf> {
    paths(cmd, cwd).into_iter().filter(|p| !p.exists()).collect()
}

/// The longest directory every path sits under (the prefix an `AllowPrefix`
/// covers), from paths already `normalize`d. None when that's too broad to hand
/// out as a scope (see `too_broad`).
pub fn common_prefix(paths: &[PathBuf]) -> Option<PathBuf> {
    let first = paths.first()?;
    let mut prefix: PathBuf = first.clone();
    for p in &paths[1..] {
        while !p.starts_with(&prefix) {
            prefix = prefix.parent()?.to_path_buf();
        }
    }
    (!too_broad(&prefix)).then_some(prefix)
}

/// `/` and top-level dirs (`/usr`, `/home`), the home directory and its parent,
/// and the shared temp roots (`/tmp`, `/private/tmp`, `/var/tmp`, the OS temp
/// dir) or anything above them. A directory *inside* one of those is specific
/// enough: `/tmp/frog-build` is a scope, `/tmp` isn't.
pub fn too_broad(prefix: &Path) -> bool {
    if prefix.components().count() <= 2 {
        return true;
    }
    let mut shared: Vec<PathBuf> = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"]
        .iter()
        .map(PathBuf::from)
        .collect();
    shared.push(std::env::temp_dir());
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        shared.push(home);
    }
    shared
        .iter()
        .flat_map(|s| [s.clone(), normalize(s)])
        .any(|s| s.starts_with(prefix))
}

fn human(bytes: u64) -> String {
    match bytes {
        b if b >= 1 << 30 => format!("{:.1} GB", b as f64 / (1u64 << 30) as f64),
        b if b >= 1 << 20 => format!("{:.1} MB", b as f64 / (1u64 << 20) as f64),
        b if b >= 1 << 10 => format!("{:.1} KB", b as f64 / 1024.0),
        b => format!("{b} B"),
    }
}

/// Build the card for a shell command that's about to ask.
pub fn card(
    cmd: &str,
    cwd: &Path,
    root: &Path,
    trigger: &str,
    agent_reason: Option<String>,
    created: &HashSet<PathBuf>,
    timeout_secs: u64,
) -> ApprovalCard {
    let found = paths(cmd, cwd);
    let touches: Vec<Touch> = found
        .iter()
        .map(|p| {
            let meta = std::fs::symlink_metadata(p).ok();
            Touch {
                path: p.display().to_string(),
                exists: meta.is_some(),
                dir: meta.as_ref().is_some_and(|m| m.is_dir()),
                bytes: meta.is_some().then(|| size(p)).flatten(),
                created_here: created_here(p, created),
            }
        })
        .collect();
    let prog = program(cmd);
    let deletes = matches!(prog.as_str(), "rm" | "rmdir" | "unlink")
        || cmd.contains(" -delete")
        || cmd.contains("git clean");
    let existing: Vec<&Touch> = touches.iter().filter(|t| t.exists).collect();
    let all_ours = !existing.is_empty() && existing.iter().all(|t| t.created_here);
    let outside = found
        .iter()
        .any(|p| !p.starts_with(root) && !p.starts_with("/private/tmp") && !p.starts_with("/tmp"));
    let creds = crate::shell::touches_credentials(cmd);
    let total: u64 = existing.iter().filter_map(|t| t.bytes).sum();
    let (risk, recommendation) = if creds {
        (
            "reads or writes credentials".to_string(),
            "deny: credentials shouldn't pass through the agent".to_string(),
        )
    } else if deletes && existing.is_empty() {
        (
            "deletes paths that don't exist; nothing to lose".to_string(),
            "allow: a no-op".to_string(),
        )
    } else if deletes && all_ours {
        (
            format!(
                "deletes {} ({}) that this session created",
                plural(existing.len(), "path"),
                human(total)
            ),
            "allow: cleaning up its own output".to_string(),
        )
    } else if deletes {
        (
            format!(
                "deletes {} ({}) this session didn't create",
                plural(existing.len(), "path"),
                human(total)
            ),
            "deny unless you know these are disposable".to_string(),
        )
    } else if outside {
        (
            "acts on paths outside the project".to_string(),
            "deny unless the task needs those paths".to_string(),
        )
    } else {
        (
            "runs a command frog can't prove harmless".to_string(),
            "allow if it matches what you asked for".to_string(),
        )
    };
    ApprovalCard {
        agent_reason,
        trigger: trigger.to_string(),
        prefix: common_prefix(&found).map(|p| p.display().to_string()),
        touches,
        risk,
        recommendation,
        timeout_secs,
    }
}

fn plural(n: usize, word: &str) -> String {
    if n == 1 { format!("1 {word}") } else { format!("{n} {word}s") }
}

/// Whether every path `cmd` names sits under a prefix the user allowed for
/// `cmd`'s program this session. A command naming no paths never matches.
pub fn prefix_allows(cmd: &str, cwd: &Path, allowed: &[(String, PathBuf)]) -> bool {
    let prog = program(cmd);
    let found = paths(cmd, cwd);
    !found.is_empty()
        && found.iter().all(|p| {
            allowed
                .iter()
                .any(|(program, prefix)| *program == prog && p.starts_with(prefix))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp() -> PathBuf {
        let d = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("frog-approval-{}", crate::session::new_id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn finds_paths_and_skips_flags_urls_and_globs() {
        let cwd = Path::new("/work/proj");
        let found = paths(
            "CARGO_TARGET_DIR=/private/tmp/t cargo build -p x && rm -rf ./out /private/tmp/old 2>/dev/null; curl https://a.b/c; ls *.rs",
            cwd,
        );
        assert_eq!(
            found,
            vec![
                PathBuf::from("/private/tmp/t"),
                PathBuf::from("/work/proj/./out"),
                PathBuf::from("/private/tmp/old"),
            ]
        );
        assert_eq!(program("FOO=1 rm -rf x"), "rm");
    }

    #[test]
    fn own_scope_covers_the_project_and_own_scratch_only() {
        let (root, cwd) = (Path::new("/work/proj"), Path::new("/work/proj"));
        let own = tmp(); // a real dir this "session" made
        let created: HashSet<PathBuf> = [own.clone()].into();
        // In-project and session-created paths pass.
        // No path arguments: it acts in the shell's cwd, in or out of the project.
        assert!(own_scope("cargo build", cwd, root, &created));
        assert!(!own_scope("cargo build", Path::new("/work/elsewhere"), root, &created));
        assert!(own_scope("touch src/a.rs", cwd, root, &created));
        // Deleting in the project needs provenance too.
        assert!(!own_scope("rm -rf src", cwd, root, &created));
        assert!(!own_scope("mv src/a.rs src/b.rs", cwd, root, &created));
        assert!(own_scope(
            &format!("rm -rf {}", own.display()),
            cwd,
            root,
            &created
        ));
        // Fresh scratch under /private/tmp (a build's own target dir): passes.
        let fresh = "/private/tmp/skittish-fresh-target";
        assert!(own_scope(
            &format!("CARGO_TARGET_DIR={fresh} cargo test"),
            cwd,
            root,
            &created
        ));
        // An existing scratch tree it didn't create: doesn't pass…
        std::fs::create_dir_all("/private/tmp/skittish-not-ours").unwrap();
        assert!(!own_scope(
            "ls /private/tmp/skittish-not-ours && echo hi > /private/tmp/skittish-not-ours/x",
            cwd,
            root,
            &created
        ));
        // …and a destructive program there needs provenance even if fresh-ish.
        assert!(!own_scope("rm -rf /private/tmp/skittish-not-ours", cwd, root, &created));
        let _ = std::fs::remove_dir_all("/private/tmp/skittish-not-ours");
        let _ = std::fs::remove_dir_all(own);
        // Write/Edit: a fresh temp file is ours; an existing one we didn't make isn't.
        assert!(path_in_own_scope(Path::new("/private/tmp/skittish-fresh/f.log"), root, &created));
        std::fs::create_dir_all("/private/tmp/skittish-theirs").unwrap();
        assert!(!path_in_own_scope(Path::new("/private/tmp/skittish-theirs"), root, &created));
        let _ = std::fs::remove_dir_all("/private/tmp/skittish-theirs");
        assert!(!path_in_own_scope(Path::new("/Users/cam/.zshrc"), root, &created));
        // Outside everywhere: never passes.
        assert!(!own_scope("cat > /etc/motd", cwd, root, &created));
        // Credential paths are the caller's hard check, but don't pass here either.
        assert!(!own_scope("cat ~/.ssh/id_rsa", cwd, root, &created));
    }

    #[test]
    fn provenance_marks_what_this_session_made() {
        let dir = tmp();
        let made = dir.join("build");
        std::fs::create_dir_all(made.join("sub")).unwrap();
        std::fs::write(made.join("sub/a.bin"), vec![0u8; 2048]).unwrap();
        let theirs = dir.join("theirs");
        std::fs::create_dir_all(&theirs).unwrap();
        let created: HashSet<PathBuf> = [made.clone()].into();
        // Our own build output: deleting it is recommended.
        let ours = card(
            &format!("rm -rf {}", made.display()),
            &dir,
            &dir,
            "leaves the sandbox",
            Some("cleaning up".into()),
            &created,
            600,
        );
        assert!(ours.touches[0].created_here && ours.touches[0].dir);
        assert_eq!(ours.touches[0].bytes, Some(2048));
        assert!(ours.risk.contains("this session created"), "{}", ours.risk);
        assert!(ours.recommendation.starts_with("allow"));
        assert_eq!(ours.agent_reason.as_deref(), Some("cleaning up"));
        // Someone else's: deny is recommended.
        let other = card(
            &format!("rm -rf {}", theirs.display()),
            &dir,
            &dir,
            "rule",
            None,
            &created,
            600,
        );
        assert!(!other.touches[0].created_here);
        assert!(other.risk.contains("didn't create"), "{}", other.risk);
        assert!(other.recommendation.starts_with("deny"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn relative_paths_follow_the_shell_but_the_project_is_the_root() {
        // Fixed paths (no temp dir: Linux's is /tmp, which `card` never calls outside).
        let (root, sub) = (Path::new("/frog-test/proj"), Path::new("/frog-test/proj/sub"));
        // The shell has `cd`'d into sub: `../notes.txt` is the root's file, inside the project.
        let inside = card("touch ../notes.txt", sub, root, "rule", None, &HashSet::new(), 600);
        assert_eq!(inside.touches[0].path, "/frog-test/proj/notes.txt");
        assert!(!inside.risk.contains("outside"), "{}", inside.risk);
        // Climbing above the root is outside, wherever the shell is.
        let outside = card("touch ../../elsewhere", sub, root, "rule", None, &HashSet::new(), 600);
        assert_eq!(outside.touches[0].path, "/frog-test/elsewhere");
        assert!(outside.risk.contains("outside the project"), "{}", outside.risk);
    }

    #[test]
    fn prefix_allows_only_the_same_program_under_the_prefix() {
        let cwd = Path::new("/work");
        let allowed = vec![("rm".to_string(), PathBuf::from("/private/tmp/frog-x"))];
        assert!(prefix_allows("rm -rf /private/tmp/frog-x/target", cwd, &allowed));
        assert!(prefix_allows("rm -rf /private/tmp/frog-x/a /private/tmp/frog-x/b", cwd, &allowed));
        // Another path, another program, or no path at all: not covered.
        assert!(!prefix_allows("rm -rf /private/tmp/frog-x/a /private/tmp/other", cwd, &allowed));
        assert!(!prefix_allows("mv /private/tmp/frog-x/a /private/tmp/frog-x/b", cwd, &allowed));
        assert!(!prefix_allows("rm -rf", cwd, &allowed));
    }

    #[test]
    fn common_prefix_is_never_too_broad() {
        let p = |s: &str| PathBuf::from(s);
        assert_eq!(
            common_prefix(&[p("/private/tmp/frog-x/a"), p("/private/tmp/frog-x/b/c")]),
            Some(p("/private/tmp/frog-x"))
        );
        // Linux's temp dirs are shallow (`/tmp/frog-x`): still a fine scope.
        assert_eq!(
            common_prefix(&[p("/tmp/frog-x/a"), p("/tmp/frog-x/b")]),
            Some(p("/tmp/frog-x"))
        );
        // The shared roots themselves, `/`, top-level dirs and home are not.
        for broad in ["/tmp", "/private/tmp", "/var/tmp", "/", "/usr"] {
            assert!(too_broad(Path::new(broad)), "{broad}");
            assert_eq!(common_prefix(&[p(&format!("{broad}/a")), p(&format!("{broad}/b"))]), None, "{broad}");
        }
        assert!(too_broad(&std::env::temp_dir()));
        if let Some(home) = std::env::var_os("HOME") {
            assert!(too_broad(Path::new(&home)));
        }
        assert_eq!(common_prefix(&[p("/private/tmp/a"), p("/usr/b")]), None);
        assert_eq!(common_prefix(&[]), None);
    }

    #[test]
    fn paths_compare_the_same_however_they_are_spelled() {
        let dir = tmp();
        let canon = dir.canonicalize().unwrap();
        // `.`/`..`, and (on macOS) `/tmp` vs `/private/tmp`, all land on one spelling.
        let wobbly = format!("{}/./x/../y/new-file", dir.display());
        assert_eq!(normalize(Path::new(&wobbly)), canon.join("y/new-file"));
        assert_eq!(normalize(Path::new("/tmp/frog-none/z")), Path::new("/tmp").canonicalize().unwrap().join("frog-none/z"));
        let _ = std::fs::remove_dir_all(dir);
    }
}
