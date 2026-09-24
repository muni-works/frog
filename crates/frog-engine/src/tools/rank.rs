//! Grep-like ranking of text chunks against a query, for WebFetch and Docs. No model calls:
//! query terms are scored by how rare they are across the chunks, with extra weight for hits
//! in a chunk's heading and for chunks that contain every term.

use std::collections::HashSet;

/// A piece of a document: a heading (or an item's signature) and the text under it.
#[derive(Clone, Debug, Default)]
pub struct Chunk {
    pub heading: String,
    pub body: String,
    /// Where it came from, e.g. `src/lib.rs:42`. Empty for web pages.
    pub loc: String,
}

impl Chunk {
    /// Bytes it takes up in output.
    pub fn size(&self) -> usize {
        self.heading.len() + self.body.len() + self.loc.len()
    }
}

const STOP: &[&str] = &[
    "a", "an", "and", "are", "as", "at", "be", "by", "can", "do", "does", "for", "from", "how",
    "i", "in", "is", "it", "of", "on", "or", "the", "this", "to", "use", "what", "when", "with",
];

/// Lowercase search terms: words of two or more characters, minus common filler.
/// `Client::builder` gives `client` and `builder`.
pub fn terms(query: &str) -> Vec<String> {
    let mut seen = HashSet::new();
    query
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .map(str::to_lowercase)
        .filter(|t| t.chars().count() >= 2 && !STOP.contains(&t.as_str()))
        .filter(|t| seen.insert(t.clone()))
        .collect()
}

fn count(hay: &str, needle: &str) -> usize {
    hay.matches(needle).take(8).count()
}

/// Score each chunk; zero means no term matched.
pub fn scores(chunks: &[Chunk], terms: &[String]) -> Vec<f32> {
    if terms.is_empty() {
        return vec![0.0; chunks.len()];
    }
    let lower: Vec<(String, String)> = chunks
        .iter()
        .map(|c| (c.heading.to_lowercase(), c.body.to_lowercase()))
        .collect();
    let n = chunks.len() as f32;
    let idf: Vec<f32> = terms
        .iter()
        .map(|t| {
            let df = lower
                .iter()
                .filter(|(h, b)| h.contains(t.as_str()) || b.contains(t.as_str()))
                .count() as f32;
            (1.0 + n / (1.0 + df)).ln()
        })
        .collect();
    lower
        .iter()
        .map(|(h, b)| {
            let mut s = 0.0;
            let mut matched = 0;
            for (t, w) in terms.iter().zip(&idf) {
                let (th, tb) = (count(h, t), count(b, t));
                if th + tb == 0 {
                    continue;
                }
                matched += 1;
                if th > 0 {
                    s += 2.0 * w;
                }
                if tb > 0 {
                    s += w * (1.0 + (tb as f32).ln());
                }
            }
            let coverage = matched as f32 / terms.len() as f32;
            // Long chunks match more by chance.
            s * coverage * coverage / (1.0 + (h.len() + b.len()) as f32 / 4_000.0)
        })
        .collect()
}

/// The best chunks for `query` that fit in `budget` bytes, best first. Chunks that match no
/// term are never picked.
pub fn top(chunks: &[Chunk], query: &str, budget: usize) -> Vec<usize> {
    let s = scores(chunks, &terms(query));
    let mut order: Vec<usize> = (0..chunks.len()).filter(|&i| s[i] > 0.0).collect();
    order.sort_by(|&a, &b| s[b].total_cmp(&s[a]).then(a.cmp(&b)));
    let mut used = 0;
    let mut out = Vec::new();
    for i in order {
        let len = chunks[i].size() + 8;
        if used + len > budget {
            // One oversized best hit still beats nothing.
            if out.is_empty() {
                out.push(i);
            }
            continue;
        }
        used += len;
        out.push(i);
    }
    out
}

/// Split markdown into chunks under their nearest heading, each at most about `max` bytes,
/// breaking only between paragraphs and never inside a code fence.
pub fn markdown_chunks(md: &str, max: usize) -> Vec<Chunk> {
    let mut chunks = Vec::new();
    let mut heading = String::new();
    let mut para = String::new();
    let mut body = String::new();
    let mut fence = false;
    let flush_body = |heading: &str, body: &mut String, chunks: &mut Vec<Chunk>| {
        if !body.trim().is_empty() {
            chunks.push(Chunk {
                heading: heading.to_string(),
                body: body.trim().to_string(),
                loc: String::new(),
            });
        }
        body.clear();
    };
    let push_para =
        |heading: &str, para: &mut String, body: &mut String, chunks: &mut Vec<Chunk>| {
            if para.trim().is_empty() {
                para.clear();
                return;
            }
            if !body.is_empty() && body.len() + para.len() > max {
                flush_body(heading, body, chunks);
            }
            body.push_str(para.trim_end());
            body.push_str("\n\n");
            para.clear();
        };
    for line in md.lines() {
        let t = line.trim_start();
        if t.starts_with("```") || t.starts_with("~~~") {
            fence = !fence;
        }
        if !fence && t.starts_with('#') && t.trim_start_matches('#').starts_with(' ') {
            push_para(&heading, &mut para, &mut body, &mut chunks);
            flush_body(&heading, &mut body, &mut chunks);
            heading = t.trim_start_matches('#').trim().to_string();
            continue;
        }
        if !fence && t.is_empty() {
            push_para(&heading, &mut para, &mut body, &mut chunks);
            continue;
        }
        para.push_str(line);
        para.push('\n');
    }
    push_para(&heading, &mut para, &mut body, &mut chunks);
    flush_body(&heading, &mut body, &mut chunks);
    chunks
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: &str = "# Guide\n\nIntro text about the library.\n\n## Installation\n\nRun cargo add widget.\n\n## Timeouts\n\nSet a timeout with `Client::builder().timeout(d)`.\n\n```rust\nlet c = Client::builder()\n\n    .timeout(Duration::from_secs(5));\n```\n\n## Proxies\n\nProxies are read from the environment.\n";

    #[test]
    fn splits_under_headings_and_keeps_fences_whole() {
        let chunks = markdown_chunks(PAGE, 10_000);
        let heads: Vec<&str> = chunks.iter().map(|c| c.heading.as_str()).collect();
        assert_eq!(heads, ["Guide", "Installation", "Timeouts", "Proxies"]);
        assert!(
            chunks[2]
                .body
                .contains("```rust\nlet c = Client::builder()\n\n    .timeout")
        );
        // A small budget splits between paragraphs, not inside the fence.
        let small = markdown_chunks(PAGE, 20);
        assert!(
            small
                .iter()
                .any(|c| c.heading == "Timeouts" && c.body.starts_with("```rust"))
        );
    }

    #[test]
    fn query_picks_the_matching_section() {
        let chunks = markdown_chunks(PAGE, 10_000);
        let hits = top(&chunks, "how do I set a timeout?", 10_000);
        assert_eq!(chunks[hits[0]].heading, "Timeouts");
        assert!(hits.iter().all(|&i| chunks[i].heading != "Installation"));
        assert!(top(&chunks, "graphql", 10_000).is_empty());
        assert_eq!(
            terms("Client::builder and the timeout"),
            ["client", "builder", "timeout"]
        );
    }
}
