//! Keeping the brief fresh while nothing of frog's is open: a LaunchAgent that runs
//! `frog --watch` from the moment you log in. It's yours to see and remove: one plist in
//! `~/Library/LaunchAgents`, logging to `~/Library/Logs/Frog/pond.log`.

use anyhow::{Context, Result, bail};
use std::path::{Path, PathBuf};
use std::process::Command;

pub const LABEL: &str = "eco.frog.pond";

/// Minutes between looks.
const EVERY: u64 = 15;

fn plist_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join("Library/LaunchAgents")
        .join(format!("{LABEL}.plist"))
}

fn log_path() -> PathBuf {
    dirs::home_dir().unwrap_or_default().join("Library/Logs/Frog/pond.log")
}

fn domain() -> String {
    format!("gui/{}", unsafe { libc::getuid() })
}

/// Whether the agent is installed, and the frog it runs.
pub fn status() -> Option<PathBuf> {
    let text = std::fs::read_to_string(plist_path()).ok()?;
    // The first <string> after ProgramArguments is the binary.
    let args = text.split("<key>ProgramArguments</key>").nth(1)?;
    let bin = args.split("<string>").nth(1)?.split("</string>").next()?;
    Some(PathBuf::from(unescape(bin)))
}

/// Install (or replace) the agent to run `bin --watch`, and start it.
pub fn on(bin: &Path) -> Result<()> {
    if !bin.is_absolute() || !bin.exists() {
        bail!("{} isn't a frog binary to run in the background", bin.display());
    }
    off()?;
    let plist = plist_path();
    std::fs::create_dir_all(plist.parent().context("no LaunchAgents folder")?)?;
    std::fs::create_dir_all(log_path().parent().context("no Logs folder")?)?;
    let home = dirs::home_dir().unwrap_or_default();
    // Launched agents get a bare PATH; `gh` (and the models' servers) live in the usual places.
    let path = format!(
        "{0}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        home.display()
    );
    std::fs::write(&plist, plist_text(bin, &path, &log_path()))?;
    let out = Command::new("launchctl")
        .args(["bootstrap", &domain()])
        .arg(&plist)
        .output()?;
    if !out.status.success() {
        bail!(
            "launchctl couldn't start it: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(())
}

/// Stop and remove the agent. Nothing to do when it isn't installed.
pub fn off() -> Result<()> {
    let plist = plist_path();
    if !plist.exists() {
        return Ok(());
    }
    // Fails harmlessly when it isn't loaded.
    let _ = Command::new("launchctl")
        .args(["bootout", &format!("{}/{LABEL}", domain())])
        .output();
    std::fs::remove_file(plist)?;
    Ok(())
}

fn plist_text(bin: &Path, path: &str, log: &Path) -> String {
    let s = |p: &Path| escape(&p.to_string_lossy());
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{bin}</string>
        <string>--watch</string>
        <string>{EVERY}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>{path}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>300</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{log}</string>
    <key>StandardErrorPath</key>
    <string>{log}</string>
</dict>
</plist>
"#,
        bin = s(bin),
        path = escape(path),
        log = s(log),
    )
}

fn escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn unescape(s: &str) -> String {
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_plist_runs_watch_and_its_binary_reads_back() {
        let text = plist_text(Path::new("/Apps/F & G.app/frog"), "/usr/bin", Path::new("/tmp/p.log"));
        assert!(text.contains("<string>/Apps/F &amp; G.app/frog</string>"));
        assert!(text.contains("<string>--watch</string>"));
        let bin = text.split("<key>ProgramArguments</key>").nth(1).unwrap().split("<string>").nth(1).unwrap().split("</string>").next().unwrap();
        assert_eq!(unescape(bin), "/Apps/F & G.app/frog");
    }
}
