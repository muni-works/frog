//! Questions that outlive one session: the ledger of what was asked and what was answered,
//! and the tree rule that makes one question the whole tree's question.
//!
//! `Ask` is session-local by construction — the engine emits [`Event::Question`], one client
//! answers with [`Op::Answer`], and nothing else ever hears of it. That is fine for one
//! conversation and wrong for a tree of them: a manager and its worker both ask the user the
//! same thing, two cards open, the user answers one, and the other hangs. The failure this
//! module exists for: the user answered a *different* card in the same session (a free-form
//! reply that read as an answer to something else), the structured question silently closed,
//! and neither the asking session nor its parent could tell it had never been answered.
//!
//! So there are two pieces of state, and they are not the same thing:
//!
//! - **Open** — a question a client is showing right now. Live state, owned by the client
//!   (`Conversation.question` on the Mac, `Shared::questions` in the engine).
//! - **Answered** — a record of what the user actually chose. Durable, owned by this ledger,
//!   written once when an answer lands and never rewritten.
//!
//! Only an answer with a real choice or real words is an answer. A dismissal — the card closed,
//! the turn interrupted, an empty `Answer` — records **nothing** as an answer, so "never
//! answered" stays distinguishable from "answered" forever, across a restart and across every
//! session in the tree. That is requirement 5. It is enforced twice on purpose: by
//! [`Answered::of`], which turns a client's `Answer` into a record (the writer's gate), and by
//! [`Answered::is_real`], which [`fold`] checks on every line it reads (the reader's gate), so
//! neither a client nor a hand-edited or torn line can settle a question nobody answered.
//!
//! # Where the records live, and why there
//!
//! `<store>/questions/<session id>.jsonl`, in a subdirectory beside the session logs: same
//! append-only JSONL, same torn-last-line tolerance. A subdirectory, not the log directory
//! itself, because `session::list` walks that directory for `*.jsonl` and would re-scan every
//! ledger on every listing. **One file per session, one writer per
//! file** — each session's own engine appends only to its own file, exactly as it writes only
//! its own `<id>.jsonl`. That is what makes this safe across the many engine processes a tree
//! runs: no two writers ever touch the same file, so no record is lost to a rewrite race.
//!
//! A reader (the asking engine, or the client's `ListQuestions`) reads one file per session in
//! the tree. An answer is appended to the *asking* session's file, because that is the engine
//! that receives it — its question, its answer.
//!
//! The tree itself is not stored here: parentage is the client's (the sidebar's nesting, mutable
//! with `MoveSession`), so the engine asks for it and passes it in.

use crate::protocol::{Answer, AskOption};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// How many recent answered rows a file keeps before it is compacted down to the live set.
const KEEP: usize = 512;

/// The suffix that marks a ledger file.
pub const SUFFIX: &str = ".jsonl";

/// The subdirectory of the store that holds the ledgers, beside (not among) the session logs.
/// A subdirectory matters: `session::list` walks the sessions directory for `*.jsonl` and scans
/// each one, so a ledger sitting there would be re-read every listing and never cached — it has
/// no `Header` line, so it is skipped, but the work is wasted every time.
pub const DIR: &str = "questions";

/// The normalization two questions must share to count as the same question.
///
/// Trim, collapse runs of whitespace to one space, lowercase. Deliberately dumb: it catches the
/// real case (a parent and a child restating one decision in the same words) and cannot
/// silently merge two questions that differ, which a fuzzy match would. The eventual version is
/// embedding similarity over the question and its options — same decision, different words —
/// but that needs a model call at ask time and a threshold to tune, and a wrong merge here
/// hides a question the user never answered. Text equality errs toward asking twice, which is
/// the failure we can see and fix; a bad merge is the one we can't.
pub fn key(question: &str) -> String {
    question
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

/// What the user actually chose.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Answered {
    /// The labels they picked, filtered to the ones that were offered.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub choices: Vec<String>,
    /// Their own words, when they typed instead of picking.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub other: Option<String>,
    /// Unix milliseconds.
    pub at_ms: i64,
}

