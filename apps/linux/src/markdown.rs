//! Just enough Markdown for frog's answers: paragraphs with **bold**, *italic*, `code` and
//! [links](url) as Pango markup, headings, lists, and fenced code blocks (drawn separately, in
//! a source view).

pub enum Block {
    Text(String),
    Code { lang: String, code: String },
}

pub fn blocks(md: &str) -> Vec<Block> {
    let mut out = Vec::new();
    let mut text = String::new();
    let mut code: Option<(String, String)> = None;
    for line in md.lines() {
        let fence = line.trim_start().starts_with("```");
        match (&mut code, fence) {
            (Some(_), true) => {
                let (lang, c) = code.take().unwrap();
                out.push(Block::Code { lang, code: c.trim_end_matches('\n').to_string() });
            }
            (Some((_, c)), false) => {
                c.push_str(line);
                c.push('\n');
            }
            (None, true) => {
                flush(&mut text, &mut out);
                code = Some((line.trim_start().trim_start_matches('`').trim().to_string(), String::new()));
            }
            (None, false) => {
                text.push_str(line);
                text.push('\n');
            }
        }
    }
    if let Some((lang, c)) = code {
        out.push(Block::Code { lang, code: c.trim_end_matches('\n').to_string() });
    }
    flush(&mut text, &mut out);
    out
}

fn flush(text: &mut String, out: &mut Vec<Block>) {
    let t = text.trim_matches('\n');
    if !t.trim().is_empty() {
        out.push(Block::Text(markup(t)));
    }
    text.clear();
}

pub fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// Pango markup for a run of Markdown lines (no code fences).
pub fn markup(md: &str) -> String {
    let mut out = Vec::new();
    for line in md.lines() {
        let t = line.trim_start();
        let indent = &line[..line.len() - t.len()];
        let l = if let Some(h) = t.strip_prefix("### ").or(t.strip_prefix("## ")).or(t.strip_prefix("# ")) {
            format!("<b>{}</b>", inline(h))
        } else if let Some(item) = t.strip_prefix("- ").or(t.strip_prefix("* ")) {
            format!("{indent}•  {}", inline(item))
        } else {
            format!("{indent}{}", inline(t))
        };
        out.push(l);
    }
    out.join("\n")
}

fn inline(s: &str) -> String {
    let mut out = String::new();
    let mut rest = s;
    let (mut bold, mut italic) = (false, false);
    while let Some(c) = rest.chars().next() {
        if c == '`' {
            if let Some(end) = rest[1..].find('`') {
                out.push_str(&format!("<tt>{}</tt>", escape(&rest[1..1 + end])));
                rest = &rest[end + 2..];
                continue;
            }
        }
        if rest.starts_with("**") {
            out.push_str(if bold { "</b>" } else { "<b>" });
            bold = !bold;
            rest = &rest[2..];
            continue;
        }
        if c == '*' && (italic || rest[1..].contains('*')) && !rest[1..].starts_with(' ') {
            out.push_str(if italic { "</i>" } else { "<i>" });
            italic = !italic;
            rest = &rest[1..];
            continue;
        }
        if c == '[' {
            if let Some(close) = rest.find("](") {
                if let Some(end) = rest[close..].find(')') {
                    let label = &rest[1..close];
                    let url = &rest[close + 2..close + end];
                    out.push_str(&format!("<a href=\"{}\">{}</a>", escape(url).replace('"', "&quot;"), escape(label)));
                    rest = &rest[close + end + 1..];
                    continue;
                }
            }
        }
        out.push_str(&escape(&c.to_string()));
        rest = &rest[c.len_utf8()..];
    }
    if italic {
        out.push_str("</i>");
    }
    if bold {
        out.push_str("</b>");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inline_styles_and_escapes() {
        assert_eq!(markup("a **b** `<c>` [d](http://x)"), "a <b>b</b> <tt>&lt;c&gt;</tt> <a href=\"http://x\">d</a>");
        assert_eq!(markup("- one\n# Two"), "•  one\n<b>Two</b>");
        assert_eq!(markup("2 * 3 = 6"), "2 * 3 = 6");
    }

    #[test]
    fn fences_split_blocks() {
        let b = blocks("hi\n```rust\nfn x() {}\n```\nbye");
        assert_eq!(b.len(), 3);
        assert!(matches!(&b[1], Block::Code { lang, code } if lang == "rust" && code == "fn x() {}"));
    }
}
