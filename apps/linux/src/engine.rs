//! One conversation's engine: a `frog --serve` child speaking `frog_engine::protocol` (Op
//! JSON lines in, Event JSON lines out), the same link the Mac app has. Lines are read on a
//! thread and handed to the main loop over a channel, tagged with the link's generation so a
//! replaced conversation's last lines never reach the new one.

use frog_engine::protocol::{Envelope, Op};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};

pub enum Msg {
    Event(u64, Box<Envelope>),
    Exited(u64, Option<i32>, String),
}

pub struct Link {
    child: Arc<Mutex<Child>>,
    stdin: Option<ChildStdin>,
}

/// How to start a conversation.
#[derive(Clone, Debug, Default)]
pub struct Start {
    pub cwd: Option<PathBuf>,
    pub resume: Option<String>,
    pub fork: Option<String>,
    pub model: Option<String>,
}

/// The frog binary: `FROG_BIN`, else beside this app, else on `PATH`.
pub fn frog_bin() -> PathBuf {
    if let Some(b) = std::env::var_os("FROG_BIN") {
        return b.into();
    }
    if let Some(dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf)) {
        let beside = dir.join("frog");
        if beside.is_file() {
            return beside;
        }
    }
    "frog".into()
}

/// Play a recorded session instead of a model (screenshots, design work).
pub fn replay() -> Option<String> {
    std::env::var("FROG_APP_REPLAY").ok().filter(|s| !s.is_empty())
}

impl Link {
    pub fn spawn(generation: u64, start: &Start, cwd: &Path, tx: async_channel::Sender<Msg>) -> std::io::Result<Self> {
        let mut cmd = Command::new(frog_bin());
        if let Some(r) = replay() {
            let speed = std::env::var("FROG_APP_SPEED").unwrap_or_else(|_| "4".into());
            cmd.args(["--replay", &r, "--replay-ask", "--speed", &speed]);
        } else {
            cmd.arg("--serve");
            if let Some(r) = &start.resume {
                cmd.args(["-r", r]);
            }
            if let Some(f) = &start.fork {
                cmd.args(["--fork", f]);
            }
            if let Some(m) = &start.model {
                cmd.args(["-m", m]);
            }
        }
        let mut child = cmd
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;
        let stdout = child.stdout.take().expect("piped");
        let stderr = child.stderr.take().expect("piped");
        let last_err = Arc::new(Mutex::new(String::new()));
        {
            let last_err = last_err.clone();
            std::thread::spawn(move || {
                for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                    if !line.trim().is_empty() {
                        // keep the last few lines: a startup failure explains itself in several
                        let mut e = last_err.lock().unwrap();
                        let mut lines: Vec<&str> = e.lines().collect();
                        lines.push(&line);
                        let keep = lines.len().saturating_sub(8);
                        *e = lines[keep..].join("\n");
                    }
                }
            });
        }
        let stdin = child.stdin.take();
        let child = Arc::new(Mutex::new(child));
        let waiter = child.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if !line.starts_with('{') {
                    continue;
                }
                match serde_json::from_str::<Envelope>(&line) {
                    Ok(env) => {
                        if tx.send_blocking(Msg::Event(generation, Box::new(env))).is_err() {
                            return;
                        }
                    }
                    Err(e) => eprintln!("frog-app: unreadable event ({e}): {}", &line[..line.len().min(200)]),
                }
            }
            // stdout closed: the child is exiting. Its status comes from waitpid below.
            let code = waiter.lock().unwrap().wait().ok().and_then(|s| s.code());
            let err = last_err.lock().unwrap().clone();
            let _ = tx.send_blocking(Msg::Exited(generation, code, err));
        });
        let mut link = Link { child, stdin };
        if replay().is_none() {
            // The window can put the model's questions to a person, so it gets `Ask`.
            link.send(&Op::SetClientCaps { panes: false, ask: true });
            if start.resume.is_some() || start.fork.is_some() {
                link.send(&Op::Subscribe { after: 0 });
            }
        }
        Ok(link)
    }

    pub fn send(&mut self, op: &Op) {
        let Some(stdin) = self.stdin.as_mut() else { return };
        let Ok(mut line) = serde_json::to_string(op) else { return };
        line.push('\n');
        if stdin.write_all(line.as_bytes()).and_then(|_| stdin.flush()).is_err() {
            self.stdin = None;
        }
    }

    /// Ask the engine to finish, then make sure it does.
    pub fn stop(mut self) {
        self.send(&Op::Shutdown);
        self.stdin = None;
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_secs(3));
            // still running after the grace period (the reader thread holds the lock while
            // it reaps an exiting child, so this waits for that instead of racing it)
            let mut c = self.child.lock().unwrap();
            if matches!(c.try_wait(), Ok(None)) {
                let _ = c.kill();
                let _ = c.wait();
            }
        });
    }
}

/// Read a frog CLI listing (`--sessions --all --json`, `--models --json`) on a thread.
pub fn list(args: &'static [&'static str], tx: async_channel::Sender<serde_json::Value>) {
    std::thread::spawn(move || {
        let out = Command::new(frog_bin()).args(args).stderr(Stdio::null()).output();
        let v = out
            .ok()
            .and_then(|o| serde_json::from_slice(&o.stdout).ok())
            .unwrap_or(serde_json::Value::Array(vec![]));
        let _ = tx.send_blocking(v);
    });
}
