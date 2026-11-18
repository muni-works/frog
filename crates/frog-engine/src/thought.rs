//! The thought line: one cleaned-up line of what the model is thinking, for the transcript's
//! thinking row (docs/design/transcript/spec.md, "The thought line (engine)").
//!
//! The engine, not each app, turns reasoning into the line both apps show. [`line`] is the pure
//! rule: reasoning so far in, the line to show out. [`Thoughts`] is the same rule fed one
//! streamed chunk at a time, throttled so the line changes at most once every
//! [`INTERVAL_MS`], and remembering which lines it showed so the completed reasoning item can
//! carry them ([`ShownThought`]).
//!
//! The rules, in short (the definition is `docs/design/transcript/thoughts.json`):
//!
//! 1. Only finished paragraphs count: a paragraph is finished once a blank line (or a closing
//!    reasoning tag such as `</think>`) follows it. Never a partial one.
//! 2. Take its first sentence: cut at the first full stop (or `?`, `!`, `。`), at a colon that
//!    ends the line, or at the end of the line.
//! 3. Drop lead-ins ("Let me", "I should", "Actually,", "Hmm,", "OK so") and use the sentence
//!    that follows when the lead-in was the whole sentence ("Let me think.").
//! 4. Skip the paragraph (hold the previous line) when what's left is a list item, code,
//!    mostly digits or symbols, or under three words.
//! 5. Strip markdown and trailing punctuation. A sentence over [`MAX_CHARS`] is cut at a clause
//!    break, or at a word with an ellipsis.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// The line changes at most this often (ms). A paragraph that lands sooner waits; when several
/// land in one interval only the newest shows.
pub const INTERVAL_MS: u64 = 1200;

/// Longest line, in characters. Longer sentences are cut (see [`shorten`]).
pub const MAX_CHARS: usize = 120;

/// One line the thinking row showed, as the completed reasoning item carries it.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq, JsonSchema)]
pub struct ShownThought {
    /// The line, exactly as it was shown.
    pub text: String,
    /// The paragraph it came from, as a half-open range into the item's `text`, in UTF-16 code
    /// units (JavaScript string indices; Swift's `String.utf16` view).
    pub start: u32,
    pub end: u32,
    /// When it was shown, in ms after the item's first reasoning arrived.
    pub ms: u64,
}

/// The line for `reasoning` so far, or `None` when nothing qualifies yet.
pub fn line(reasoning: &str) -> Option<String> {
    let mut s = Scanner::default();
    s.scan(reasoning);
    s.best.map(|b| b.line)
}

/// The newest qualifying paragraph: its line and byte range in the reasoning.
#[derive(Clone, Debug, PartialEq)]
struct Pick {
    line: String,
    start: usize,
    end: usize,
}

/// Walks finished paragraphs in order, once each, and keeps the newest that yields a line.
#[derive(Default)]
struct Scanner {
    /// Byte offset of the first paragraph not yet known to be finished.
    from: usize,
    /// Inside a fenced code block (an odd number of ``` lines so far).
    fence: bool,
    best: Option<Pick>,
}

impl Scanner {
    /// Scan whatever new paragraphs `text` (the whole reasoning so far) has finished.
    fn scan(&mut self, text: &str) {
        while let Some((end, next)) = boundary(text, self.from) {
            let para = &text[self.from..end];
            let fenced = self.fence;
            self.fence ^= fences(para) % 2 == 1;
            if !fenced && let Some(line) = pick(para) {
                let lead = para.len() - para.trim_start().len();
                self.best = Some(Pick {
                    line,
                    start: self.from + lead,
                    end: self.from + para.trim_end().len(),
                });
            }
            self.from = next;
        }
    }
}

