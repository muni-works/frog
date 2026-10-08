//! frog for Linux: a GTK 4 + libadwaita app (eco.frog.Frog) that speaks `frog --serve`, as
//! the Mac app does, in frog's own look translated to GNOME's conventions.
//!
//!   frog-app [DIR]          open; new conversations work in DIR
//!   frog-app --new          a new conversation
//!   frog-app --ask TEXT     send TEXT in a new conversation
//!   frog-app --resume ID    continue session ID
//!   frog-app --shot PATH    save the window as a PNG (docs, tests)
//!   frog-app --allow        answer the open permission prompt (tests)
//!   frog-app --quit         close the window and end its conversation
//!
//! One instance per user (GApplication): a second launch hands its arguments to the first.

mod engine;
mod markdown;
mod widgets;
mod window;

use adw::prelude::*;
use engine::Start;
use gtk::{gio, glib};
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;

const APP_ID: &str = "eco.frog.Frog";
const CSS: &str = include_str!("style.css");

#[derive(Default, Debug)]
struct Args {
    dir: Option<PathBuf>,
    new: bool,
    ask: Option<String>,
    resume: Option<String>,
    shot: Option<String>,
    allow: bool,
    quit: bool,
}

fn parse(argv: &[std::ffi::OsString], cwd: Option<PathBuf>) -> Args {
    let mut a = Args::default();
    let argv: Vec<String> = argv.iter().skip(1).map(|s| s.to_string_lossy().into_owned()).collect();
    let mut i = 0;
    while i < argv.len() {
        match argv[i].as_str() {
            "--new" => a.new = true,
            "--allow" => a.allow = true,
            "--quit" => a.quit = true,
            "--ask" => {
                a.ask = Some(argv[i + 1..].join(" "));
                break;
            }
            "--resume" | "-r" => {
                a.resume = argv.get(i + 1).cloned();
                i += 1;
            }
            "--shot" => {
                a.shot = argv.get(i + 1).map(|p| abs(p, &cwd));
                i += 1;
            }
            p if !p.starts_with('-') => {
                let d = PathBuf::from(abs(p, &cwd));
                if d.is_dir() {
                    a.dir = Some(d);
                }
            }
            _ => {}
        }
        i += 1;
    }
    a
}

fn abs(p: &str, cwd: &Option<PathBuf>) -> String {
    let path = PathBuf::from(p);
    if path.is_absolute() { p.into() } else { cwd.clone().unwrap_or_default().join(path).display().to_string() }
}

fn main() -> glib::ExitCode {
    let app = adw::Application::builder()
        .application_id(APP_ID)
        .flags(gio::ApplicationFlags::HANDLES_COMMAND_LINE)
        .build();
    let win: Rc<RefCell<Option<Rc<window::Win>>>> = Rc::default();

    app.connect_startup(|app| {
        let css = gtk::CssProvider::new();
        css.load_from_string(CSS);
        gtk::style_context_add_provider_for_display(
            &gtk::gdk::Display::default().expect("a display"),
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        // the icons ship in the hicolor theme; a build tree finds them beside the binary too
        if let Some(theme) = gtk::gdk::Display::default().map(|d| gtk::IconTheme::for_display(&d)) {
            let here = std::env::current_exe().ok().and_then(|e| e.parent().map(|p| p.to_path_buf()));
            for dir in [here.map(|h| h.join("../share/icons")), Some(PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/data/icons")))].into_iter().flatten() {
                if dir.is_dir() {
                    theme.add_search_path(dir);
                }
            }
        }
        gtk::Window::set_default_icon_name(APP_ID);
        actions(app);
    });

    {
        let win = win.clone();
        app.connect_command_line(move |app, cmd| {
            let args = parse(&cmd.arguments(), cmd.cwd());
            let existing = win.borrow().clone();
            let w = match existing {
                Some(w) => w,
                None => {
                    let w = window::Win::new(app);
                    *win.borrow_mut() = Some(w.clone());
                    let start = Start {
                        cwd: args.dir.clone().or_else(|| std::env::var_os("FROG_APP_CWD").map(PathBuf::from)),
                        resume: args.resume.clone(),
                        ..Default::default()
                    };
                    w.start(start);
                    w.window.present();
                    if let Some(t) = &args.ask {
                        w.ask(t);
                    }
                    if let Some(p) = args.shot.clone() {
                        let w2 = w.clone();
                        glib::timeout_add_local_once(std::time::Duration::from_millis(1500), move || w2.shot(&p));
                    }
                    return glib::ExitCode::SUCCESS;
                }
            };
            if args.quit {
                w.window.close();
                return glib::ExitCode::SUCCESS;
            }
            w.window.present();
            if let Some(id) = &args.resume {
                let _ = gtk::prelude::WidgetExt::activate_action(&w.window, "win.resume", Some(&id.to_variant()));
            } else if args.new || args.dir.is_some() {
                w.start(Start { cwd: args.dir.clone(), ..Default::default() });
            }
            if let Some(t) = &args.ask {
                w.ask(t);
            }
            if args.allow {
                let _ = gtk::prelude::WidgetExt::activate_action(&w.window, "win.allow", None);
            }
            if let Some(p) = &args.shot {
                w.shot(p);
            }
            glib::ExitCode::SUCCESS
        });
    }
    app.run()
}

fn actions(app: &adw::Application) {
    let about = gio::SimpleAction::new("about", None);
    {
        let app = app.clone();
        about.connect_activate(move |_, _| {
            let d = adw::AboutDialog::builder()
                .application_name("Frog")
                .application_icon(APP_ID)
                .developer_name("Cam Pedersen")
                .version(env!("CARGO_PKG_VERSION"))
                .comments("A coding agent built for local models. Runs on tang, ollama or a cloud model.")
                .website("https://frog.eco")
                .issue_url("https://github.com/ecto/frog/issues")
                .license_type(gtk::License::Custom)
                .build();
            d.present(app.active_window().as_ref());
        });
    }
    app.add_action(&about);

    let shortcuts = gio::SimpleAction::new("shortcuts", None);
    {
        let app = app.clone();
        shortcuts.connect_activate(move |_, _| {
            let d = adw::ShortcutsDialog::new();
            let s = adw::ShortcutsSection::new(Some("Conversation"));
            for (title, accel) in [
                ("Send", "Return"),
                ("New line", "<Shift>Return"),
                ("Stop", "Escape"),
                ("New conversation", "<Control>n"),
                ("Choose a model", "<Control>k"),
                ("Allow", "<Control>Return"),
                ("Deny", "<Control>period"),
            ] {
                s.add(adw::ShortcutsItem::new(title, accel));
            }
            d.add(s);
            let g = adw::ShortcutsSection::new(Some("General"));
            for (title, accel) in [("Keyboard shortcuts", "<Control>question"), ("Quit", "<Control>q")] {
                g.add(adw::ShortcutsItem::new(title, accel));
            }
            d.add(g);
            d.present(app.active_window().as_ref());
        });
    }
    app.add_action(&shortcuts);

    let quit = gio::SimpleAction::new("quit", None);
    {
        let app = app.clone();
        quit.connect_activate(move |_, _| app.quit());
    }
    app.add_action(&quit);

    app.set_accels_for_action("app.shortcuts", &["<Control>question"]);
    app.set_accels_for_action("app.quit", &["<Control>q"]);
    app.set_accels_for_action("win.new", &["<Control>n"]);
    app.set_accels_for_action("win.models", &["<Control>k"]);
    app.set_accels_for_action("win.allow", &["<Control>Return"]);
    app.set_accels_for_action("win.deny", &["<Control>period"]);
}
