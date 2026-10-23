//! A small shell parser that decides whether a command is *read-only*: it can't
//! write files, run arbitrary subshells, or mutate anything, so every permission
//! mode except "ask for everything" may run it without a prompt.
//!
//! The parser splits a command on `&&`, `||`, `;` and `|` with real shell quoting
//! (a `;` inside quotes is just a character), then checks every segment:
//! the program must be on a read-only allowlist with only safe arguments.
//! Anything the parser can't fully understand — command substitution, backticks,
//! process substitution, heredocs, redirects to anywhere but `/dev/null`,
//! `2>&1` and `2>/dev/null` — is rejected, and the caller falls back to asking.
//! Writes, network and unknown programs keep their normal behavior.
//!
//! This is a permission fast path, not a sandbox: it answers "may this run
//! without asking", and a wrong answer only means an unnecessary prompt or a
//! read-only command running unattended. It must never say yes to a write.

/// The command's top-level segments (`&&`/`;`/`|` split, quotes honored), for
/// callers that check each segment separately. `None` means unparsable
/// (subshells, backticks, a lone `&`, unbalanced quotes).
pub fn segments(cmd: &str) -> Option<Vec<String>> {
    split_top(cmd)
}

/// Whether `cmd` is read-only: every segment is a read-only program with safe
/// arguments, and any redirection goes to `/dev/null` (or `2>&1`).
pub fn read_only(cmd: &str) -> bool {
    if touches_credentials(cmd) {
        return false; // credential reads always ask, even when read-only
    }
    if cmd.contains('\n') {
        // A newline is a separator we don't model (except inside quotes, which
        // `segments` handles); treat the whole command as opaque.
        // Also covers heredocs, which we reject outright.
        return false;
    }
    if cmd.contains("<<") {
        return false; // heredoc
    }
    let Some(parts) = split_top(cmd) else {
        return false;
    };
    if parts.is_empty() {
        return false;
    }
    parts.iter().all(|p| segment_read_only(p))
}

/// Split on `&&`, `||`, `;`, `|` at the top level (outside quotes). `None` when
/// the string has unbalanced quotes or other syntax we don't parse.
fn split_top(cmd: &str) -> Option<Vec<String>> {
    let mut parts = Vec::new();
    let mut cur = String::new();
    let mut chars = cmd.chars().peekable();
    let mut quote: Option<char> = None; // ' or "
    while let Some(c) = chars.next() {
        match quote {
            Some(q) => {
                cur.push(c);
                if c == q {
                    quote = None;
                } else if c == '\\' && q == '"' {
                    // Backslash escapes the next char inside double quotes.
                    if let Some(n) = chars.next() {
                        cur.push(n);
                    }
                }
            }
            None => match c {
                '\'' | '"' => {
                    quote = Some(c);
                    cur.push(c);
                }
                '\\' => {
                    // Escaped character: keep both, it can't be a separator.
                    cur.push(c);
                    if let Some(n) = chars.next() {
                        cur.push(n);
                    }
                }
                '&' => {
                    if chars.peek() == Some(&'&') {
                        chars.next();
                        parts.push(take(&mut cur));
                    } else if cur.ends_with('>') {
                        // `>&1` fd dup inside a redirect (`2>&1`): not a
                        // background operator. Keep it; parse_segment checks it.
                        cur.push(c);
                    } else {
                        return None; // single & (background) — not modeled
                    }
                }
                '|' => {
                    if chars.peek() == Some(&'|') {
                        chars.next();
                    }
                    parts.push(take(&mut cur));
                }
                ';' => parts.push(take(&mut cur)),
                '(' | ')' => return None, // subshell / process substitution
                '`' => return None,       // backticks
                _ => cur.push(c),
            },
        }
    }
    if quote.is_some() {
        return None; // unbalanced quote
    }
    parts.push(take(&mut cur));
    Some(parts.into_iter().filter(|p| !p.trim().is_empty()).collect())
}

fn take(cur: &mut String) -> String {
    std::mem::take(cur).trim().to_string()
}

/// Shell-split one segment into words with quotes resolved, plus the
/// redirections it contains. `None` when anything unparsable appears.
struct Segment {
    words: Vec<String>,
    /// Redirection targets seen: each must be /dev/null (2>&1 has no target).
    redirects: usize,
}