/// The end of the paragraph starting at `from`, and where the next one starts, if a paragraph
/// break follows: a blank line (only spaces or tabs between two newlines), or a reasoning tag.
fn boundary(text: &str, from: usize) -> Option<(usize, usize)> {
    let b = text.as_bytes();
    let mut i = from;
    while i < b.len() {
        match b[i] {
            b'\n' => {
                let mut j = i + 1;
                while j < b.len() && (b[j] == b' ' || b[j] == b'\t' || b[j] == b'\r') {
                    j += 1;
                }
                if j < b.len() && b[j] == b'\n' {
                    return Some((i, j + 1));
                }
            }
            b'<' => {
                if let Some(n) = tag_len(&text[i..]) {
                    return Some((i, i + n));
                }
            }
            _ => {}
        }
        i += 1;
    }
    None
}

/// Tags some models wrap their reasoning in. Either end breaks a paragraph and is never shown.
const TAGS: &[&str] = &[
    "think",
    "thinking",
    "thought",
    "reasoning",
    "reflection",
    "scratchpad",
];

/// The length of a reasoning tag (`<think>`, `</thinking>`, …) at the start of `s`.
fn tag_len(s: &str) -> Option<usize> {
    let rest = s.strip_prefix('<')?;
    let rest = rest.strip_prefix('/').unwrap_or(rest);
    let close = rest.find('>')?;
    TAGS.iter()
        .any(|t| rest[..close].eq_ignore_ascii_case(t))
        .then(|| s.len() - rest.len() + close + 1)
}

/// How many lines of `para` open or close a fenced code block.
fn fences(para: &str) -> usize {
    para.lines()
        .filter(|l| {
            let l = l.trim_start();
            l.starts_with("```") || l.starts_with("~~~")
        })
        .count()
}

/// The line for one finished paragraph, or `None` to hold the previous line.
fn pick(para: &str) -> Option<String> {
    let para = para.trim();
    if para.is_empty() || is_code(para) {
        return None;
    }
    let first = para.lines().next().unwrap_or("").trim_start();
    if is_list_item(first) || first.starts_with('|') {
        return None;
    }
    // A heading or a quote is still prose once its marks are gone.
    let body = strip_block_marks(para);
    let mut rest = body.as_str();
    // At most a few sentences in: a paragraph of lead-ins has nothing to say.
    for _ in 0..4 {
        let (sentence, after) = first_sentence(rest);
        let cleaned = clean(sentence);
        match strip_lead_ins(&cleaned) {
            Lead::Filler => {
                rest = after;
                if rest.trim().is_empty() {
                    return None;
                }
            }
            Lead::Line(line) => return accept(&line),
        }
    }
    None
}

/// What's left of a sentence once its lead-ins are gone.
enum Lead {
    /// Nothing: the lead-in was the whole sentence ("Let me think.").
    Filler,
    Line(String),
}

/// A paragraph that is code: fenced, indented, or shaped like source.
fn is_code(para: &str) -> bool {
    if para.starts_with("```") || para.starts_with("~~~") {
        return true;
    }
    let lines: Vec<&str> = para.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines
        .iter()
        .all(|l| l.starts_with("    ") || l.starts_with('\t'))
    {
        return true;
    }
    // Source lines: ending in `;`, `{`, `}` or `)`, or starting with a keyword and a symbol.
    let codey = lines
        .iter()
        .filter(|l| {
            let t = l.trim();
            t.ends_with(';')
                || t.ends_with('{')
                || t == "}"
                || t.starts_with("fn ")
                || t.starts_with("def ")
                || t.starts_with("func ")
                || t.starts_with("function ")
                || t.starts_with("import ")
                || t.starts_with("#include")
                || t.starts_with("$ ")
        })
        .count();
    codey * 2 > lines.len()
}

/// `- x`, `* x`, `+ x`, `• x`, `1. x`, `1) x`, `a) x`, `[ ] x`.
fn is_list_item(line: &str) -> bool {
    let t = line.trim_start();
    if ["- ", "* ", "+ ", "• ", "· ", "– ", "— "]
        .iter()
        .any(|m| t.starts_with(m))
        || t == "-"
        || t == "*"
    {
        return true;
    }
    let digits = t.chars().take_while(|c| c.is_ascii_digit()).count();
    if digits > 0 && digits <= 3 {
        let after = &t[digits..];
        return after.starts_with(". ") || after.starts_with(") ");
    }
    // `a) x`, and `A. x` / `B) x` (an enumeration, not an initial: a sentence never starts
    // with one).
    let mut chars = t.chars();
    match (chars.next(), chars.next(), chars.next()) {
        (Some(c), Some(')'), Some(' ')) => c.is_ascii_alphabetic(),
        (Some(c), Some('.'), Some(' ')) => c.is_ascii_uppercase(),
        _ => false,
    }
}

