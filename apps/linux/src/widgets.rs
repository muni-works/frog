//! The transcript's pieces, in frog's own look (apps/FrogKit) drawn with GNOME's widgets:
//! your prompt as an accent bubble on the right, frog's answer as plain text, thinking folded
//! to one line, tool calls as a row (icon, name, argument, +/− or status, chevron) that opens
//! to its diff or output, and permission/question cards.

use crate::markdown;
use adw::prelude::*;
use frog_engine::protocol::{FileDiff, LineKind, ToolOutcome};
use gtk::{Align, Orientation, glib, pango};
use sourceview5::prelude::*;

pub fn label(text: &str, classes: &[&str]) -> gtk::Label {
    let l = gtk::Label::builder()
        .label(text)
        .xalign(0.0)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .build();
    for c in classes {
        l.add_css_class(c);
    }
    l
}

/// The source view style that matches the app's light or dark look.
pub fn scheme() -> Option<sourceview5::StyleScheme> {
    let dark = adw::StyleManager::default().is_dark();
    sourceview5::StyleSchemeManager::default().scheme(if dark { "Adwaita-dark" } else { "Adwaita" })
}

/// Read-only source text: code blocks, diffs, tool output. Grows with its content up to
/// `max_height`, then scrolls.
pub fn code_view(text: &str, lang: Option<&str>, max_height: i32) -> (gtk::ScrolledWindow, sourceview5::Buffer) {
    let buffer = sourceview5::Buffer::new(None);
    buffer.set_text(text);
    buffer.set_highlight_matching_brackets(false);
    if let Some(l) = lang.and_then(|l| sourceview5::LanguageManager::default().language(l)) {
        buffer.set_language(Some(&l));
    }
    if let Some(s) = scheme() {
        buffer.set_style_scheme(Some(&s));
    }
    {
        let buffer = buffer.clone();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(s) = scheme() {
                buffer.set_style_scheme(Some(&s));
            }
        });
    }
    let view = sourceview5::View::with_buffer(&buffer);
    view.set_editable(false);
    view.set_cursor_visible(false);
    view.set_monospace(true);
    view.set_top_margin(8);
    view.set_bottom_margin(8);
    view.set_left_margin(10);
    view.set_right_margin(10);
    view.add_css_class("frog-code");
    let scroll = gtk::ScrolledWindow::builder()
        .child(&view)
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .propagate_natural_height(true)
        .max_content_height(max_height)
        .build();
    scroll.add_css_class("frog-code-frame");
    (scroll, buffer)
}

/// A file change: its path and +/− over the hunks, as a highlighted diff.
pub fn diff_view(d: &FileDiff, max_height: i32) -> gtk::Box {
    let b = gtk::Box::new(Orientation::Vertical, 0);
    b.add_css_class("frog-diff");
    let head = gtk::Box::new(Orientation::Horizontal, 8);
    head.add_css_class("frog-diff-head");
    let path = gtk::Label::builder()
        .label(home(&d.path))
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(pango::EllipsizeMode::Start)
        .build();
    path.add_css_class("monospace");
    head.append(&path);
    if d.created {
        head.append(&label("new file", &["dim-label", "caption"]));
    }
    head.append(&stat(d.added, d.removed));
    b.append(&head);
    let mut text = String::new();
    for (i, h) in d.hunks.iter().enumerate() {
        if i > 0 {
            text.push_str("@@\n");
        }
        for l in &h.lines {
            text.push(match l.kind {
                LineKind::Add => '+',
                LineKind::Remove => '-',
                LineKind::Context => ' ',
            });
            text.push_str(&l.text);
            text.push('\n');
        }
    }
    let (view, _) = code_view(text.trim_end_matches('\n'), Some("diff"), max_height);
    b.append(&view);
    b
}

/// `+3 −1` in green and red, as the Mac app shows it.
pub fn stat(added: u32, removed: u32) -> gtk::Label {
    let l = gtk::Label::new(None);
    l.set_markup(&format!("<span foreground=\"#26a269\">+{added}</span> <span foreground=\"#e01b24\">−{removed}</span>"));
    l.add_css_class("caption");
    l.add_css_class("numeric");
    l
}

pub fn home(p: &str) -> String {
    match std::env::var("HOME") {
        Ok(h) if !h.is_empty() && p.starts_with(&h) => format!("~{}", &p[h.len()..]),
        _ => p.to_string(),
    }
}