impl Answered {
    /// An answer worth recording, or `None` for a dismissal. Callers use this rather than the
    /// struct literal so an empty answer can't be recorded by accident; the literal is reachable
    /// (the fields are public for the JSON shape) and the disk path is checked again on read by
    /// [`is_real`], because a hand-edited or half-written line is not a caller.
    pub fn of(answer: &Answer, options: &[AskOption], allow_other: bool, at_ms: i64) -> Option<Self> {
        let choices: Vec<String> = answer
            .choices
            .iter()
            .filter(|c| options.iter().any(|o| &o.label == *c))
            .cloned()
            .collect();
        let other = answer
            .other
            .as_deref()
            .map(str::trim)
            .filter(|o| !o.is_empty() && allow_other)
            .map(String::from);
        // No offered label picked and no words of their own: a dismissal, whatever the client
        // sent. This is the case that used to close a question silently.
        if choices.is_empty() && other.is_none() {
            return None;
        }
        Some(Self {
            choices,
            other,
            at_ms,
        })
    }

    /// Whether this is an answer at all: something the user picked or wrote. Requirement 5 is
    /// enforced here, on the way *out of storage* as well, so a record can't become a settled
    /// answer that nobody gave — not from a client, not from a torn or edited line.
    pub fn is_real(&self) -> bool {
        !self.choices.is_empty() || self.other.as_deref().is_some_and(|o| !o.trim().is_empty())
    }

    /// One line for a model: "Dev, Max" or "neither, revert".
    pub fn words(&self) -> String {
        match (self.choices.is_empty(), &self.other) {
            (false, None) => self.choices.join(", "),
            (false, Some(o)) => format!("{} (and: {o})", self.choices.join(", ")),
            (true, Some(o)) => o.clone(),
            (true, None) => String::new(),
        }
    }
}

/// One line of a ledger file. Append-only: `Asked`, then optionally `Answered` or `Dismissed`
/// (a later line for the same id). Readers fold the lines by id, so a record is never rewritten
/// in place and a crash mid-write costs at most the last line.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "record", rename_all = "snake_case")]
pub enum Entry {
    Asked {
        id: String,
        /// The session that asked.
        session: String,
        /// Its title, when the asking engine knew one.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        question: String,
        /// [`key`] of `question`, stored so readers needn't re-derive it.
        key: String,
        options: Vec<AskOption>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        multi: bool,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        allow_other: bool,
        asked_ms: i64,
    },
    Answered {
        id: String,
        #[serde(flatten)]
        answer: Answered,
    },
    /// The card went away without an answer. Its own record — never an empty answer — so
    /// "asked, never answered" can't be read as settled.
    Dismissed {
        id: String,
        at_ms: i64,
    },
}

/// A question folded from its lines: what was asked, and how it stands.
#[derive(Clone, Debug, PartialEq)]
pub struct Asked {
    pub id: String,
    pub session: String,
    pub name: Option<String>,
    pub question: String,
    pub key: String,
    pub options: Vec<AskOption>,
    pub multi: bool,
    pub allow_other: bool,
    pub asked_ms: i64,
    /// The answer, once one lands. `None` while open **and** after a dismissal.
    pub answer: Option<Answered>,
    /// When the card was put away without an answer.
    pub dismissed_ms: Option<i64>,
}

impl Asked {
    /// The card is still up somewhere: no answer, not dismissed.
    pub fn is_open(&self) -> bool {
        self.answer.is_none() && self.dismissed_ms.is_none()
    }

    /// One word for a listing: `open`, `answered`, `dismissed`.
    pub fn state(&self) -> &'static str {
        match (&self.answer, self.dismissed_ms) {
            (Some(_), _) => "answered",
            (None, Some(_)) => "dismissed",
            (None, None) => "open",
        }
    }
}