fn parse_segment(seg: &str) -> Option<Segment> {
    let mut words = Vec::new();
    let mut cur = String::new();
    let mut has_word = false;
    let mut redirects = 0;
    let mut chars = seg.chars().peekable();
    let mut quote: Option<char> = None;
    while let Some(c) = chars.next() {
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                } else {
                    if c == '\\' && q == '"' {
                        if let Some(n) = chars.next() {
                            cur.push(n);
                        }
                        continue;
                    }
                    cur.push(c);
                }
            }
            None => match c {
                '\'' | '"' => {
                    quote = Some(c);
                    has_word = true; // "" is a word
                }
                '\\' => match chars.next() {
                    Some(n) => {
                        cur.push(n);
                        has_word = true;
                    }
                    None => return None, // trailing backslash
                },
                ' ' | '\t' => {
                    if has_word {
                        words.push(std::mem::take(&mut cur));
                        has_word = false;
                    }
                }
                '>' => {
                    if chars.peek() == Some(&'(') {
                        return None; // >( ) process substitution
                    }
                    if chars.peek() == Some(&'>') {
                        chars.next(); // >> appending redirect — target still checked
                    }
                    if has_word {
                        words.push(std::mem::take(&mut cur));
                        has_word = false;
                    }
                    // 2>&1: the &1 fd dup — allowed.
                    if chars.peek() == Some(&'&') {
                        chars.next();
                        match chars.next() {
                            Some('1') => continue, // 2>&1 — fine
                            Some('2') => continue, // >&2 — writes to stderr, fine
                            _ => return None,
                        }
                    }
                    redirects += 1;
                    // The target word must be /dev/null.
                    while matches!(chars.peek(), Some(' ') | Some('\t')) {
                        chars.next();
                    }
                    let mut target = String::new();
                    while let Some(&n) = chars.peek() {
                        if n == ' ' || n == '\t' {
                            break;
                        }
                        target.push(n);
                        chars.next();
                    }
                    if target != "/dev/null" {
                        return None;
                    }
                }
                '<' => {
                    if chars.peek() == Some(&'(') {
                        return None; // <( ) process substitution
                    }
                    if chars.peek() == Some(&'<') {
                        return None; // heredoc (also caught above)
                    }
                    if chars.peek() == Some(&'>') {
                        return None; // <> open for read/write
                    }
                    if has_word {
                        words.push(std::mem::take(&mut cur));
                        has_word = false;
                    }
                    // Input redirect: reading from a file is read-only; the
                    // target just becomes a word we don't check further.
                    let _target = collect_word(&mut chars);
                }
                '$' => {
                    if chars.peek() == Some(&'(') {
                        return None; // $( ) command substitution
                    }
                    // A variable expansion becomes its own word. It can't be the
                    // program (the allowlist only matches literal names), and as
                    // an argument it is inert: shell word-splitting doesn't
                    // re-interpret operators inside expanded values.
                    if has_word {
                        words.push(std::mem::take(&mut cur));
                    }
                    words.push(format!("${}", collect_word(&mut chars)));
                    has_word = false;
                }
                '(' | ')' | '`' => return None,
                _ => {
                    cur.push(c);
                    has_word = true;
                }
            },
        }
    }
    if quote.is_some() {
        return None;
    }
    if has_word {
        words.push(cur);
    }
    (words.first().is_some()).then_some(Segment { words, redirects })
}

fn collect_word(chars: &mut std::iter::Peekable<std::str::Chars>) -> String {
    let mut w = String::new();
    while let Some(&c) = chars.peek() {
        if c == ' ' || c == '\t' {
            break;
        }
        w.push(c);
        chars.next();
    }
    w
}

