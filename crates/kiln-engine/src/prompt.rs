use crate::config::{Config, config_dir};
use crate::message::{Block, Message};
use crate::provider::ToolSpec;
use regex::Regex;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

const BASE: &str = "You are Kiln, an interactive coding agent running in the user's terminal. \
You help with software engineering tasks: fixing bugs, adding features, refactoring, explaining code, and running commands.

# How to work
- Investigate with tools before answering questions about the code. Never guess at file contents.
- Read a file before editing it. Use Edit for changes to existing files; use Write only for new files or full rewrites.
- Keep changes minimal and focused on what was asked. Match the existing style, naming, and patterns.
- After making changes, verify them: run the build, tests, or linter if the project has them.
- For tasks with 3+ steps, track progress with TodoWrite.
- Don't commit, push, or run destructive commands (rm -rf, git reset --hard, force push) unless asked.
- If the user rejects a tool call, don't retry it. Stop and ask how to proceed.
- If you're stuck or the request is ambiguous in a way that matters, ask a short question.

# Communication
- Be concise and direct. Your output is shown in a terminal.
- Don't narrate every step. Say briefly what you'll do, do it, then summarize the result in a few lines.
- Reference code as path:line.
- When the task is done, stop. Don't start unrequested work.";

fn memory_files(cwd: &Path, cfg: &Config) -> Vec<PathBuf> {
    let mut files = vec![config_dir().join("KILN.md")];
    if cfg.load_claude_md {
        files.push(
            dirs::home_dir()
                .unwrap_or_default()
                .join(".claude/CLAUDE.md"),
        );
    }
    let mut dirs: Vec<&Path> = cwd.ancestors().collect();
    dirs.reverse();
    for d in dirs {
        for name in ["AGENTS.md", "KILN.md", "CLAUDE.md"] {
            if name == "CLAUDE.md" && !cfg.load_claude_md {
                continue;
            }
            files.push(d.join(name));
        }
    }
    let mut seen = std::collections::HashSet::new();
    files
        .into_iter()
        .filter(|f| f.is_file() && seen.insert(f.clone()))
        .collect()
}

pub fn system_prompt(cwd: &Path, cfg: &Config, model: &str) -> String {
    let git = cwd.ancestors().any(|d| d.join(".git").exists());
    let mut s = format!(
        "{BASE}\n\n# Environment\n- Working directory: {}\n- Git repository: {}\n- Platform: {} ({})\n- Date: {}\n- Model: {model}\n",
        cwd.display(),
        if git { "yes" } else { "no" },
        std::env::consts::OS,
        std::env::consts::ARCH,
        chrono::Local::now().format("%Y-%m-%d"),
    );
    for f in memory_files(cwd, cfg) {
        if let Ok(text) = std::fs::read_to_string(&f) {
            s.push_str(&format!(
                "\n# Instructions from {}\n{}\n",
                f.display(),
                text.trim()
            ));
        }
    }
    s
}

// ---- text-mode tool calling, for models/servers without working native tools ----

pub fn text_tools_prompt(tools: &[ToolSpec]) -> String {
    let mut s = String::from(
        "\n# Tools\nYou can call tools. To call one, output a block in exactly this format:\n\
<tool_call>\n{\"name\": \"ToolName\", \"arguments\": {\"param\": \"value\"}}\n</tool_call>\n\
You may make several calls in one response. After your tool calls, stop and wait: results arrive in \
<tool_result> blocks in the next message. Never write a <tool_result> yourself.\n\nAvailable tools:\n",
    );
    for t in tools {
        s.push_str(&format!(
            "\n## {}\n{}\nParameters (JSON schema): {}\n",
            t.name, t.description, t.schema
        ));
    }
    s
}

/// Render native tool blocks as text for text-mode models.
pub fn to_text_mode(messages: &[Message]) -> Vec<Message> {
    messages
        .iter()
        .map(|m| Message {
            role: m.role,
            content: m
                .content
                .iter()
                .map(|b| match b {
                    Block::ToolUse { name, input, .. } => Block::Text {
                        text: format!(
                            "<tool_call>\n{}\n</tool_call>",
                            json!({ "name": name, "arguments": input })
                        ),
                    },
                    Block::ToolResult {
                        name,
                        content,
                        is_error,
                        ..
                    } => Block::Text {
                        text: format!(
                            "<tool_result name=\"{name}\"{}>\n{content}\n</tool_result>",
                            if *is_error { " error=\"true\"" } else { "" }
                        ),
                    },
                    b => b.clone(),
                })
                .collect(),
        })
        .collect()
}

static TOOL_CALL: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?s)<tool_call>\s*(.*?)\s*(?:</tool_call>|$)").unwrap());

fn parse_call(raw: &str) -> Option<(String, Value)> {
    let raw = raw
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();
    let v: Value = serde_json::from_str(raw).ok()?;
    let name = v["name"].as_str()?.to_string();
    let args = match v.get("arguments").or_else(|| v.get("parameters")) {
        Some(Value::String(s)) => serde_json::from_str(s).unwrap_or(json!({})),
        Some(a) => a.clone(),
        None => json!({}),
    };
    Some((name, args))
}

/// Pull `<tool_call>` blocks out of text. Also catches models that emit them
/// as text even in native mode (common with Qwen/Hermes templates on some servers).
pub fn extract_tool_calls(text: &str) -> Option<(String, Vec<(String, Value)>)> {
    if !text.contains("<tool_call>") {
        return None;
    }
    let calls: Vec<_> = TOOL_CALL
        .captures_iter(text)
        .filter_map(|c| parse_call(&c[1]))
        .collect();
    if calls.is_empty() {
        return None;
    }
    let clean = TOOL_CALL.replace_all(text, "").trim().to_string();
    Some((clean, calls))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_calls() {
        let t = "Let me look.\n<tool_call>\n{\"name\": \"Read\", \"arguments\": {\"file_path\": \"a.rs\"}}\n</tool_call>\n\
<tool_call>{\"name\":\"Bash\",\"arguments\":\"{\\\"command\\\":\\\"ls\\\"}\"}";
        let (clean, calls) = extract_tool_calls(t).unwrap();
        assert_eq!(clean, "Let me look.");
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].0, "Read");
        assert_eq!(calls[1].1["command"], "ls");
    }
}