/// Fold one file's lines into rows, in the order the questions were asked. An `Answered` or
/// `Dismissed` line for an id this file doesn't have is dropped: it belongs to the file that
/// asked, and that engine wrote it there.
pub fn fold(lines: impl IntoIterator<Item = String>) -> Vec<Asked> {
    let mut rows: Vec<Asked> = Vec::new();
    let mut at: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for line in lines {
        let Ok(entry) = serde_json::from_str::<Entry>(&line) else {
            continue; // a torn final line (a crash mid-write), as session logs tolerate
        };
        match entry {
            Entry::Asked {
                id,
                session,
                name,
                question,
                key,
                options,
                multi,
                allow_other,
                asked_ms,
            } => {
                let row = Asked {
                    id: id.clone(),
                    session,
                    name,
                    question,
                    key,
                    options,
                    multi,
                    allow_other,
                    asked_ms,
                    answer: None,
                    dismissed_ms: None,
                };
                // A re-ask of an id already folded (a resumed turn) replaces the question.
                match at.get(&id) {
                    Some(&i) => rows[i] = row,
                    None => {
                        at.insert(id, rows.len());
                        rows.push(row);
                    }
                }
            }
            Entry::Answered { id, answer } => {
                if let Some(&i) = at.get(&id) {
                    // The first answer stands: a second card's click can't rewrite it. And an
                    // answer with nothing in it is not an answer: a hand-edited or torn line
                    // can't settle a question the user never answered (requirement 5).
                    if rows[i].answer.is_none() && answer.is_real() {
                        rows[i].answer = Some(answer);
                        rows[i].dismissed_ms = None;
                    }
                }
            }
            Entry::Dismissed { id, at_ms } => {
                if let Some(&i) = at.get(&id)
                    && rows[i].answer.is_none()
                    && rows[i].dismissed_ms.is_none()
                {
                    rows[i].dismissed_ms = Some(at_ms);
                }
            }
        }
    }
    rows
}

/// One session's ledger file: append-only, one writer (that session's engine).
pub struct File {
    path: PathBuf,
    session: String,
}