/// Whether one parsed segment is read-only.
fn segment_read_only(seg: &str) -> bool {
    let Some(Segment { words, redirects }) = parse_segment(seg) else {
        return false;
    };
    if redirects > 0 && words.is_empty() {
        return false;
    }
    let Some(program) = words.first().cloned() else {
        return false;
    };
    let args = &words[1..];
    let _ = redirects; // targets were validated during parsing
    match program.as_str() {
        "cd" => args.len() <= 1,
        "pwd" => true,
        "df" => args.iter().all(|a| a.starts_with('-') || a.starts_with('/')),
        "ls" | "cat" | "head" | "tail" | "wc" | "stat" | "du" | "file" | "which" | "echo"
        | "jq" | "sort" | "uniq" | "cut" | "tr" | "tree" => true,
        // Process inspection reads only: ps lists processes; sample samples a
        // live process's stacks to stdout. `sample`'s numeric args are pids and
        // durations; anything else (an output file, `-file`) is not allowed.
        "ps" => args
            .iter()
            .all(|a| a.starts_with('-') || a.contains(',') || a.chars().all(|c| c.is_ascii_digit())),
        // pgrep only lists (pkill is the one that signals).
        "pgrep" => true,
        // Read-only Xcode lookups; xcrun itself runs any tool, so only these.
        "xcrun" => matches!(
            (args.first().map(String::as_str), args.get(1).map(String::as_str)),
            (Some("xcresulttool"), Some("get")) | (Some("simctl"), Some("list"))
        ),
        "sample" => args.iter().all(|a| {
            a.starts_with('-') && !a.starts_with("-file")
                || a.chars().next().is_some_and(|c| c.is_ascii_digit())
        }),
        // Reads like cat: absolute paths are fine (credential paths were
        // rejected above), and -f only reads patterns from a file.
        "grep" | "rg" => true,
        "find" => {
            // No -exec/-execdir/-delete/-fprint*/-ok: those act on what they find.
            let mut i = 0;
            while i < args.len() {
                let a = args[i].as_str();
                if a == "-exec" || a == "-execdir" || a == "-delete" || a == "-ok" {
                    return false;
                }
                if a.starts_with("-fprint") {
                    return false;
                }
                // An expression word after -newer/-name etc. is fine.
                i += 1;
            }
            true
        }
        "awk" => {
            // No system(), no print > file, no | command, no "cmd" | getline.
            let script = args
                .iter()
                .find(|a| !a.starts_with('-'))
                .cloned()
                .unwrap_or_default();
            // getline fed from a command (`"cmd" | getline`), system(), and
            // `print > "file"`: all run or write something.
            let joined = args.join(" ");
            if joined.contains("system(") || joined.contains("| getline") || joined.contains("\" |") {
                return false;
            }
            if script.contains('>') && script.contains("print") {
                return false;
            }
            if script.contains("getline") && (script.contains('|') || script.contains('"')) {
                return false;
            }
            !script.contains("system(")
        }
        "sed" => {
            // Printing and filtering only: no -i (in-place), and no script that
            // writes or executes (the `w`/`W`/`e`/`r` commands, or an s-command
            // flagging them, like s/a/b/w file).
            let script_idx = args.iter().position(|a| !a.starts_with('-'));
            let Some(idx) = script_idx else { return false };
            let script = &args[idx];
            if args[..idx].iter().any(|a| a.starts_with("-i")) {
                return false;
            }
            for cmd in script.split(';').chain(script.split('\n')) {
                let cmd = cmd.trim();
                if cmd.is_empty() || cmd.starts_with('#') {
                    continue;
                }
                // A bare write/exec/read-file command: `w f`, `e cmd`, `r f`, `W f`.
                if cmd
                    .split_whitespace()
                    .next()
                    .is_some_and(|w| matches!(w, "w" | "W" | "e" | "r" | "R"))
                {
                    return false;
                }
                // An s-command's flags: s/…/…/wge — reject w/W/e among them.
                if let Some(rest) = cmd.strip_prefix('s') {
                    if let Some(flags) = rest.rsplit('/').next() {
                        if flags.contains(['w', 'W', 'e']) {
                            return false;
                        }
                    }
                }
            }
            true
        }
        "git" => {
            // Listing subcommands only; no -d/-D/-m/-c on branch.
            let Some(sub) = args.first() else {
                return false;
            };
            match sub.as_str() {
                "status" | "log" | "diff" | "show" | "blame" | "rev-parse" | "ls-files"
                | "merge-base" | "rev-list" => true,
                "branch" => args.iter().skip(1).all(|a| {
                    !a.starts_with("-d")
                        && !a.starts_with("-D")
                        && !a.starts_with("-m")
                        && !a.starts_with("-c")
                        && !a.starts_with("--edit")
                        && !a.starts_with("--set-upstream-to")
                }),
                "remote" => args.len() <= 2 && (args.len() < 2 || args[1] == "-v"),
                "worktree" => args.len() >= 2 && args[1] == "list",
                _ => false,
            }
        }
        _ => false,
    }
}