/// Your message: an accent bubble on the right.
pub fn user_bubble(text: &str) -> gtk::Widget {
    let row = gtk::Box::new(Orientation::Horizontal, 0);
    row.set_halign(Align::End);
    row.set_margin_start(80);
    let l = label(text, &["frog-user"]);
    l.set_selectable(true);
    row.append(&l);
    row.upcast()
}

/// frog's answer: plain text while it streams, Markdown with highlighted code once done.
pub struct Message {
    pub root: gtk::Box,
    text: String,
    streaming: gtk::Label,
}

impl Message {
    pub fn new() -> Self {
        let root = gtk::Box::new(Orientation::Vertical, 10);
        root.add_css_class("frog-answer");
        let streaming = label("", &["frog-answer-text"]);
        streaming.set_selectable(true);
        root.append(&streaming);
        Message { root, text: String::new(), streaming }
    }

    pub fn push(&mut self, delta: &str) {
        self.text.push_str(delta);
        self.streaming.set_text(&self.text);
    }

    pub fn finish(&mut self, text: &str) {
        self.text = text.to_string();
        while let Some(c) = self.root.first_child() {
            self.root.remove(&c);
        }
        for b in markdown::blocks(&self.text) {
            match b {
                markdown::Block::Text(m) => {
                    let l = label("", &["frog-answer-text"]);
                    l.set_markup(&m);
                    l.set_selectable(true);
                    self.root.append(&l);
                }
                markdown::Block::Code { lang, code } => {
                    let lang = match lang.as_str() {
                        "" => None,
                        "sh" | "shell" | "bash" | "console" => Some("sh"),
                        "py" => Some("python3"),
                        "rs" => Some("rust"),
                        "ts" => Some("typescript"),
                        "js" => Some("js"),
                        l => Some(l),
                    };
                    let (v, _) = code_view(&code, lang, 420);
                    self.root.append(&v);
                }
            }
        }
    }
}

/// A thought, folded to one line ("Thought · …"); a click shows the rest.
pub struct Reasoning {
    pub root: gtk::Box,
    preview: gtk::Label,
    full: gtk::Label,
    text: String,
}

impl Reasoning {
    pub fn new() -> Self {
        let root = gtk::Box::new(Orientation::Vertical, 4);
        root.add_css_class("frog-thought");
        let button = gtk::Button::new();
        button.add_css_class("flat");
        button.add_css_class("frog-row-button");
        let head = gtk::Box::new(Orientation::Horizontal, 8);
        let icon = gtk::Image::from_icon_name("eco.frog.Frog-thought-symbolic");
        icon.add_css_class("dim-label");
        head.append(&icon);
        let title = label("Thought", &["dim-label", "caption-heading"]);
        title.set_wrap(false);
        head.append(&title);
        let preview = gtk::Label::builder()
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        preview.add_css_class("dim-label");
        preview.add_css_class("caption");
        head.append(&preview);
        let chevron = gtk::Image::from_icon_name("pan-end-symbolic");
        chevron.add_css_class("dim-label");
        head.append(&chevron);
        button.set_child(Some(&head));
        root.append(&button);
        let full = label("", &["dim-label", "caption"]);
        full.set_selectable(true);
        full.set_margin_start(26);
        let rev = gtk::Revealer::builder().child(&full).transition_type(gtk::RevealerTransitionType::SlideDown).build();
        root.append(&rev);
        button.connect_clicked(move |_| {
            let open = !rev.reveals_child();
            rev.set_reveal_child(open);
            chevron.set_icon_name(Some(if open { "pan-down-symbolic" } else { "pan-end-symbolic" }));
        });
        Reasoning { root, preview, full, text: String::new() }
    }

    pub fn push(&mut self, delta: &str) {
        self.text.push_str(delta);
        self.update();
    }

    pub fn finish(&mut self, text: &str) {
        self.text = text.to_string();
        self.update();
    }

    fn update(&self) {
        let t = self.text.trim();
        self.preview.set_text(&t.lines().last().unwrap_or("").chars().take(300).collect::<String>());
        self.full.set_text(t);
        self.root.set_visible(!t.is_empty());
    }
}