impl File {
    /// `<dir>/questions/<session id>.jsonl`, beside the session logs' own directory.
    pub fn new(dir: &Path, session: &str) -> Self {
        Self {
            path: dir.join(DIR).join(format!("{session}{SUFFIX}")),
            session: session.to_string(),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Every row this file holds, folded.
    pub fn read(&self) -> Vec<Asked> {
        let Ok(text) = std::fs::read_to_string(&self.path) else {
            return Vec::new();
        };
        fold(text.lines().map(String::from))
    }

    /// Append one line. Best effort, like the session log's own appends: a question that can't
    /// be recorded still gets asked, it just isn't shared with the tree.
    fn append(&self, entry: &Entry) {
        let Ok(mut line) = serde_json::to_string(entry) else {
            return;
        };
        line.push('\n');
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        use std::io::Write;
        if let Ok(mut f) = std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(&self.path)
        {
            let _ = f.write_all(line.as_bytes());
            let _ = f.sync_data();
        }
    }

    /// Record the question as asked. Idempotent by id, so a resumed turn doesn't double it.
    pub fn ask(&self, q: &crate::ask::Question, id: &str, name: Option<String>, asked_ms: i64) {
        if self.read().iter().any(|r| r.id == id) {
            return;
        }
        self.append(&Entry::Asked {
            id: id.to_string(),
            session: self.session.clone(),
            name,
            question: q.question.clone(),
            key: key(&q.question),
            options: q.options.clone(),
            multi: q.multi,
            allow_other: q.allow_other,
            asked_ms,
        });
        self.compact();
    }

    /// Record the user's answer. `None` (a dismissal) records nothing: the question stays
    /// unanswered, which is the point.
    pub fn answer(&self, id: &str, answer: &Answer, at_ms: i64) -> Option<Answered> {
        let rows = self.read();
        let row = rows.iter().find(|r| r.id == id)?;
        if let Some(a) = &row.answer {
            return Some(a.clone()); // already settled; the first answer stands
        }
        let answered = Answered::of(answer, &row.options, row.allow_other, at_ms)?;
        self.append(&Entry::Answered {
            id: id.to_string(),
            answer: answered.clone(),
        });
        self.compact();
        Some(answered)
    }

    /// The card went away without an answer: the turn ended, the user interrupted, or they
    /// answered something else in the same session. Never recorded as an answer.
    pub fn dismiss(&self, id: &str, at_ms: i64) {
        let rows = self.read();
        let Some(row) = rows.iter().find(|r| r.id == id) else {
            return;
        };
        if !row.is_open() {
            return;
        }
        self.append(&Entry::Dismissed {
            id: id.to_string(),
            at_ms,
        });
        self.compact();
    }

    /// Rewrite the file whole when it has grown past `KEEP` answered rows, keeping every open
    /// or dismissed row and the most recent answered ones. Rewriting is safe here because this
    /// file has one writer; a reader that catches the rename sees one version or the other.
    fn compact(&self) {
        let rows = self.read();
        let answered = rows.iter().filter(|r| r.answer.is_some()).count();
        if answered <= KEEP {
            return;
        }
        let mut drop_n = answered - KEEP;
        let mut text = String::new();
        for r in &rows {
            if r.answer.is_some() && drop_n > 0 {
                drop_n -= 1;
                continue;
            }
            for entry in entries_of(r) {
                if let Ok(line) = serde_json::to_string(&entry) {
                    text.push_str(&line);
                    text.push('\n');
                }
            }
        }
        let tmp = self.path.with_extension(format!("tmp{}", std::process::id()));
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &self.path);
        }
    }
}

/// A row back as the lines that make it (used by compaction).
fn entries_of(r: &Asked) -> Vec<Entry> {
    let mut out = vec![Entry::Asked {
        id: r.id.clone(),
        session: r.session.clone(),
        name: r.name.clone(),
        question: r.question.clone(),
        key: r.key.clone(),
        options: r.options.clone(),
        multi: r.multi,
        allow_other: r.allow_other,
        asked_ms: r.asked_ms,
    }];
    if let Some(a) = &r.answer {
        out.push(Entry::Answered {
            id: r.id.clone(),
            answer: a.clone(),
        });
    }
    if let Some(at) = r.dismissed_ms {
        out.push(Entry::Dismissed {
            id: r.id.clone(),
            at_ms: at,
        });
    }
    out
}

/// Every question the sessions in `tree` have recorded, oldest first. Reads one file per
/// session; a session with no file simply has none.
pub fn in_tree(dir: &Path, tree: &[String]) -> Vec<Asked> {
    let mut out: Vec<Asked> = Vec::new();
    for session in tree {
        out.extend(File::new(dir, session).read());
    }
    out.sort_by_key(|r| r.asked_ms);
    out
}

/// What a session should do about a question it is about to ask.
pub enum Before<'a> {
    /// Nothing equivalent in the tree: ask it.
    Ask,
    /// Already open somewhere in the tree. Don't open a second card.
    Open { at: &'a Asked },
    /// Already answered somewhere in the tree. The answer is settled; use it.
    Answered { at: &'a Asked, answer: &'a Answered },
}

impl Before<'_> {
    /// The text the model gets instead of a card.
    pub fn words(&self) -> String {
        match self {
            Self::Ask => String::new(),
            Self::Open { at } => format!(
                "This question is already open in {} ({}), waiting on the user. Don't ask it \
again: the answer is recorded once they give it, and ListQuestions shows it as open until \
then. If you need it to proceed, say so and stop; don't re-ask it or guess.",
                at.name.as_deref().unwrap_or("another session"),
                at.session
            ),
            Self::Answered { at, answer } => format!(
                "This was already answered in {} ({}): {}. Use that answer rather than asking \
the user again; only ask if you need something it doesn't cover.",
                at.name.as_deref().unwrap_or("another session"),
                at.session,
                answer.words()
            ),
        }
    }
}