/// A paragraph without its block marks: `#` heading marks and `>` quote marks at line starts.
fn strip_block_marks(para: &str) -> String {
    para.lines()
        .map(|l| {
            let t = l.trim_start();
            let t = t.trim_start_matches('>').trim_start();
            let hashes = t.chars().take_while(|&c| c == '#').count();
            if hashes > 0 && hashes <= 6 && t[hashes..].starts_with(' ') {
                t[hashes..].trim_start()
            } else {
                t
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Words that end with a dot but don't end a sentence.
const ABBREVIATIONS: &[&str] = &[
    "e.g", "i.e", "etc", "vs", "cf", "approx", "mr", "mrs", "ms", "dr", "st", "no", "fig", "eq",
    "al", "incl", "esp", "resp", "ca",
];

/// The first sentence of `s` and what follows it. A sentence ends at a full stop, `?` or `!`
/// followed by a space or the end; at `。`, `？` or `！`; at a colon that ends its line; or at
/// the end of its line.
fn first_sentence(s: &str) -> (&str, &str) {
    let s = s.trim_start();
    let chars: Vec<(usize, char)> = s.char_indices().collect();
    for (k, &(i, c)) in chars.iter().enumerate() {
        let next = chars.get(k + 1).map(|&(_, n)| n);
        let end_here = |len: usize| (&s[..i + len], &s[i + len..]);
        match c {
            '\n' => return (&s[..i], &s[i + 1..]),
            '。' | '？' | '！' => return end_here(c.len_utf8()),
            '.' | '?' | '!' if next.is_none_or(char::is_whitespace) => {
                if c == '.' && is_abbreviation(&s[..i]) {
                    continue;
                }
                return end_here(1);
            }
            ':' | '：' if next.is_none_or(|n| n == '\n') => return end_here(c.len_utf8()),
            ':' if next == Some(' ') && s[i + 1..].trim_start_matches(' ').starts_with('\n') => {
                return end_here(1);
            }
            _ => {}
        }
    }
    (s, "")
}

/// Whether the word just before a dot is an abbreviation ("e.g.", "vs.") or a single letter
/// ("J. Smith"), so the dot doesn't end the sentence.
fn is_abbreviation(before: &str) -> bool {
    let word = before
        .rsplit(|c: char| c.is_whitespace() || c == '(')
        .next()
        .unwrap_or("");
    let w = word.to_lowercase();
    ABBREVIATIONS.contains(&w.as_str())
        || (word.chars().count() == 1 && word.chars().all(|c| c.is_uppercase()))
}

/// A sentence with its markdown gone and its whitespace collapsed: `**bold**`, `_em_`,
/// `` `code` ``, `~~struck~~`, `[text](url)`.
fn clean(sentence: &str) -> String {
    let mut s = String::with_capacity(sentence.len());
    let mut chars = sentence.chars().peekable();
    let mut prev = ' ';
    while let Some(c) = chars.next() {
        match c {
            '*' | '`' => {}
            '~' if chars.peek() == Some(&'~') => {
                chars.next();
            }
            // `_` marks emphasis only at a word's edge; inside (`snake_case`) it stays.
            '_' if !prev.is_alphanumeric()
                || !chars.peek().is_some_and(|n| n.is_alphanumeric()) => {}
            '[' => {
                // `[text](url)` → text; a lone `[` stays.
                let rest: String = chars.clone().collect();
                if let Some(close) = rest.find("](")
                    && let Some(paren) = rest[close + 2..].find(')')
                {
                    s.push_str(&rest[..close]);
                    for _ in 0..rest[..close + 2 + paren + 1].chars().count() {
                        chars.next();
                    }
                    prev = 'x';
                    continue;
                }
                s.push(c);
            }
            c if c.is_whitespace() => {
                if !s.ends_with(' ') && !s.is_empty() {
                    s.push(' ');
                }
            }
            c => s.push(c),
        }
        prev = c;
    }
    s.trim().to_string()
}

/// Interjections dropped from a sentence's start, followed by a comma, a dash or a space.
const INTERJECTIONS: &[&str] = &[
    "actually",
    "hmm",
    "hm",
    "hmmm",
    "ok so",
    "okay so",
    "ok",
    "okay",
    "alright",
    "all right",
    "so",
    "well",
    "wait",
    "oh",
    "ah",
    "aha",
    "now",
    "also",
    "but",
    "and",
    "then",
    "anyway",
    "yeah",
    "still",
    "hold on",
    "oh wait",
    "um",
    "uh",
];

/// Interjections dropped only with a comma, a dash or a stop after them ("Good, the build
/// passed"), never with a plain space ("Good tests cover this").
const COMMA_ONLY: &[&str] = &[
    "good",
    "great",
    "perfect",
    "nice",
    "yes",
    "interesting",
    "excellent",
    "cool",
    "got it",
    "i see",
    "understood",
    "fine",
    "sure",
    "done",
    "huh",
    "right",
    "first",
    "next",
    "finally",
    "found it",
    "ah i see",
];

/// Verb phrases dropped from a sentence's start: the rest is what the model will do.
const LEAD_INS: &[&str] = &[
    "let me",
    "let's",
    "lets",
    "let us",
    "i should",
    "i'll",
    "i will",
    "i need to",
    "i have to",
    "i must",
    "i want to",
    "i'm going to",
    "i am going to",
    "i'd like to",
    "i would like to",
    "we need to",
    "we should",
    "we'll",
    "i can",
    "i could",
    "i think",
    "i believe",
    "i guess",
    "i suppose",
    "i'm gonna",
    "time to",
    "now i need to",
    "now let me",
    "i'll now",
    "i now need to",
];

/// What a lead-in leaves behind when it was the whole sentence.
const FILLER: &[&str] = &[
    "",
    "think",
    "think about this",
    "think about it",
    "think about that",
    "think this through",
    "think step by step",
    "think carefully",
    "think more carefully",
    "think again",
    "see",
    "look",
    "check",
    "start",
    "begin",
    "analyze",
    "analyze this",
    "consider",
    "reconsider",
    "re-read",
    "reread",
    "recap",
    "summarize",
    "continue",
    "proceed",
    "go",
    "figure this out",
    "figure it out",
    "work through this",
    "break this down",
    "understand",
    "get started",
    "do this",
    "be careful",
    "look again",
    "look at this",
    "check this",
    "re-check",
    "recheck",
    "verify",
    "double-check",
    "double check",
    "found it",
    "there it is",
    "that's it",
    "that makes sense",
    "makes sense",
    "that works",
];

/// A sentence without its lead-ins. Lead-ins can stack ("Okay, so let me check …").
fn strip_lead_ins(sentence: &str) -> Lead {
    let mut s = sentence.trim();
    let mut stripped = false;
    loop {
        let before = s;
        if let Some(rest) =
            strip_word(s, INTERJECTIONS, true).or_else(|| strip_word(s, COMMA_ONLY, false))
        {
            s = rest;
        }
        if let Some(rest) = strip_word(s, LEAD_INS, true) {
            s = rest;
            stripped = true;
        }
        if s == before {
            break;
        }
        stripped = true;
    }
    let bare = s.trim_end_matches(|c: char| is_trailing(c)).trim();
    if FILLER.contains(&bare.to_lowercase().as_str()) {
        return Lead::Filler;
    }
    let mut out = s.to_string();
    if stripped {
        out = capitalize(&out);
    }
    Lead::Line(out)
}

/// `s` without one of `words` at its start (case-insensitive), when what follows is a comma,
/// a dash, a stop or the end, or (`space_ok`) a space.
fn strip_word<'a>(s: &'a str, words: &[&str], space_ok: bool) -> Option<&'a str> {
    let lower = s.to_lowercase();
    // Lowercasing can change byte lengths outside ASCII; only compare when it didn't.
    if lower.len() != s.len() {
        return None;
    }
    let mut best: Option<&'a str> = None;
    for w in words {
        let Some(after_l) = lower.strip_prefix(*w).or_else(|| {
            // The curly apostrophe models often write.
            lower.strip_prefix(w.replace('\'', "’").as_str())
        }) else {
            continue;
        };
        let after = &s[s.len() - after_l.len()..];
        let next = after.chars().next();
        let rest = match next {
            None => Some(after),
            Some(',' | '—' | '–' | '.' | '!' | '…' | ';') => {
                Some(after.trim_start_matches([',', '—', '–', '.', '!', '…', ';']))
            }
            Some(' ') => {
                let t = after.trim_start();
                if t.starts_with(['-', '—', '–']) {
                    Some(t.trim_start_matches(['-', '—', '–']))
                } else if space_ok {
                    Some(t)
                } else {
                    None
                }
            }
            _ => None,
        };
        if let Some(rest) = rest {
            // The longest match wins ("ok so" over "ok").
            if best.is_none_or(|b| rest.len() < b.len()) {
                best = Some(rest.trim_start());
            }
        }
    }
    best
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
        None => String::new(),
    }
}

fn is_trailing(c: char) -> bool {
    matches!(
        c,
        '.' | ','
            | ';'
            | ':'
            | '!'
            | '?'
            | '…'
            | '-'
            | '–'
            | '—'
            | '。'
            | '，'
            | '：'
            | '；'
            | '！'
            | '？'
    ) || c.is_whitespace()
}

/// The finished line, or `None` when it doesn't qualify (rule 4).
fn accept(line: &str) -> Option<String> {
    let line = line.trim_end_matches(is_trailing).trim();
    if is_list_item(line) || is_code_sentence(line) {
        return None;
    }
    // Checked on what would show: a cut or a dropped quote can leave too little.
    let line = shorten(&capitalize_word(&balance_quotes(line)));
    let visible: Vec<char> = line.chars().filter(|c| !c.is_whitespace()).collect();
    let letters = visible.iter().filter(|c| c.is_alphabetic()).count();
    if visible.is_empty() || letters * 2 < visible.len() || words(&line) < 3 {
        return None;
    }
    Some(line)
}

/// A sentence that is a line of code: an assignment, arrow or path together with a call.
fn is_code_sentence(line: &str) -> bool {
    let ops = [" = ", " == ", " != ", " => ", " -> ", "::", " += ", " := "];
    ops.iter().any(|o| line.contains(o)) && line.contains('(') && line.contains(')')
}

/// A line cut inside a quotation loses the quote mark it can't close.
fn balance_quotes(line: &str) -> String {
    let mut out = line.to_string();
    for (open, close) in [('"', '"'), ('“', '”'), ('«', '»'), ('「', '」')] {
        let opens = out.chars().filter(|&c| c == open).count();
        let closes = out.chars().filter(|&c| c == close).count();
        let unmatched = if open == close {
            opens % 2 == 1
        } else {
            opens > closes
        };
        if unmatched && let Some(i) = out.rfind(open) {
            out.remove(i);
            out = out.split_whitespace().collect::<Vec<_>>().join(" ");
        }
    }
    out
}

/// A line starting with a plain lowercase word starts with a capital ("how to" → "How to");
/// a word with capitals, digits or marks in it (`iPhone`, `cargo.toml`) is left alone.
fn capitalize_word(line: &str) -> String {
    let first = line.split_whitespace().next().unwrap_or("");
    if first.chars().any(char::is_lowercase)
        && first.chars().all(|c| c.is_lowercase() || "'’-".contains(c))
    {
        capitalize(line)
    } else {
        line.to_string()
    }
}

/// Words, counting each character of a script written without spaces (Chinese, Japanese) as one.
fn words(s: &str) -> usize {
    let wide = s.chars().filter(|&c| is_wide(c)).count();
    let spaced = s
        .split_whitespace()
        .filter(|w| w.chars().any(|c| c.is_alphanumeric() && !is_wide(c)))
        .count();
    wide + spaced
}

fn is_wide(c: char) -> bool {
    matches!(c as u32,
        0x3040..=0x30FF   // Hiragana, Katakana
        | 0x3400..=0x4DBF // CJK extension A
        | 0x4E00..=0x9FFF // CJK unified
        | 0xF900..=0xFAFF
        | 0xAC00..=0xD7AF // Hangul syllables (spaced, but short words)
        | 0x0E00..=0x0E7F // Thai
    )
}

/// A line over [`MAX_CHARS`] characters, cut at the last clause break past a third of the way
/// (`, `, `; `, ` — `, ` (`), or else at the last word that fits, with an ellipsis.
fn shorten(line: &str) -> String {
    if line.chars().count() <= MAX_CHARS {
        return line.to_string();
    }
    let cut: String = line.chars().take(MAX_CHARS).collect();
    let floor = cut.len() / 3;
    let clause = [", ", "; ", " — ", " – ", " - ", " (", "，", "；"]
        .iter()
        .filter_map(|m| cut.rfind(m))
        .filter(|&i| i >= floor)
        .max();
    if let Some(i) = clause {
        return cut[..i].trim_end_matches(is_trailing).to_string();
    }
    let room: String = line.chars().take(MAX_CHARS - 1).collect();
    let word = room
        .rfind(' ')
        .filter(|&i| i >= floor)
        .unwrap_or(room.len());
    format!("{}…", room[..word].trim_end_matches(is_trailing))
}

/// The thought line fed one streamed chunk at a time, throttled to one change per
/// [`INTERVAL_MS`]. Kept per model-call attempt, so a retried call starts clean.
#[derive(Default)]
pub struct Thoughts {
    text: String,
    scanner: Scanner,
    /// Lines shown so far, with byte ranges into `text`.
    shown: Vec<(Pick, u64)>,
    /// When the first chunk arrived and when the line last changed (caller's clock, ms).
    first: Option<u64>,
    last: Option<u64>,
}

impl Thoughts {
    /// Add `chunk`, arriving at `now` ms on any clock that doesn't run backwards. Returns the
    /// new line when it changes now.
    pub fn push(&mut self, chunk: &str, now: u64) -> Option<String> {
        let first = *self.first.get_or_insert(now);
        self.text.push_str(chunk);
        // A paragraph only finishes at a newline or a tag's `>`.
        if chunk.contains(['\n', '>']) {
            self.scanner.scan(&self.text);
        }
        let best = self.scanner.best.as_ref()?;
        if let Some((last, _)) = self.shown.last() {
            if last.start == best.start || last.line == best.line {
                return None;
            }
        }
        if self
            .last
            .is_some_and(|t| now.saturating_sub(t) < INTERVAL_MS)
        {
            return None;
        }
        self.last = Some(now);
        self.shown.push((best.clone(), now.saturating_sub(first)));
        Some(best.line.clone())
    }

    /// The reasoning streamed so far.
    pub fn text(&self) -> &str {
        &self.text
    }

    /// The lines shown, with their paragraphs as UTF-16 ranges into `text`, the completed
    /// item's text. That is normally what streamed; if the provider's final text differs, each
    /// paragraph is looked up in it, and a line whose paragraph isn't there is left out.
    pub fn shown(&self, text: &str) -> Vec<ShownThought> {
        let same = text == self.text;
        let mut from = 0;
        let mut out = Vec::new();
        for (p, ms) in &self.shown {
            let (start, end) = if same {
                (p.start, p.end)
            } else {
                let para = &self.text[p.start..p.end];
                match text[from..].find(para) {
                    Some(i) => (from + i, from + i + para.len()),
                    None => continue,
                }
            };
            from = start;
            out.push(ShownThought {
                text: p.line.clone(),
                start: utf16(text, start),
                end: utf16(text, end),
                ms: *ms,
            });
        }
        out
    }
}

/// A byte offset into `s` as a UTF-16 offset.
fn utf16(s: &str, byte: usize) -> u32 {
    s[..byte].encode_utf16().count() as u32
}

#[cfg(test)]
#[path = "thought_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "thought_measure.rs"]
mod measure;
