//! The frog window: sessions in a sidebar, the conversation, the composer, and the cards that
//! wait on you (permission, questions). One `frog --serve` per open conversation.

use crate::engine::{self, Link, Msg, Start};
use crate::widgets::{self, Message, Reasoning, Tool};
use adw::prelude::*;
use frog_engine::protocol::{Answer, Decision, Delta, EndReason, Envelope, Event, Item, ItemKind, Level, Op};
use gtk::{Align, Orientation, gio, glib, pango};
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::Rc;

#[derive(Default)]
struct State {
    link: Option<Link>,
    generation: u64,
    cwd: PathBuf,
    session: Option<String>,
    model: String,
    busy: bool,
    messages: HashMap<String, Message>,
    thoughts: HashMap<String, Reasoning>,
    tools: HashMap<String, Tool>,
    permission: Option<(String, String)>, // (request id, tool item id)
    question: Option<String>,
    queued: Vec<String>,
    sessions: Vec<serde_json::Value>,
    models: Vec<serde_json::Value>,
}

pub struct Win {
    pub window: adw::ApplicationWindow,
    split: adw::NavigationSplitView,
    content_page: adw::NavigationPage,
    title: adw::WindowTitle,
    stack: gtk::Stack,
    empty: adw::StatusPage,
    scroller: gtk::ScrolledWindow,
    transcript: gtk::Box,
    cards: gtk::Box,
    input: gtk::TextView,
    send: gtk::Button,
    stop: gtk::Button,
    progress: gtk::Label,
    model_label: gtk::Label,
    model_list: gtk::ListBox,
    model_popover: gtk::Popover,
    session_list: gtk::ListBox,
    status: gtk::Label,
    tx: async_channel::Sender<Msg>,
    state: RefCell<State>,
}