/// Decide whether the tree already has this question open or settled. `rows` comes from
/// [`in_tree`].
pub fn before<'a>(rows: &'a [Asked], key: &str, tree: &[String]) -> Before<'a> {
    let mine = |r: &&Asked| r.key == key && tree.contains(&r.session);
    if let Some(at) = rows.iter().filter(|r| mine(r) && r.is_open()).next_back() {
        return Before::Open { at };
    }
    if let Some(at) = rows
        .iter()
        .filter(|r| mine(r) && r.answer.is_some())
        .next_back()
        && let Some(answer) = &at.answer
    {
        return Before::Answered { at, answer };
    }
    Before::Ask
}

/// The sessions in `id`'s tree, from the client's parent map: `id`, its ancestors, and its
/// descendants. The one place the tree rule lives, so the engine and any reader agree.
///
/// Walks are bounded by the recorded parents, so a cycle that somehow got recorded terminates
/// instead of hanging.
pub fn members(id: &str, parent: impl Fn(&str) -> Option<String>, known: &[String]) -> Vec<String> {
    let mut out = vec![id.to_string()];
    let mut seen: HashSet<String> = out.iter().cloned().collect();
    let mut cur = parent(id);
    while let Some(c) = cur {
        if !seen.insert(c.clone()) {
            break;
        }
        out.push(c.clone());
        cur = parent(&c);
    }
    for other in known {
        if !seen.contains(other) && is_ancestor(id, other, &parent) {
            seen.insert(other.clone());
            out.push(other.clone());
        }
    }
    out
}

