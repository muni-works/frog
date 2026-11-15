//! Replay today's resolved permission prompts through the new permit() layers and
//! report what would still ask. Usage:
//!
//! ```sh
//! cargo run --example replay_asks -- prompts.json
//! ```
//!
//! Layer 1 only (no model): a command runs without asking when it's read-only
//! and touches no credentials. Everything else would go to the classifier (auto
//! mode) or the user, and is counted as "asks".

use std::io::Read;

#[derive(serde::Deserialize)]
struct Prompt {
    session: String,
    #[allow(dead_code)]
    perm_id: String,
    decision: String,
    name: String,
    input: serde_json::Value,
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: replay_asks prompts.json");
    let mut text = String::new();
    std::fs::File::open(&path)
        .unwrap_or_else(|e| panic!("opening {path}: {e}"))
        .read_to_string(&mut text)
        .unwrap();
    let prompts: Vec<Prompt> = serde_json::from_str(&text).unwrap();
    let bash: Vec<&Prompt> = prompts.iter().filter(|p| p.name == "Bash").collect();
    let mut rule = 0;
    let mut asks: Vec<&Prompt> = Vec::new();
    for p in &bash {
        let cmd = p.input["command"].as_str().unwrap_or("").trim();
        if !frog_engine::shell::touches_credentials(cmd) && frog_engine::shell::read_only(cmd) {
            rule += 1;
        } else {
            asks.push(p);
        }
    }
    println!("replayed {} resolved prompts ({} Bash)", prompts.len(), bash.len());
    println!("layer-1 rule (read-only, no credentials): {} would auto-run", rule);
    let creds = asks.iter().filter(|p| {
        frog_engine::shell::touches_credentials(p.input["command"].as_str().unwrap_or(""))
    })
    .count();
    println!(
        "would still ask: {} ({} for credential paths, {} gray-area: the classifier or user decides)",
        asks.len(),
        creds,
        asks.len() - creds
    );
    for p in &asks {
        let cmd = p.input["command"].as_str().unwrap_or("");
        let why = if frog_engine::shell::touches_credentials(cmd) {
            "credential path"
        } else {
            "write/network/unknown"
        };
        println!(
            "  [{}] {} :: {} :: {}",
            why,
            p.session,
            p.decision,
            cmd.replace('\n', "\\n").chars().take(120).collect::<String>()
        );
    }
}