/// The SF Symbol names of FrogKit's ToolIcon, as Adwaita symbolic icons.
pub fn tool_icon(name: &str) -> &'static str {
    match name {
        "Bash" | "!" => "utilities-terminal-symbolic",
        "Read" => "text-x-generic-symbolic",
        "Write" => "document-new-symbolic",
        "Edit" => "document-edit-symbolic",
        "Glob" => "folder-saved-search-symbolic",
        "Grep" => "edit-find-symbolic",
        "TodoWrite" => "checkbox-checked-symbolic",
        "Image" | "Screenshot" => "image-x-generic-symbolic",
        "WebFetch" => "web-browser-symbolic",
        "WebSearch" => "system-search-symbolic",
        "Task" => "system-users-symbolic",
        "Ask" => "dialog-question-symbolic",
        "Docs" => "accessories-dictionary-symbolic",
        "UseFolder" => "folder-symbolic",
        n if n.starts_with("mcp__") => "application-x-addon-symbolic",
        _ => "applications-engineering-symbolic",
    }
}

pub fn tool_title(name: &str) -> String {
    match name {
        "!" => "Shell".into(),
        "Task" => "Subagent".into(),
        n if n.starts_with("mcp__") => {
            let parts: Vec<&str> = n[5..].split("__").collect();
            if parts.len() >= 2 { format!("{} › {}", parts[0], parts[1..].join("__")) } else { n[5..].into() }
        }
        n => n.into(),
    }
}

/// A tool call: one row that opens to what it did.
pub struct Tool {
    pub root: gtk::Box,
    name: String,
    summary: gtk::Box,
    status: gtk::Stack,
    detail: gtk::Box,
    revealer: gtk::Revealer,
    live: Option<(gtk::ScrolledWindow, sourceview5::Buffer)>,
    output: String,
    done: bool,
}

impl Tool {
    pub fn new(name: &str, arg: &str) -> Self {
        let root = gtk::Box::new(Orientation::Vertical, 6);
        root.add_css_class("frog-tool");
        let button = gtk::Button::new();
        button.add_css_class("flat");
        button.add_css_class("frog-row-button");
        let head = gtk::Box::new(Orientation::Horizontal, 8);
        let icon = gtk::Image::from_icon_name(tool_icon(name));
        icon.add_css_class("dim-label");
        head.append(&icon);
        let title = gtk::Label::new(Some(&tool_title(name)));
        title.add_css_class("frog-tool-name");
        head.append(&title);
        let a = gtk::Label::builder()
            .label(arg.split_whitespace().collect::<Vec<_>>().join(" "))
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(pango::EllipsizeMode::Middle)
            .build();
        a.add_css_class("monospace");
        a.add_css_class("dim-label");
        head.append(&a);
        let summary = gtk::Box::new(Orientation::Horizontal, 0);
        head.append(&summary);
        let status = gtk::Stack::new();
        let spinner = adw::Spinner::new();
        status.add_named(&spinner, Some("running"));
        let ok = gtk::Image::from_icon_name("object-select-symbolic");
        ok.add_css_class("success");
        status.add_named(&ok, Some("ok"));
        let ask = gtk::Image::from_icon_name("dialog-warning-symbolic");
        ask.add_css_class("warning");
        status.add_named(&ask, Some("ask"));
        status.add_named(&gtk::Box::new(Orientation::Horizontal, 0), Some("none"));
        status.set_visible_child_name("running");
        head.append(&status);
        let chevron = gtk::Image::from_icon_name("pan-end-symbolic");
        chevron.add_css_class("dim-label");
        head.append(&chevron);
        button.set_child(Some(&head));
        root.append(&button);
        let detail = gtk::Box::new(Orientation::Vertical, 6);
        let revealer = gtk::Revealer::builder().child(&detail).transition_type(gtk::RevealerTransitionType::SlideDown).build();
        root.append(&revealer);
        {
            let revealer = revealer.clone();
            let root = root.clone();
            button.connect_clicked(move |_| {
                let open = !revealer.reveals_child();
                revealer.set_reveal_child(open);
                chevron.set_icon_name(Some(if open { "pan-down-symbolic" } else { "pan-end-symbolic" }));
                if open { root.add_css_class("open") } else { root.remove_css_class("open") }
            });
        }
        Tool { root, name: name.into(), summary, status, detail, revealer, live: None, output: String::new(), done: false }
    }

    pub fn waiting(&self, on: bool) {
        if !self.done {
            self.status.set_visible_child_name(if on { "ask" } else { "running" });
        }
    }

