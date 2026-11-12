//! Visuals: self-contained HTML or SVG widgets the model writes with `Visualize`, drawn inline
//! in the transcript by a sandboxed web view (an iframe on the web, a WKWebView on Apple).
//!
//! The engine wraps the model's fragment in [`document`]: Frog's theme as CSS variables, base
//! styles, a Content-Security-Policy that blocks every network request except a few pinned
//! CDNs, and a tiny bridge that reports the content's height and offers `sendPrompt(text)`.
//! The finished document travels on the item, so session logs, replays and shared sessions
//! draw exactly what the user saw, without the client knowing anything about the shell.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

/// The widget as the model wrote it, plus the document clients load.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, JsonSchema)]
pub struct Widget {
    pub title: String,
    /// The model's HTML or SVG fragment (what "Source" shows).
    pub code: String,
    /// A complete HTML document wrapping `code`: load it into a sandboxed view as is.
    pub html: String,
}

/// Script and stylesheet hosts a widget may load from. Everything else is blocked.
pub const SCRIPT_HOSTS: &[&str] = &[
    "https://cdnjs.cloudflare.com",
    "https://cdn.jsdelivr.net",
    "https://unpkg.com",
];

/// The largest fragment accepted. Real widgets are 3–25 KB; this stops runaway output.
pub const MAX_CODE: usize = 200_000;

impl Widget {
    pub fn new(title: &str, code: &str) -> Self {
        let title = title.trim().to_string();
        let code = strip_fences(code).to_string();
        let html = document(&title, &code);
        Self { title, code, html }
    }

    pub fn is_svg(&self) -> bool {
        self.code.trim_start().starts_with("<svg")
    }
}

/// Models sometimes wrap the code in a Markdown fence; take it off.
fn strip_fences(code: &str) -> &str {
    let t = code.trim();
    let Some(rest) = t.strip_prefix("```") else {
        return t;
    };
    let body = rest.split_once('\n').map(|(_, b)| b).unwrap_or("");
    body.trim_end().strip_suffix("```").unwrap_or(body).trim()
}

/// Problems worth telling the model about, so it can fix them on the next call.
pub fn lint(code: &str) -> Vec<String> {
    let mut out = Vec::new();
    let lower = code.to_ascii_lowercase();
    if lower.contains("<!doctype") || lower.contains("<html") || lower.contains("<head") {
        out.push(
            "Send a fragment, not a whole document: no <!DOCTYPE>, <html>, <head> or <body>. The shell provides them."
                .into(),
        );
    }
    let mut blocked: Vec<String> = Vec::new();
    for attr in [
        "src=\"", "src='", "href=\"", "href='", "url(", "fetch(\"", "fetch('",
    ] {
        for (i, _) in lower.match_indices(attr) {
            let rest = &code[i + attr.len()..];
            let rest = rest.trim_start_matches(['"', '\'']);
            if !rest.starts_with("http") {
                continue;
            }
            let url: String = rest
                .chars()
                .take_while(|c| !matches!(c, '"' | '\'' | ')' | ' ' | '>'))
                .collect();
            let ok = SCRIPT_HOSTS.iter().any(|h| url.starts_with(h))
                || url.starts_with("https://fonts.googleapis.com")
                || url.starts_with("https://fonts.gstatic.com");
            if !ok && !blocked.contains(&url) {
                blocked.push(url);
            }
        }
    }
    if !blocked.is_empty() {
        out.push(format!(
            "These URLs will be blocked (widgets may only load scripts from {}): {}. Inline the data or draw it yourself.",
            SCRIPT_HOSTS.join(", "),
            blocked.join(", ")
        ));
    }
    if lower.contains("localstorage")
        || lower.contains("sessionstorage")
        || lower.contains("document.cookie")
    {
        out.push(
            "Storage and cookies aren't available in the sandbox; keep state in variables.".into(),
        );
    }
    if lower.contains("<script")
        && !lower.contains("prefers-reduced-motion")
        && lower.contains("requestanimationframe")
    {
        out.push("It animates: respect `matchMedia('(prefers-reduced-motion: reduce)')` (draw one still frame instead).".into());
    }
    out
}

