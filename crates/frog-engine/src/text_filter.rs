/// Hides `<tool_call>` markup that text-mode models stream as plain text.
#[derive(Default)]
pub struct TagFilter {
    pub buf: String,
    pub inside: bool,
}

impl TagFilter {
    const OPEN: &str = "<tool_call>";
    const CLOSE: &str = "</tool_call>";

    /// Returns the text that's safe to show. Holds back a trailing partial tag.
    pub fn push(&mut self, s: &str) -> String {
        self.buf.push_str(s);
        let mut out = String::new();
        loop {
            let tag = if self.inside { Self::CLOSE } else { Self::OPEN };
            if let Some(i) = self.buf.find(tag) {
                if !self.inside {
                    out.push_str(&self.buf[..i]);
                }
                self.buf.drain(..i + tag.len());
                self.inside = !self.inside;
                continue;
            }
            // Keep the longest suffix that could be the start of the tag.
            let keep = (1..tag.len())
                .rev()
                .find(|&n| self.buf.ends_with(&tag[..n]))
                .unwrap_or(0);
            let cut = self.buf.len() - keep;
            if !self.inside {
                out.push_str(&self.buf[..cut]);
            }
            self.buf.drain(..cut);
            return out;
        }
    }

    /// Whatever is left once the stream ends.
    pub fn finish(&mut self) -> String {
        let rest = std::mem::take(&mut self.buf);
        if self.inside { String::new() } else { rest }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn filters_tool_calls_across_chunks() {
        let mut f = super::TagFilter::default();
        let mut out = String::new();
        for chunk in [
            "Let me look.<tool",
            "_call>{\"name\":",
            "\"Read\"}</tool_",
            "call> done <",
        ] {
            out.push_str(&f.push(chunk));
        }
        out.push_str(&f.finish());
        assert_eq!(out, "Let me look. done <");
        assert!(!f.inside);
    }
}