impl Win {
    pub fn new(app: &adw::Application) -> Rc<Self> {
        let (tx, rx) = async_channel::unbounded::<Msg>();

        // ---- sidebar: sessions
        let session_list = gtk::ListBox::new();
        session_list.add_css_class("navigation-sidebar");
        let side_scroll = gtk::ScrolledWindow::builder().child(&session_list).vexpand(true).build();
        let side_header = adw::HeaderBar::new();
        let new_button = gtk::Button::from_icon_name("list-add-symbolic");
        new_button.set_tooltip_text(Some("New Conversation"));
        new_button.set_action_name(Some("win.new"));
        side_header.pack_start(&new_button);
        let menu = gio::Menu::new();
        menu.append(Some("_Keyboard Shortcuts"), Some("app.shortcuts"));
        menu.append(Some("_About Frog"), Some("app.about"));
        let menu_button = gtk::MenuButton::builder().icon_name("open-menu-symbolic").menu_model(&menu).primary(true).build();
        menu_button.set_tooltip_text(Some("Main Menu"));
        side_header.pack_end(&menu_button);
        let side_view = adw::ToolbarView::new();
        side_view.add_top_bar(&side_header);
        side_view.set_content(Some(&side_scroll));
        let side_page = adw::NavigationPage::builder().title("Frog").tag("sidebar").child(&side_view).build();

        // ---- content: the conversation
        let title = adw::WindowTitle::new("New Conversation", "");
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&title));
        let model_label = gtk::Label::builder().ellipsize(pango::EllipsizeMode::Middle).max_width_chars(28).build();
        let model_box = gtk::Box::new(Orientation::Horizontal, 6);
        model_box.append(&model_label);
        model_box.append(&gtk::Image::from_icon_name("pan-down-symbolic"));
        let model_list = gtk::ListBox::new();
        model_list.add_css_class("navigation-sidebar");
        let model_search = gtk::SearchEntry::builder().placeholder_text("Search models").build();
        let model_pop_box = gtk::Box::new(Orientation::Vertical, 6);
        model_pop_box.append(&model_search);
        model_pop_box.append(
            &gtk::ScrolledWindow::builder()
                .child(&model_list)
                .propagate_natural_height(true)
                .max_content_height(420)
                .min_content_width(340)
                .hscrollbar_policy(gtk::PolicyType::Never)
                .build(),
        );
        let model_popover = gtk::Popover::builder().child(&model_pop_box).build();
        let model_button = gtk::MenuButton::builder().child(&model_box).popover(&model_popover).build();
        model_button.set_tooltip_text(Some("Model (Ctrl+K)"));
        model_button.add_css_class("flat");
        header.pack_end(&model_button);

        let transcript = gtk::Box::new(Orientation::Vertical, 14);
        transcript.add_css_class("frog-transcript");
        let progress = widgets::label("", &["dim-label", "caption"]);
        progress.set_margin_start(6);
        let column = gtk::Box::new(Orientation::Vertical, 14);
        column.append(&transcript);
        column.append(&progress);
        let clamp = adw::Clamp::builder().maximum_size(820).tightening_threshold(600).child(&column).build();
        clamp.set_margin_top(20);
        clamp.set_margin_bottom(12);
        clamp.set_margin_start(24);
        clamp.set_margin_end(24);
        let scroller = gtk::ScrolledWindow::builder().child(&clamp).hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).build();
        let empty = adw::StatusPage::builder().icon_name("eco.frog.Frog-symbolic").title("Frog").build();
        empty.add_css_class("compact");
        let stack = gtk::Stack::new();
        stack.set_transition_type(gtk::StackTransitionType::Crossfade);
        stack.add_named(&empty, Some("empty"));
        stack.add_named(&scroller, Some("transcript"));

        // the cards (permission, question) and the composer, pinned at the bottom
        let cards = gtk::Box::new(Orientation::Vertical, 8);
        let input = gtk::TextView::builder().wrap_mode(gtk::WrapMode::WordChar).accepts_tab(false).build();
        input.add_css_class("frog-input");
        let placeholder = widgets::label("Ask frog to do something", &["dim-label"]);
        placeholder.set_can_target(false);
        placeholder.set_valign(Align::Start);
        placeholder.set_margin_top(6);
        {
            let p = placeholder.clone();
            input.buffer().connect_changed(move |b| p.set_visible(b.char_count() == 0));
        }
        let input_overlay = gtk::Overlay::builder().child(&input).build();
        input_overlay.add_overlay(&placeholder);
        let input_scroll = gtk::ScrolledWindow::builder()
            .child(&input_overlay)
            .hscrollbar_policy(gtk::PolicyType::Never)
            .propagate_natural_height(true)
            .max_content_height(220)
            .hexpand(true)
            .build();
        let send = gtk::Button::from_icon_name("go-up-symbolic");
        send.add_css_class("circular");
        send.add_css_class("suggested-action");
        send.set_tooltip_text(Some("Send (Enter)"));
        send.set_valign(Align::End);
        let stop = gtk::Button::from_icon_name("media-playback-stop-symbolic");
        stop.add_css_class("circular");
        stop.set_tooltip_text(Some("Stop (Escape)"));
        stop.set_valign(Align::End);
        stop.set_visible(false);
        stop.set_action_name(Some("win.interrupt"));
        let composer = gtk::Box::new(Orientation::Horizontal, 8);
        composer.add_css_class("frog-composer");
        composer.append(&input_scroll);
        composer.append(&stop);
        composer.append(&send);
        let status = widgets::label("", &["dim-label", "caption", "numeric"]);
        status.set_halign(Align::Center);
        let bottom = gtk::Box::new(Orientation::Vertical, 8);
        bottom.append(&cards);
        bottom.append(&composer);
        bottom.append(&status);
        let bottom_clamp = adw::Clamp::builder().maximum_size(820).tightening_threshold(600).child(&bottom).build();
        bottom_clamp.set_margin_start(24);
        bottom_clamp.set_margin_end(24);
        bottom_clamp.set_margin_bottom(10);

        let content_view = adw::ToolbarView::new();
        content_view.add_top_bar(&header);
        content_view.set_content(Some(&stack));
        content_view.add_bottom_bar(&bottom_clamp);
        let content_page = adw::NavigationPage::builder().title("New Conversation").tag("content").child(&content_view).build();

        let split = adw::NavigationSplitView::builder()
            .sidebar(&side_page)
            .content(&content_page)
            .min_sidebar_width(240.0)
            .max_sidebar_width(320.0)
            .build();
        let window = adw::ApplicationWindow::builder()
            .application(app)
            .default_width(1180)
            .default_height(800)
            .width_request(360)
            .height_request(400)
            .title("Frog")
            .content(&split)
            .build();
        // narrow: the sidebar becomes its own page
        let bp = adw::Breakpoint::new(adw::BreakpointCondition::new_length(
            adw::BreakpointConditionLengthType::MaxWidth,
            640.0,
            adw::LengthUnit::Sp,
        ));
        bp.add_setter(&split, "collapsed", Some(&true.to_value()));
        window.add_breakpoint(bp);

        let me = Rc::new(Win {
            window,
            split,
            content_page,
            title,
            stack,
            empty,
            scroller,
            transcript,
            cards,
            input,
            send,
            stop,
            progress,
            model_label,
            model_list,
            model_popover,
            session_list,
            status,
            tx,
            state: RefCell::new(State {
                cwd: std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| "/".into()),
                ..Default::default()
            }),
        });
        me.wire(&model_search);

        // engine events into the main loop
        {
            let me = Rc::downgrade(&me);
            glib::spawn_future_local(async move {
                while let Ok(msg) = rx.recv().await {
                    let Some(me) = me.upgrade() else { return };
                    me.on_msg(msg);
                }
            });
        }
        me
    }

    fn wire(self: &Rc<Self>, model_search: &gtk::SearchEntry) {
        let w = &self.window;
        let action = |name: &str, f: Box<dyn Fn(&Rc<Win>)>| {
            let a = gio::SimpleAction::new(name, None);
            let me = Rc::downgrade(self);
            a.connect_activate(move |_, _| {
                if let Some(me) = me.upgrade() {
                    f(&me)
                }
            });
            w.add_action(&a);
        };
        action("new", Box::new(|me| me.start(Start::default())));
        action("interrupt", Box::new(|me| me.send(Op::Interrupt)));
        action("allow", Box::new(|me| me.decide(Decision::Allow)));
        action("deny", Box::new(|me| me.decide(Decision::Deny)));
        action("models", Box::new(|me| me.model_popover.popup()));
        action("focus", Box::new(|me| { me.input.grab_focus(); }));
        for (name, fork) in [("resume", false), ("fork", true)] {
            let a = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
            let me = Rc::downgrade(self);
            a.connect_activate(move |_, v| {
                let (Some(me), Some(id)) = (me.upgrade(), v.and_then(|v| v.str().map(String::from))) else { return };
                let cwd = me.session_cwd(&id);
                let start = if fork { Start { fork: Some(id), cwd, ..Default::default() } } else { Start { resume: Some(id), cwd, ..Default::default() } };
                me.start(start);
            });
            w.add_action(&a);
        }

        // closing the window ends its conversation's engine, and the app with it
        {
            let me = Rc::downgrade(self);
            self.window.connect_close_request(move |w| {
                if let Some(me) = me.upgrade() {
                    if let Some(l) = me.state.borrow_mut().link.take() {
                        l.stop();
                    }
                }
                if let Some(app) = w.application() {
                    app.quit();
                }
                glib::Propagation::Proceed
            });
        }

        // composer: Enter sends, Shift+Enter is a new line
        {
            let me = Rc::downgrade(self);
            let keys = gtk::EventControllerKey::new();
            keys.connect_key_pressed(move |_, key, _, mods| {
                let Some(me) = me.upgrade() else { return glib::Propagation::Proceed };
                if key == gtk::gdk::Key::Escape && me.state.borrow().busy {
                    me.send(Op::Interrupt);
                    return glib::Propagation::Stop;
                }
                let enter = matches!(key, gtk::gdk::Key::Return | gtk::gdk::Key::KP_Enter);
                if enter && !mods.contains(gtk::gdk::ModifierType::SHIFT_MASK) && !mods.contains(gtk::gdk::ModifierType::CONTROL_MASK) {
                    me.submit_input();
                    return glib::Propagation::Stop;
                }
                glib::Propagation::Proceed
            });
            self.input.add_controller(keys);
        }
        {
            let me = Rc::downgrade(self);
            self.send.connect_clicked(move |_| {
                if let Some(me) = me.upgrade() {
                    me.submit_input();
                }
            });
        }

        // sessions: click continues; right click offers continue or fork
        {
            let me = Rc::downgrade(self);
            self.session_list.connect_row_activated(move |_, row| {
                let Some(me) = me.upgrade() else { return };
                let id = row.widget_name().to_string();
                let _ = gtk::prelude::WidgetExt::activate_action(&me.window, "win.resume", Some(&id.to_variant()));
                me.split.set_show_content(true);
            });
        }

        // models: filter as you type, pick to switch
        {
            let search = model_search.clone();
            self.model_list.set_filter_func(move |row| {
                let q = search.text().to_lowercase();
                q.is_empty() || row.widget_name().to_lowercase().contains(&q)
            });
            let list = self.model_list.clone();
            model_search.connect_search_changed(move |_| list.invalidate_filter());
            let me = Rc::downgrade(self);
            self.model_list.connect_row_activated(move |_, row| {
                let Some(me) = me.upgrade() else { return };
                me.send(Op::SetModel { spec: row.widget_name().to_string() });
                me.model_popover.popdown();
            });
            let me = Rc::downgrade(self);
            let search = model_search.clone();
            self.model_popover.connect_show(move |_| {
                search.set_text("");
                search.grab_focus();
                if let Some(me) = me.upgrade() {
                    me.load_models();
                }
            });
            let me = Rc::downgrade(self);
            model_search.connect_activate(move |_| {
                let Some(me) = me.upgrade() else { return };
                let mut i = 0;
                while let Some(row) = me.model_list.row_at_index(i) {
                    if row.is_child_visible() {
                        row.activate();
                        return;
                    }
                    i += 1;
                }
            });
        }
    }

    // ---- conversations

    pub fn start(self: &Rc<Self>, start: Start) {
        let mut st = self.state.borrow_mut();
        if let Some(old) = st.link.take() {
            old.stop();
        }
        st.generation += 1;
        if let Some(c) = &start.cwd {
            st.cwd = c.clone();
        }
        st.session = start.resume.clone();
        st.busy = false;
        st.messages.clear();
        st.thoughts.clear();
        st.tools.clear();
        st.permission = None;
        st.question = None;
        st.model = start.model.clone().unwrap_or_default();
        let cwd = st.cwd.clone();
        let link = Link::spawn(st.generation, &start, &cwd, self.tx.clone());
        drop(st);
        while let Some(c) = self.transcript.first_child() {
            self.transcript.remove(&c);
        }
        self.clear_cards();
        self.set_title(None);
        self.set_busy(false);
        self.stack.set_visible_child_name(if start.resume.is_some() || start.fork.is_some() { "transcript" } else { "empty" });
        match link {
            Ok(l) => self.state.borrow_mut().link = Some(l),
            Err(e) => self.add(widgets::note(&format!("Couldn't start frog ({}): {e}", engine::frog_bin().display()), "error")),
        }
        self.update_empty();
        self.refresh_sessions();
        self.input.grab_focus();
    }

    fn session_cwd(&self, id: &str) -> Option<PathBuf> {
        self.state
            .borrow()
            .sessions
            .iter()
            .find(|s| s["id"] == id)
            .and_then(|s| s["cwd"].as_str())
            .map(PathBuf::from)
            .filter(|p| p.is_dir())
    }

    pub fn ask(self: &Rc<Self>, text: &str) {
        let fresh = {
            let st = self.state.borrow();
            !st.busy && st.messages.is_empty() && st.tools.is_empty() && self.transcript.first_child().is_none()
        };
        if !fresh {
            self.start(Start::default());
        }
        self.submit(text);
    }

    fn submit_input(self: &Rc<Self>) {
        let buf = self.input.buffer();
        let text = buf.text(&buf.start_iter(), &buf.end_iter(), false).to_string();
        if text.trim().is_empty() || self.state.borrow().busy {
            return;
        }
        buf.set_text("");
        self.submit(&text);
    }

    fn submit(self: &Rc<Self>, text: &str) {
        let t = text.trim();
        if let Some(cmd) = t.strip_prefix('!') {
            self.send(Op::Shell { command: cmd.to_string() });
        } else {
            self.send(Op::Submit { text: t.to_string(), images: vec![] });
        }
    }

    pub fn send(&self, op: Op) {
        if let Some(l) = self.state.borrow_mut().link.as_mut() {
            l.send(&op);
        }
    }

    fn decide(self: &Rc<Self>, d: Decision) {
        let Some((id, _)) = self.state.borrow().permission.clone() else { return };
        self.send(Op::Permission { id, decision: d });
    }

    // ---- events

    fn on_msg(self: &Rc<Self>, msg: Msg) {
        match msg {
            Msg::Event(g, env) if g == self.state.borrow().generation => self.on_event(*env),
            Msg::Exited(g, code, err) if g == self.state.borrow().generation => {
                self.state.borrow_mut().link = None;
                self.set_busy(false);
                if code != Some(0) {
                    let why = if err.is_empty() { String::new() } else { format!(":\n{err}") };
                    self.add(widgets::note(&format!("frog stopped ({}){why}", code.map_or("signal".into(), |c| c.to_string())), "error"));
                }
            }
            _ => {}
        }
    }

    fn on_event(self: &Rc<Self>, env: Envelope) {
        if self.state.borrow().session.is_none() && !env.session.is_empty() {
            self.state.borrow_mut().session = Some(env.session.clone());
            self.mark_current_session();
        }
        let follow = self.at_bottom();
        match env.event {
            Event::TurnStarted { input, .. } => {
                self.add(widgets::user_bubble(&input));
                self.set_busy(true);
            }
            Event::ItemStarted { id, kind } => match kind {
                ItemKind::Message => {
                    let m = Message::new();
                    self.add(m.root.clone());
                    self.state.borrow_mut().messages.insert(id, m);
                }
                ItemKind::Reasoning => {
                    let r = Reasoning::new();
                    r.root.set_visible(false);
                    self.add(r.root.clone());
                    self.state.borrow_mut().thoughts.insert(id, r);
                }
                ItemKind::ToolCall { name, arg } => {
                    let t = Tool::new(&name, &arg);
                    self.add(t.root.clone());
                    self.state.borrow_mut().tools.insert(id, t);
                }
            },
            Event::ItemDelta { id, delta } => {
                let mut st = self.state.borrow_mut();
                match delta {
                    Delta::Text { text } => {
                        if let Some(m) = st.messages.get_mut(&id) {
                            m.push(&text)
                        }
                    }
                    Delta::Reasoning { text } => {
                        if let Some(r) = st.thoughts.get_mut(&id) {
                            r.push(&text)
                        }
                    }
                    Delta::Output { text } => {
                        if let Some(t) = st.tools.get_mut(&id) {
                            t.push_output(&text)
                        }
                    }
                    Delta::ImagePreview { .. } => {}
                }
            }
            Event::ItemCompleted { id, item } => {
                let mut st = self.state.borrow_mut();
                match item {
                    Item::Message { text } => match st.messages.get_mut(&id) {
                        Some(m) => m.finish(&text),
                        None => {
                            let mut m = Message::new();
                            m.finish(&text);
                            drop(st);
                            self.add(m.root.clone());
                            self.state.borrow_mut().messages.insert(id, m);
                        }
                    },
                    Item::Reasoning { text } => {
                        if let Some(r) = st.thoughts.get_mut(&id) {
                            r.finish(&text)
                        }
                    }
                    Item::ToolCall { name, arg, outcome, output, display, diff, .. } => {
                        let shown = display.unwrap_or(output);
                        match st.tools.get_mut(&id) {
                            Some(t) => t.finish(outcome, &shown, diff.as_ref()),
                            None => {
                                let mut t = Tool::new(&name, &arg);
                                t.finish(outcome, &shown, diff.as_ref());
                                drop(st);
                                self.add(t.root.clone());
                                self.state.borrow_mut().tools.insert(id, t);
                            }
                        }
                    }
                }
            }
            Event::PermissionRequest { id, item, name, arg, always, preview, reason } => {
                if let Some(t) = self.state.borrow().tools.get(&item) {
                    t.waiting(true)
                }
                self.state.borrow_mut().permission = Some((id.clone(), item));
                self.permission_card(&id, &name, &arg, &always, preview.as_ref(), reason.as_deref());
            }
            Event::PermissionResolved { id, .. } => {
                let done = self.state.borrow().permission.as_ref().is_some_and(|p| p.0 == id);
                if done {
                    let taken = self.state.borrow_mut().permission.take();
                    if let Some((_, item)) = taken {
                        if let Some(t) = self.state.borrow().tools.get(&item) {
                            t.waiting(false)
                        }
                    }
                    self.clear_cards();
                }
            }
            Event::Question { id, question, options, multi, allow_other, .. } => {
                self.state.borrow_mut().question = Some(id.clone());
                self.question_card(&id, &question, &options, multi, allow_other);
            }
            Event::QuestionResolved { id, .. } => {
                if self.state.borrow().question.as_deref() == Some(id.as_str()) {
                    self.state.borrow_mut().question = None;
                    self.clear_cards();
                }
            }
            Event::TurnEnded { reason, .. } => {
                let note = match &reason {
                    EndReason::Complete => None,
                    EndReason::MaxTokens => Some(("Stopped at the output limit.", "warning")),
                    EndReason::Denied => Some(("Stopped: you denied a tool call.", "dim-label")),
                    EndReason::Looping => Some(("Stopped: the model kept repeating the same call.", "warning")),
                    EndReason::StepLimit => Some(("Stopped at the step limit.", "warning")),
                    EndReason::Cancelled => Some(("Interrupted.", "dim-label")),
                    EndReason::Error { .. } => None,
                };
                if let Some((t, c)) = note {
                    self.add(widgets::note(t, c));
                }
                if let EndReason::Error { error } = reason {
                    self.add(widgets::note(&error.to_string(), "error"));
                }
                self.state.borrow_mut().permission = None;
                self.state.borrow_mut().question = None;
                self.clear_cards();
                self.set_busy(false);
                self.refresh_sessions();
            }
            Event::Compacted { tokens_before, tokens_after } => {
                self.add(widgets::note(&format!("Compacted the conversation: {tokens_before} → {tokens_after} tokens."), "dim-label"))
            }
            Event::ModelChanged { model } => {
                self.state.borrow_mut().model = model;
                self.update_model();
            }
            Event::Titled { title } => self.set_title(Some(&title)),
            Event::FolderChanged { cwd } => {
                self.state.borrow_mut().cwd = cwd;
                self.update_subtitle();
            }
            Event::Progress { label } => self.progress.set_text(&label),
            Event::Notice { level, message } => self.add(widgets::note(
                &message,
                match level {
                    Level::Warn => "warning",
                    Level::Info => "dim-label",
                },
            )),
            Event::Error { error } => self.add(widgets::note(&error.to_string(), "error")),
            Event::Status(s) => {
                {
                    let mut st = self.state.borrow_mut();
                    st.model = s.model.clone();
                    st.cwd = s.cwd.clone();
                }
                self.update_model();
                self.update_subtitle();
                self.update_empty();
                let mut parts = vec![];
                if let (Some(t), w) = (s.context_tokens, s.context_window) {
                    if w > 0 {
                        parts.push(format!("{}% of context", (100 * t / w).min(100)));
                    }
                }
                if let Some(tps) = s.tokens_per_sec {
                    parts.push(format!("{tps:.0} tok/s"));
                }
                self.status.set_text(&parts.join("  ·  "));
            }
            Event::Idle => {
                self.set_busy(false);
                let next = self.state.borrow_mut().queued.pop();
                if let Some(t) = next {
                    self.submit(&t);
                }
            }
            _ => {}
        }
        if follow {
            self.scroll_to_end();
        }
    }

    // ---- view helpers

    fn add(&self, w: impl IsA<gtk::Widget>) {
        self.transcript.append(&w);
        self.stack.set_visible_child_name("transcript");
    }

    fn at_bottom(&self) -> bool {
        let a = self.scroller.vadjustment();
        a.value() + a.page_size() >= a.upper() - 48.0
    }

    fn scroll_to_end(&self) {
        let a = self.scroller.vadjustment();
        widgets::idle(move || a.set_value(a.upper() - a.page_size()));
    }

    fn set_busy(&self, busy: bool) {
        self.state.borrow_mut().busy = busy;
        self.stop.set_visible(busy);
        self.send.set_visible(!busy);
        if !busy {
            self.progress.set_text("");
        }
    }

    fn set_title(&self, t: Option<&str>) {
        let t = t.unwrap_or("New Conversation");
        self.title.set_title(t);
        self.content_page.set_title(t);
    }

    fn update_subtitle(&self) {
        let cwd = self.state.borrow().cwd.display().to_string();
        self.title.set_subtitle(&widgets::home(&cwd));
    }

    fn update_model(&self) {
        let m = self.state.borrow().model.clone();
        self.model_label.set_text(if m.is_empty() { "Model" } else { &m });
    }

    fn update_empty(&self) {
        let st = self.state.borrow();
        let mut d = String::new();
        if !st.model.is_empty() {
            d.push_str(&format!("Talking to <b>{}</b>\n", crate::markdown::escape(&st.model)));
        }
        d.push_str(&crate::markdown::escape(&widgets::home(&st.cwd.display().to_string())));
        self.empty.set_description(Some(&d));
    }

    fn clear_cards(&self) {
        while let Some(c) = self.cards.first_child() {
            self.cards.remove(&c);
        }
        self.input.set_sensitive(true);
    }

    fn permission_card(self: &Rc<Self>, id: &str, name: &str, arg: &str, always: &str, preview: Option<&frog_engine::protocol::FileDiff>, reason: Option<&str>) {
        self.clear_cards();
        let card = widgets::card("frog-permission");
        let icon = if name == "UseFolder" { "folder-symbolic" } else if reason.is_some() { "changes-allow-symbolic" } else { "dialog-warning-symbolic" };
        let q = widgets::permission_question(name, arg, reason.is_some(), preview.is_some_and(|p| p.created));
        card.append(&widgets::heading_row(icon, "warning", &q));
        if let Some(r) = reason {
            card.append(&widgets::label(r, &["dim-label"]));
        }
        if let Some(d) = preview {
            card.append(&widgets::diff_view(d, 240));
        } else if !arg.is_empty() {
            let l = widgets::label(arg, &["monospace", "frog-arg"]);
            l.set_selectable(true);
            l.set_lines(8);
            l.set_ellipsize(pango::EllipsizeMode::End);
            card.append(&l);
        }
        let buttons = gtk::Box::new(Orientation::Horizontal, 8);
        let allow = gtk::Button::builder().label("Allow").tooltip_text("Allow (Ctrl+Enter)").build();
        allow.add_css_class("suggested-action");
        allow.add_css_class("pill-small");
        allow.set_action_name(Some("win.allow"));
        buttons.append(&allow);
        if !always.is_empty() {
            let mut a = always.to_string();
            if let Some(f) = a.get(..1) {
                a = f.to_uppercase() + &a[1..];
            }
            let b = gtk::Button::with_label(&a);
            b.add_css_class("pill-small");
            let me = Rc::downgrade(self);
            b.connect_clicked(move |_| {
                if let Some(me) = me.upgrade() {
                    me.decide(Decision::AllowAlways)
                }
            });
            buttons.append(&b);
        }
        let spacer = gtk::Box::new(Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        buttons.append(&spacer);
        let deny = gtk::Button::builder().label("Deny").tooltip_text("Deny (Ctrl+.)").build();
        deny.add_css_class("pill-small");
        deny.set_action_name(Some("win.deny"));
        buttons.append(&deny);
        card.append(&buttons);
        let _ = id;
        self.cards.append(&card);
        allow.grab_focus();
    }

    fn question_card(self: &Rc<Self>, id: &str, question: &str, options: &[frog_engine::protocol::AskOption], multi: bool, allow_other: bool) {
        self.clear_cards();
        let card = widgets::card("frog-question");
        card.append(&widgets::heading_row("dialog-question-symbolic", "accent", question));
        let list = gtk::ListBox::new();
        list.add_css_class("boxed-list");
        list.set_selection_mode(gtk::SelectionMode::None);
        let checks: Rc<RefCell<Vec<(String, gtk::CheckButton)>>> = Rc::default();
        for o in options {
            let row = adw::ActionRow::builder().title(glib::markup_escape_text(&o.label)).activatable(true).build();
            if let Some(d) = &o.detail {
                row.set_subtitle(&glib::markup_escape_text(d));
            }
            if multi {
                let c = gtk::CheckButton::new();
                row.add_prefix(&c);
                row.set_activatable_widget(Some(&c));
                checks.borrow_mut().push((o.label.clone(), c));
            } else {
                row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
                let me = Rc::downgrade(self);
                let (id, label) = (id.to_string(), o.label.clone());
                row.connect_activated(move |_| {
                    if let Some(me) = me.upgrade() {
                        me.send(Op::Answer { id: id.clone(), answer: Answer { choices: vec![label.clone()], other: None } });
                    }
                });
            }
            list.append(&row);
        }
        card.append(&list);
        let other = gtk::Entry::builder().placeholder_text("Or type your own answer").hexpand(true).build();
        let buttons = gtk::Box::new(Orientation::Horizontal, 8);
        if allow_other {
            buttons.append(&other);
        } else {
            let s = gtk::Box::new(Orientation::Horizontal, 0);
            s.set_hexpand(true);
            buttons.append(&s);
        }
        let skip = gtk::Button::with_label("Skip");
        skip.add_css_class("pill-small");
        buttons.append(&skip);
        let answer = gtk::Button::with_label("Answer");
        answer.add_css_class("suggested-action");
        answer.add_css_class("pill-small");
        answer.set_visible(multi || allow_other);
        buttons.append(&answer);
        card.append(&buttons);
        {
            let me = Rc::downgrade(self);
            let id = id.to_string();
            skip.connect_clicked(move |_| {
                if let Some(me) = me.upgrade() {
                    me.send(Op::Answer { id: id.clone(), answer: Answer::default() });
                }
            });
        }
        {
            let me = Rc::downgrade(self);
            let id = id.to_string();
            let other2 = other.clone();
            let go = move || {
                let Some(me) = me.upgrade() else { return };
                let choices = checks.borrow().iter().filter(|(_, c)| c.is_active()).map(|(l, _)| l.clone()).collect();
                let t = other2.text().to_string();
                me.send(Op::Answer { id: id.clone(), answer: Answer { choices, other: (!t.trim().is_empty()).then_some(t) } });
            };
            let go = Rc::new(go);
            let g = go.clone();
            answer.connect_clicked(move |_| g());
            other.connect_activate(move |_| go());
        }
        self.cards.append(&card);
    }

    // ---- sessions and models

    pub fn refresh_sessions(self: &Rc<Self>) {
        let (tx, rx) = async_channel::bounded(1);
        engine::list(&["--sessions", "--all", "--json"], tx);
        let me = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(v) = rx.recv().await else { return };
            let Some(me) = me.upgrade() else { return };
            let mut all = v.as_array().cloned().unwrap_or_default();
            all.sort_by_key(|s| std::cmp::Reverse(s["modified"].as_i64().unwrap_or(0)));
            all.truncate(200);
            me.show_sessions(&all);
            me.state.borrow_mut().sessions = all;
        });
    }

    fn show_sessions(&self, all: &[serde_json::Value]) {
        while let Some(c) = self.session_list.first_child() {
            self.session_list.remove(&c);
        }
        let now = glib::DateTime::now_utc().map(|d| d.to_unix() * 1000).unwrap_or(0);
        for s in all {
            let id = s["id"].as_str().unwrap_or_default();
            let title = s["title"].as_str().or(s["first_input"].as_str()).unwrap_or("Untitled");
            let title: String = title.split_whitespace().collect::<Vec<_>>().join(" ");
            let cwd = s["cwd"].as_str().unwrap_or("");
            let folder = std::path::Path::new(cwd).file_name().and_then(|f| f.to_str()).unwrap_or(cwd);
            let age = ago(now - s["modified"].as_i64().unwrap_or(now));
            let b = gtk::Box::new(Orientation::Vertical, 2);
            b.set_margin_top(4);
            b.set_margin_bottom(4);
            let t = gtk::Label::builder().label(&title).xalign(0.0).ellipsize(pango::EllipsizeMode::End).build();
            b.append(&t);
            let sub = gtk::Label::builder().label(format!("{folder} · {age}")).xalign(0.0).ellipsize(pango::EllipsizeMode::End).build();
            sub.add_css_class("dim-label");
            sub.add_css_class("caption");
            b.append(&sub);
            let row = gtk::ListBoxRow::builder().child(&b).name(id).build();
            row.set_tooltip_text(Some(&widgets::home(cwd)));
            // right click: continue or fork
            let menu = gio::Menu::new();
            menu.append(Some("Continue"), Some(&format!("win.resume::{id}")));
            menu.append(Some("Fork"), Some(&format!("win.fork::{id}")));
            let pop = gtk::PopoverMenu::from_model(Some(&menu));
            pop.set_parent(&row);
            pop.set_has_arrow(false);
            let click = gtk::GestureClick::builder().button(3).build();
            click.connect_pressed(move |_, _, x, y| {
                pop.set_pointing_to(Some(&gtk::gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
                pop.popup();
            });
            row.add_controller(click);
            self.session_list.append(&row);
        }
        self.mark_current_session();
    }

    fn mark_current_session(&self) {
        let cur = self.state.borrow().session.clone();
        let mut i = 0;
        while let Some(row) = self.session_list.row_at_index(i) {
            if Some(row.widget_name().as_str()) == cur.as_deref() {
                self.session_list.select_row(Some(&row));
                return;
            }
            i += 1;
        }
        self.session_list.unselect_all();
    }

    fn load_models(self: &Rc<Self>) {
        let (tx, rx) = async_channel::bounded(1);
        engine::list(&["--models", "--json"], tx);
        let me = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(v) = rx.recv().await else { return };
            let Some(me) = me.upgrade() else { return };
            let all = v.as_array().cloned().unwrap_or_default();
            while let Some(c) = me.model_list.first_child() {
                me.model_list.remove(&c);
            }
            let current = me.state.borrow().model.clone();
            for m in &all {
                let spec = m["spec"].as_str().unwrap_or_default();
                let b = gtk::Box::new(Orientation::Horizontal, 8);
                b.set_margin_top(2);
                b.set_margin_bottom(2);
                let check = gtk::Image::from_icon_name("object-select-symbolic");
                check.set_opacity(if spec == current { 1.0 } else { 0.0 });
                b.append(&check);
                let col = gtk::Box::new(Orientation::Vertical, 0);
                col.set_hexpand(true);
                let name = m["info"]["name"].as_str().unwrap_or(spec);
                col.append(&gtk::Label::builder().label(name).xalign(0.0).ellipsize(pango::EllipsizeMode::End).build());
                if name != spec {
                    let s = gtk::Label::builder().label(spec).xalign(0.0).ellipsize(pango::EllipsizeMode::Middle).build();
                    s.add_css_class("dim-label");
                    s.add_css_class("caption");
                    col.append(&s);
                }
                b.append(&col);
                let src = [m["source"].as_str(), m["tier"].as_str()].into_iter().flatten().collect::<Vec<_>>().join(" · ");
                let tag = widgets::label(&src, &["dim-label", "caption"]);
                tag.set_wrap(false);
                b.append(&tag);
                let row = gtk::ListBoxRow::builder().child(&b).name(spec).build();
                me.model_list.append(&row);
            }
            me.state.borrow_mut().models = all;
        });
    }

    /// The window as a PNG, drawn by GTK itself (no compositor screenshot, no clipboard).
    pub fn shot(&self, path: &str) {
        let w = &self.window;
        let paintable = gtk::WidgetPaintable::new(Some(w));
        let (width, height) = (w.width() as f64, w.height() as f64);
        let snap = gtk::Snapshot::new();
        paintable.snapshot(&snap, width, height);
        let Some(node) = snap.to_node() else { return eprintln!("frog-app: nothing to draw yet") };
        let Some(renderer) = w.renderer() else { return eprintln!("frog-app: no renderer") };
        let tex = renderer.render_texture(&node, Some(&gtk::graphene::Rect::new(0.0, 0.0, width as f32, height as f32)));
        match tex.save_to_png(path) {
            Ok(()) => eprintln!("frog-app: saved {path}"),
            Err(e) => eprintln!("frog-app: couldn't save {path}: {e}"),
        }
    }
}

fn ago(ms: i64) -> String {
    let s = (ms / 1000).max(0);
    match s {
        0..60 => "now".into(),
        60..3600 => format!("{}m", s / 60),
        3600..86400 => format!("{}h", s / 3600),
        _ => format!("{}d", s / 86400),
    }
}