fn escape_attr(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('"', "&quot;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The full document a client loads: theme, base styles, CSP, and the bridge around `code`.
pub fn document(title: &str, code: &str) -> String {
    let scripts = SCRIPT_HOSTS.join(" ");
    let csp = format!(
        "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' {scripts}; \
style-src 'unsafe-inline' https://fonts.googleapis.com {scripts}; \
font-src data: https://fonts.gstatic.com {scripts}; img-src data: blob:; media-src data: blob:; \
connect-src 'none'; frame-src 'none'; worker-src blob:; form-action 'none'; base-uri 'none'"
    );
    format!(
        r#"<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="{csp}">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>{SHELL_CSS}</style>
<script>{SHELL_JS}</script>
</head><body><div id="frog-widget">
{code}
</div></body></html>
"#,
        csp = escape_attr(&csp),
        title = escape_attr(title),
    )
}

/// Frog's tokens (design/tokens.json) and the widget kit the guide teaches: tiles, sliders,
/// toggles, segmented buttons. Light by default, true black in dark.
const SHELL_CSS: &str = r#"
:root{color-scheme:light dark;
--bg:transparent;--surface:#f4f4f4;--well:#ececec;--line:#e3e3e3;--line-strong:#d2d2d2;
--fg:#1b1d1a;--muted:#5e5e5e;--faint:#767676;--accent:#2e9e4f;--on-accent:#fff;
--c1:#2e9e4f;--c2:#3478e0;--c3:#d9622b;--c4:#8a5cd6;--c5:#c99a06;--c6:#d6457a;--c7:#159aa3;--c8:#6b7280;
--good:#2e9e4f;--bad:#c4513d;--warn:#c27c0e;
--font:"IBM Plex Sans",-apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;
--mono:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
--radius:10px;--radius-sm:6px}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){
--surface:#121212;--well:#1a1a1a;--line:#2a2a2a;--line-strong:#383838;
--fg:#ececec;--muted:#a3a3a3;--faint:#808080;--accent:#58cc6f;--on-accent:#0d1a10;
--c1:#58cc6f;--c2:#64a4ff;--c3:#f0834f;--c4:#a989f0;--c5:#e8bf3a;--c6:#f0709e;--c7:#3cc3cc;--c8:#9ca3af;
--good:#58cc6f;--bad:#e5775f;--warn:#e8a33a}}
:root[data-theme=dark]{
--surface:#121212;--well:#1a1a1a;--line:#2a2a2a;--line-strong:#383838;
--fg:#ececec;--muted:#a3a3a3;--faint:#808080;--accent:#58cc6f;--on-accent:#0d1a10;
--c1:#58cc6f;--c2:#64a4ff;--c3:#f0834f;--c4:#a989f0;--c5:#e8bf3a;--c6:#f0709e;--c7:#3cc3cc;--c8:#9ca3af;
--good:#58cc6f;--bad:#e5775f;--warn:#e8a33a}
*,*::before,*::after{box-sizing:border-box}
html,body{margin:0;padding:0;background:transparent;color:var(--fg);font:14px/1.45 var(--font);-webkit-font-smoothing:antialiased}
#frog-widget{padding:16px;max-width:100%;overflow:hidden}
svg{max-width:100%;height:auto;display:block}
svg text{fill:var(--fg);font-family:var(--font)}
canvas{max-width:100%;display:block}
button,input,select{font:inherit;color:inherit}
h1,h2,h3{font-weight:600;margin:0 0 8px}h3{font-size:14px}
p{margin:0 0 8px}
.muted{color:var(--muted)}.mono{font-family:var(--mono)}
.row{display:flex;align-items:center;gap:12px;flex-wrap:wrap}
.stack{display:flex;flex-direction:column;gap:10px}
.control{display:flex;align-items:center;gap:12px;margin:6px 0}
.control>label,.control>.label{min-width:84px;color:var(--fg)}
.control>output,.control>.value{min-width:64px;text-align:right;font-variant-numeric:tabular-nums}
input[type=range]{flex:1;min-width:120px;-webkit-appearance:none;appearance:none;height:4px;border-radius:2px;background:var(--line-strong);outline:none;margin:10px 0}
input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:18px;height:18px;border-radius:50%;background:var(--surface);border:1.5px solid var(--faint);cursor:pointer}
input[type=range]::-moz-range-thumb{width:18px;height:18px;border-radius:50%;background:var(--surface);border:1.5px solid var(--faint);cursor:pointer}
input[type=range]:focus-visible::-webkit-slider-thumb{outline:2px solid var(--accent);outline-offset:2px}
input[type=checkbox]{accent-color:var(--accent);width:15px;height:15px;margin:0}
.toggle{display:inline-flex;align-items:center;gap:7px;cursor:pointer;user-select:none}
select{background:var(--surface);border:1px solid var(--line);border-radius:var(--radius-sm);padding:7px 10px}
.seg{display:inline-flex;gap:6px;flex-wrap:wrap}
.seg button,.btn{background:transparent;border:1px solid var(--line-strong);border-radius:8px;padding:7px 14px;cursor:pointer}
.seg button[aria-pressed=true],.btn.on{border-color:var(--c2);color:var(--fg);box-shadow:inset 0 0 0 1px var(--c2)}
.seg button:hover,.btn:hover{background:var(--well)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-top:12px}
.tile{background:var(--surface);border-radius:var(--radius);padding:12px 14px;min-width:0}
.tile .k{color:var(--muted);font-size:13px}
.tile .v{font-size:24px;font-weight:600;font-variant-numeric:tabular-nums;line-height:1.25;overflow-wrap:anywhere}
.caption{color:var(--muted);font-size:13px;text-align:center;margin-top:6px}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:13px;color:var(--muted)}
.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}
@media (max-width:480px){#frog-widget{padding:12px}.control>label,.control>.label{min-width:64px}.tile .v{font-size:20px}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
"#;

/// Height reporting and the `sendPrompt` bridge. Speaks to an iframe parent with
/// `postMessage`, or to a WKWebView through `webkit.messageHandlers.frog`.
const SHELL_JS: &str = r#"
(function(){
  var wk = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.frog;
  function post(m){ m.frogWidget = 1; if (wk) wk.postMessage(JSON.stringify(m)); else if (window.parent !== window) window.parent.postMessage(m, '*'); }
  var last = 0;
  function report(){
    var el = document.getElementById('frog-widget');
    var h = Math.ceil(el ? el.getBoundingClientRect().height : document.documentElement.scrollHeight);
    if (h !== last) { last = h; post({type:'height', height:h}); }
  }
  window.frogReduceMotion = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  window.sendPrompt = function(text){
    text = String(text || '').trim().slice(0, 2000);
    if (!text) return false;
    // Only in answer to a click or key press: a widget can't talk on its own.
    if (navigator.userActivation && !navigator.userActivation.isActive) return false;
    post({type:'prompt', text:text});
    return true;
  };
  window.addEventListener('message', function(e){
    var d = e.data; if (!d || !d.frogHost) return;
    if (d.type === 'theme') document.documentElement.setAttribute('data-theme', d.theme);
  });
  window.addEventListener('error', function(e){ post({type:'error', message:String(e.message||e)}); });
  document.addEventListener('DOMContentLoaded', function(){
    report();
    if (window.ResizeObserver) new ResizeObserver(report).observe(document.getElementById('frog-widget'));
    window.addEventListener('load', report);
    post({type:'ready'});
  });
})();
"#;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_fragment_with_csp_and_bridge() {
        let w = Widget::new(" Casimir ", "<div class=\"tiles\"></div>");
        assert_eq!(w.title, "Casimir");
        assert!(w.html.contains("Content-Security-Policy"));
        assert!(w.html.contains("connect-src 'none'"));
        assert!(w.html.contains("window.sendPrompt"));
        assert!(w.html.contains("<div class=\"tiles\"></div>"));
        assert!(!w.is_svg());
        assert!(Widget::new("x", "  <svg viewBox='0 0 1 1'></svg>").is_svg());
    }

    #[test]
    fn strips_markdown_fences() {
        let w = Widget::new("t", "```html\n<p>hi</p>\n```");
        assert_eq!(w.code, "<p>hi</p>");
    }

    #[test]
    fn lints_documents_and_blocked_urls() {
        let l = lint("<!DOCTYPE html><script src=\"https://evil.example/x.js\"></script>");
        assert!(l.iter().any(|m| m.contains("fragment")));
        assert!(l.iter().any(|m| m.contains("evil.example")));
        let ok = lint("<script src=\"https://cdn.jsdelivr.net/npm/d3@7.9.0\"></script><p>x</p>");
        assert!(ok.is_empty(), "{ok:?}");
    }
}