/// Credential locations a command must not touch (read or write) without asking:
/// reading any of these can hand a secret to the model or exfiltrate it.
const CREDENTIALS: &[&str] = &[
    "~/.ssh",
    "~/.aws",
    "~/.gnupg",
    "~/.netrc",
    ".netrc",
    "~/.config/gcloud",
    "keychain",
    "security find-generic-password",
    "security find-internet-password",
    "security dump-keychain",
    ".env",
    "credentials.json",
    "service-account",
    "~/.wrangler",
    "~/.config/wrangler",
    "~/.gh",
    "~/.config/gh",
    "id_rsa",
    "id_ed25519",
    "authorized_keys",
];

/// Environment variable names that hold secrets.
const SECRET_ENV: &[&str] = &[
    "aws_secret_access_key",
    "aws_session_token",
    "api_key",
    "apikey",
    "secret_key",
    "access_token",
    "auth_token",
    "private_key",
    "gcp_service_account",
];

/// Whether the command mentions a credential path or a keychain read. Checked
/// against the raw command (so it also flags what the parser can't parse), with
/// `~` and `$HOME` forms both matched. False positives are fine: they only ask.
pub fn touches_credentials(cmd: &str) -> bool {
    let lowered = cmd.to_lowercase();
    if CREDENTIALS.iter().any(|c| {
        if *c == ".env" {
            // A file mention, not the word "environment".
            lowered.contains(".env") && !lowered.contains("environment")
        } else {
            lowered.contains(c)
        }
    }) {
        return true;
    }
    SECRET_ENV.iter().any(|v| lowered.contains(v))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_read_only_compounds() {
        for ok in [
            "ls",
            "ls -la src",
            "pwd",
            "cat file.txt",
            "ls \"a;b\"",
            "ls 'a|b'",
            "ls | head -5",
            "head -20 apps/macos/project.yml",
            "cd /x && git log --oneline | head",
            "cd ~/Developer/frog && ls",
            "git status",
            "git log --oneline -5",
            "git diff HEAD~1",
            "git show abc123",
            "git branch",
            "git branch --list 'frog/*'",
            "git remote -v",
            "git rev-parse --show-toplevel",
            "git ls-files",
            "git merge-base main HEAD",
            "git rev-list --count HEAD ^origin/main",
            "git worktree list",
            "df -g / | tail -1",
            "du -sh .",
            "stat Cargo.toml",
            "file /usr/bin/sandbox-exec",
            "which git",
            "echo hello world",
            "echo $HOME",
            "jq '.name' package.json",
            "sort names.txt | uniq -c",
            "cut -d, -f1 data.csv",
            "tr a-z A-Z < in.txt",
            "awk '{print $1}' data.tsv",
            "awk -F: '{print $1}' /etc/passwd",
            "awk '$0 ~ /x/ {print}' f",
            "sed -n '250,270p' crates/frog-engine/src/config.rs",
            "grep -rn TODO src",
            "rg 'fn main' crates",
            "find . -name '*.rs'",
            "find . -maxdepth 2 -type d",
            "grep pattern file 2>/dev/null",
            "make -n target 2>&1", // make isn't allowed — this must FAIL. see below
            "ls > /dev/null",
            "ls 2>&1",
            "cmd 2>&1 | head", // cmd not allowed — fails on program
            "cd somedir && ls -la",
            "echo a; echo b",
            "echo a || echo b",
            "cat a && cat b",
            "grep -E 'error:|^\\*\\* BUILD' /tmp/build.log",
            "grep -ciE 'main thread checker' /private/tmp/crash.log",
            "ps -eo pid,etime,%cpu,command | grep Frog | head",
            "ps -p 97435 -o pid,etime,%cpu,command",
            "pgrep -lf Frog.app",
            "sample 58930 1 -mayDie 2>/dev/null | head -40",
            "xcrun xcresulttool get test-results tests --path /private/tmp/dd/x.xcresult",
            "xcrun simctl list devices",
        ] {
            if ok.starts_with("make ") || ok.starts_with("cmd ") {
                assert!(!read_only(ok), "{ok} should NOT be allowed");
            } else {
                assert!(read_only(ok), "{ok} should be allowed");
            }
        }
    }

    #[test]
    fn rejects_writes_substitutions_and_unknowns() {
        for bad in [
            "cat x > y",
            "echo $(rm -rf x)",
            "echo `rm -rf x`",
            "find . -delete",
            "find . -exec rm {} \\;",
            "find . -execdir wc {} \\;",
            "find . -fprint /tmp/out",
            "sed -i s/a/b/ f",
            "sed -i 's/a/b/' f",
            "awk '{system(\"x\")}'",
            "awk '{print > \"out\"}'",
            "awk '{ \"cmd\" | getline }'",
            "git branch -D x",
            "git branch -d x",
            "git branch -m new",
            "git commit -m x",
            "git checkout main",
            "git push origin main",
            "git fetch origin main",
            "git pull",
            "cargo test",
            "npm install",
            "ls && rm -rf /",
            "echo hi > file.txt",
            "echo hi >> file.txt",
            "cat < <(echo hi)",
            "wc > >(count)",
            "bash -c 'ls'",
            "sh script.sh",
            "rm -rf target",
            "touch file",
            "mkdir dir",
            "printf 'x' > f",
            "ls; rm -rf /",
            "ls | tee out.txt",
            "ls | sort > out.txt",
            "echo unbalanced 'quote",
            "echo \"unterminated",
            "tr a-z A-Z <<EOF\nhi\nEOF",
            "git log --oneline | head &",
            "cat a | bash",
            "dd if=/dev/zero of=f",
            "cd x && git log | sh",
            "ls | xargs rm",
            "sample 58930 1 -file /private/tmp/out.txt",
            "sample Frog -file out.txt",
            "xcrun swift build",
            "xcrun simctl erase all",
            "xcrun xcresulttool export --path x",
            "grep x ~/.ssh/config",
            // credential reads ask even though they'd otherwise be read-only
            "cat ~/.ssh/id_rsa",
            "ls ~/.aws",
            "cat .env",
            "grep key ~/.config/gh/hosts.yml",
            "security find-generic-password -s x",
            "cat ~/project/.env.local",
        ] {
            assert!(!read_only(bad), "{bad} should be rejected");
        }
    }

    #[test]
    fn credential_mentions_flag_even_unparsable_commands() {
        for cmd in [
            "cat ~/.ssh/id_rsa",
            "ls -la ~/.gnupg",
            "awk '{print}' ~/.netrc",
            "tar czf backup.tgz ~/.aws",
            "security dump-keychain",
            "printenv AWS_SECRET_ACCESS_KEY > x",
            "cat staging.env",
        ] {
            assert!(touches_credentials(cmd), "{cmd} should flag credentials");
        }
        // Ordinary paths and the word "environment" don't.
        for cmd in [
            "ls src",
            "cat config.toml",
            "echo $HOME",
            "git log --oneline | head -3",
            "grep -rn environment src",
            "df -g /",
        ] {
            assert!(!touches_credentials(cmd), "{cmd} flagged spuriously");
        }
    }

    #[test]
    fn sed_writes_and_executions_are_rejected() {
        for ok in [
            "sed -n '250,270p' crates/frog-engine/src/config.rs",
            "sed -n 1,5p file",
            "sed 's/a/b/' f",
            "sed 's/a/b/g; 3d' f",
        ] {
            assert!(read_only(ok), "{ok} should be allowed");
        }
        for bad in [
            "sed -i s/a/b/ f",
            "sed -i '' 's/a/b/' f",
            "sed 's/a/b/w out.txt' f",
            "sed 'w out.txt' f",
            "sed 'e whoami' f",
            "sed 'r secret.txt' f",
        ] {
            assert!(!read_only(bad), "{bad} should be rejected");
        }
    }

    #[test]
    fn quoting_traps() {
        // ; inside quotes is not a separator
        assert!(read_only("ls \"a;b\""));
        assert!(read_only("cat 'file;with;semicolons'"));
        assert!(read_only("echo 'a && b'"));
        assert!(read_only("grep \"a|b\" file"));
        // but the same quotes around a program can't smuggle one
        assert!(!read_only("'rm' -rf /"));
        assert!(!read_only("\"rm\" -rf x"));
        // redirect hidden in quotes is not a redirect
        assert!(read_only("echo 'a > b'"));
        assert!(read_only("echo \"a > b\""));
        // unquoted redirects are
        assert!(!read_only("echo a > b"));
    }
}