/// Whether `up` is `at` itself or above it.
fn is_ancestor(up: &str, at: &str, parent: &impl Fn(&str) -> Option<String>) -> bool {
    let mut seen = HashSet::new();
    let mut cur = Some(at.to_string());
    while let Some(c) = cur {
        if c == up {
            return true;
        }
        if !seen.insert(c.clone()) {
            return false;
        }
        cur = parent(&c);
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    fn q(question: &str) -> crate::ask::Question {
        crate::ask::parse(&serde_json::json!({
            "question": question,
            "options": ["Cap it", "Let it run"]
        }))
        .unwrap()
    }

    fn dir() -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "frog-q-{}-{}",
            std::process::id(),
            crate::session::new_id()
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn key_normalizes_whitespace_and_case_only() {
        assert_eq!(key("  Raise the GPU cap?  "), "raise the gpu cap?");
        assert_eq!(key("Raise\nthe   GPU\tcap?"), "raise the gpu cap?");
        // Two questions that differ keep differing: no fuzzy merge.
        assert_ne!(key("Raise the GPU cap?"), key("Raise the GPU cap"));
        assert_ne!(key("Raise the cap?"), key("Lower the cap?"));
    }

    #[test]
    fn a_dismissal_is_not_an_answer() {
        let options = q("?").options;
        assert!(Answered::of(&Answer::default(), &options, true, 1).is_none());
        // A choice that wasn't offered, with no words: still nothing.
        let stray = Answer {
            choices: vec!["Rewrite it".into()],
            other: None,
        };
        assert!(Answered::of(&stray, &options, true, 1).is_none());
        let words = Answer {
            choices: vec![],
            other: Some("  later  ".into()),
        };
        assert_eq!(
            Answered::of(&words, &options, true, 1).unwrap().other.as_deref(),
            Some("later")
        );
        let pick = Answer {
            choices: vec!["Cap it".into()],
            other: None,
        };
        assert_eq!(Answered::of(&pick, &options, true, 1).unwrap().words(), "Cap it");
    }

    /// Requirement 5, the reason this module exists: the user answers a *different* card in
    /// the same session, this one is put away unanswered, and it stays unanswered — never
    /// closed as though it had been answered, and never silently settled.
    #[test]
    fn a_dismissed_question_is_never_an_answer() {
        let d = dir();
        let f = File::new(&d, "child");
        f.ask(&q("Raise the GPU cap?"), "q1", None, 1);
        // The client sends an empty answer (the user typed in the composer instead).
        assert!(f.answer("q1", &Answer::default(), 9).is_none());
        assert_eq!(f.read()[0].state(), "open", "an empty answer is not an answer either");
        // The card goes away: asked, never answered, off the screen.
        f.dismiss("q1", 10);
        let row = &f.read()[0];
        assert_eq!(row.state(), "dismissed");
        assert!(row.answer.is_none(), "a dismissal must never become an answer");
        // The tree must therefore ask it again rather than believe it settled.
        let tree = vec!["child".to_string(), "parent".to_string()];
        let rows = in_tree(&d, &tree);
        assert!(matches!(
            before(&rows, &key("Raise the GPU cap?"), &tree),
            Before::Ask
        ));
    }

    #[test]
    fn dismissing_an_answered_question_changes_nothing() {
        let d = dir();
        let f = File::new(&d, "child");
        f.ask(&q("Raise the GPU cap?"), "q1", None, 1);
        let a = Answer {
            choices: vec!["Cap it".into()],
            other: None,
        };
        f.answer("q1", &a, 5);
        f.dismiss("q1", 6);
        assert_eq!(f.read()[0].state(), "answered");
        assert_eq!(f.read()[0].answer.as_ref().unwrap().words(), "Cap it");
    }

    #[test]
    fn the_first_answer_stands_and_survives_a_restart() {
        let d = dir();
        {
            let f = File::new(&d, "child");
            f.ask(&q("Raise the GPU cap?"), "q1", Some("Ops".into()), 1);
            let a = Answer {
                choices: vec!["Cap it".into()],
                other: None,
            };
            assert!(f.answer("q1", &a, 5).is_some());
            // A second click can't rewrite it.
            let b = Answer {
                choices: vec!["Let it run".into()],
                other: None,
            };
            assert_eq!(f.answer("q1", &b, 6).unwrap().words(), "Cap it");
        }
        // A fresh process (the file is all there is) reads the same answer.
        let tree = vec!["child".to_string(), "parent".to_string()];
        let rows = in_tree(&d, &tree);
        match before(&rows, &key("Raise the GPU cap?"), &tree) {
            Before::Answered { at, answer } => {
                assert_eq!(at.session, "child");
                assert_eq!(answer.words(), "Cap it");
            }
            _ => panic!("the parent should see the child's settled answer"),
        }
    }

    /// One answer, whole tree: a question open in a worker is the manager's too. It doesn't
    /// open a second card, and once answered the manager gets the answer, not a card.
    #[test]
    fn an_open_question_in_a_descendant_stops_a_second_card() {
        let d = dir();
        File::new(&d, "worker").ask(&q("Raise the GPU cap?"), "q1", None, 1);
        let tree = vec!["worker".to_string(), "mgr".to_string(), "chief".to_string()];
        let rows = in_tree(&d, &tree);
        match before(&rows, &key("raise the GPU CAP?"), &tree) {
            Before::Open { at } => assert_eq!(at.session, "worker"),
            _ => panic!("the manager should see the worker's open question"),
        }
        assert!(before(&rows, &key("Raise the GPU cap?"), &tree)
            .words()
            .contains("already open"));
        // An unrelated session still asks.
        assert!(matches!(
            before(&rows, &key("Raise the GPU cap?"), &["stranger".to_string()]),
            Before::Ask
        ));
        // Answered in the worker: the manager is handed the answer instead of a card.
        let a = Answer {
            choices: vec!["Let it run".into()],
            other: None,
        };
        File::new(&d, "worker").answer("q1", &a, 4);
        let rows = in_tree(&d, &tree);
        match before(&rows, &key("Raise the GPU cap?"), &tree) {
            Before::Answered { answer, .. } => assert_eq!(answer.words(), "Let it run"),
            _ => panic!("the settled answer should reach the manager"),
        }
    }

    #[test]
    fn a_tree_is_ancestors_and_descendants_but_not_siblings() {
        let parents: std::collections::HashMap<String, String> = [
            ("mgr".to_string(), "chief".to_string()),
            ("worker".to_string(), "mgr".to_string()),
            ("other".to_string(), "chief".to_string()),
        ]
        .into_iter()
        .collect();
        let parent = |id: &str| parents.get(id).cloned();
        let known = vec![
            "chief".to_string(),
            "mgr".into(),
            "worker".into(),
            "other".into(),
        ];
        let mut mine = members("worker", &parent, &known);
        mine.sort();
        assert_eq!(mine, ["chief", "mgr", "worker"]);
        let mut top = members("chief", &parent, &known);
        top.sort();
        assert_eq!(top, ["chief", "mgr", "other", "worker"]);
        // Siblings share a parent, not a question.
        assert!(!members("worker", &parent, &known).contains(&"other".to_string()));
    }

    #[test]
    fn a_parent_cycle_terminates() {
        let parents: std::collections::HashMap<String, String> = [
            ("a".to_string(), "b".to_string()),
            ("b".to_string(), "a".to_string()),
        ]
        .into_iter()
        .collect();
        let parent = |id: &str| parents.get(id).cloned();
        let known = vec!["a".to_string(), "b".into()];
        assert_eq!(members("a", &parent, &known).len(), 2);
        assert!(!members("a", &parent, &known).contains(&"c".to_string()));
    }

    #[test]
    fn the_file_stays_bounded() {
        let d = dir();
        let f = File::new(&d, "s");
        for i in 0..KEEP + 20 {
            let id = format!("q{i}");
            f.ask(&q(&format!("question {i}")), &id, None, i as i64);
            let a = Answer {
                choices: vec!["Cap it".into()],
                other: None,
            };
            f.answer(&id, &a, i as i64);
        }
        assert_eq!(f.read().len(), KEEP, "answered rows are capped as they land");
        // An open question is never dropped.
        f.ask(&q("still open"), "live", None, 0);
        let rows = f.read();
        assert_eq!(rows.len(), KEEP + 1);
        assert!(rows.iter().any(|r| r.question == "still open" && r.is_open()));
    }

    /// A record on disk claiming an answer with nothing in it (hand-edited, or a line from an
    /// older bug) must not settle the question: the reader's gate, as `Answered::of` is the
    /// writer's. Requirement 5 is about the record surviving, so it is checked on the way out
    /// of storage too.
    #[test]
    fn a_stored_answer_with_nothing_in_it_does_not_settle() {
        let d = dir();
        let f = File::new(&d, "s");
        f.ask(&q("Raise the GPU cap?"), "q1", None, 1);
        let mut text = std::fs::read_to_string(f.path()).unwrap();
        text.push_str("{\"record\":\"answered\",\"id\":\"q1\",\"at_ms\":5}\n");
        std::fs::write(f.path(), text).unwrap();
        let row = &f.read()[0];
        assert_eq!(row.state(), "open", "an empty answer on disk is not an answer");
        assert!(row.answer.is_none());
    }

    /// A torn last line (a crash mid-write) costs that line and nothing else, as with logs.
    #[test]
    fn a_torn_line_is_ignored() {
        let d = dir();
        let f = File::new(&d, "s");
        f.ask(&q("Raise the GPU cap?"), "q1", None, 1);
        let mut text = std::fs::read_to_string(f.path()).unwrap();
        text.push_str("{\"record\":\"asked\",\"id\":\"q2\",\"sess");
        std::fs::write(f.path(), text).unwrap();
        let rows = f.read();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, "q1");
    }
}