    /// Live output while it runs: the tail of a command, shown open.
    pub fn push_output(&mut self, text: &str) {
        self.output.push_str(&strip_ansi(text));
        if self.live.is_none() {
            let (v, b) = code_view("", None, 150);
            self.detail.append(&v);
            self.revealer.set_reveal_child(true);
            self.live = Some((v, b));
        }
        if let Some((_, b)) = &self.live {
            let tail: String = self.output.chars().rev().take(6000).collect::<Vec<_>>().into_iter().rev().collect();
            b.set_text(&tail);
        }
    }

    pub fn finish(&mut self, outcome: ToolOutcome, display: &str, diff: Option<&FileDiff>) {
        self.done = true;
        while let Some(c) = self.detail.first_child() {
            self.detail.remove(&c);
        }
        self.live = None;
        self.revealer.set_reveal_child(false);
        let words = |t: &str, c: &str| {
            let l = label(t, &["caption", c]);
            l.set_wrap(false);
            l
        };
        match outcome {
            ToolOutcome::Denied => self.summary.append(&words("Denied", "warning")),
            ToolOutcome::Skipped => self.summary.append(&words("Skipped", "dim-label")),
            ToolOutcome::Error => self.summary.append(&words(
                if display.starts_with("refused") { "Repeated call refused" } else { "Failed" },
                "error",
            )),
            ToolOutcome::Ok => {
                if let Some(d) = diff {
                    self.summary.append(&stat(d.added, d.removed));
                } else if !display.is_empty() && !display.contains('\n') && display.len() < 60 {
                    self.summary.append(&words(display, "dim-label"));
                }
            }
        }
        self.status.set_visible_child_name(if outcome == ToolOutcome::Ok { "ok" } else { "none" });
        if let Some(d) = diff {
            self.detail.append(&diff_view(d, 360));
        } else if !display.trim().is_empty() {
            let lang = if self.name == "Read" { None } else { None::<&str> };
            let (v, _) = code_view(strip_ansi(display).trim_end(), lang, 300);
            self.detail.append(&v);
        }
    }
}

pub fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut it = s.chars().peekable();
    while let Some(c) = it.next() {
        if c == '\x1b' {
            match it.peek() {
                Some('[') => {
                    it.next();
                    for d in it.by_ref() {
                        if ('@'..='~').contains(&d) {
                            break;
                        }
                    }
                }
                Some(']') => {
                    for d in it.by_ref() {
                        if d == '\x07' {
                            break;
                        }
                    }
                }
                _ => {}
            }
            continue;
        }
        out.push(c);
    }
    out
}

/// A note in the transcript: an error, an interruption, a compaction.
pub fn note(text: &str, class: &str) -> gtk::Widget {
    let l = label(text, &["caption", class]);
    l.set_margin_start(6);
    l.upcast()
}

/// FrogKit's permission question for a tool call.
pub fn permission_question(name: &str, arg: &str, outside: bool, creating: bool) -> String {
    let file = std::path::Path::new(arg).file_name().and_then(|f| f.to_str()).unwrap_or(arg).to_string();
    match name {
        "Edit" => format!("Allow this edit to {file}?"),
        "Write" if creating => format!("Allow creating {file}?"),
        "Write" => format!("Allow rewriting {file}?"),
        "Bash" if outside => "Allow this command outside the sandbox?".into(),
        "Bash" => "Allow this command?".into(),
        "UseFolder" => format!("Move this conversation to {file}?"),
        n if n.starts_with("mcp__") => format!("Allow {}?", tool_title(n)),
        n => format!("Allow {n}?"),
    }
}

/// A card shell: rounded, tinted, padded (FrogKit's PermissionCard / question card).
pub fn card(class: &str) -> gtk::Box {
    let b = gtk::Box::new(Orientation::Vertical, 10);
    b.add_css_class("frog-card");
    b.add_css_class(class);
    b
}

pub fn heading_row(icon: &str, icon_class: &str, text: &str) -> gtk::Box {
    let h = gtk::Box::new(Orientation::Horizontal, 8);
    let i = gtk::Image::from_icon_name(icon);
    i.add_css_class(icon_class);
    h.append(&i);
    let l = label(text, &["heading"]);
    l.set_hexpand(true);
    h.append(&l);
    h
}

/// Run `f` once the main loop is idle (after layout), e.g. to scroll to the end.
pub fn idle(f: impl FnOnce() + 'static) {
    glib::idle_add_local_once(f);
}
