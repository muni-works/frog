//! Adapter for the official Codex CLI. It never reads Codex credentials or talks to the
//! ChatGPT service; authentication and requests stay inside the `codex` executable.

use super::{Request, Response, Stop, StreamEvent, assistant_message};
use crate::message::{Role, Usage};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;

pub struct Client {
    pub cwd: PathBuf,
    items: Arc<Mutex<Vec<(String, String, Value)>>>,
}

impl Client {
    pub fn new(cwd: PathBuf, _model: String) -> Self {
        Self {
            cwd,
            items: Arc::new(Mutex::new(Vec::new())),
        }
    }

    async fn exec_json(
        &self,
        req: &Request<'_>,
        on: &mut (dyn FnMut(StreamEvent) + Send),
    ) -> Result<Response> {
        let history = req
            .messages
            .iter()
            .map(|m| {
                format!(
                    "{}: {}",
                    if m.role == Role::User {
                        "user"
                    } else {
                        "assistant"
                    },
                    m.text()
                )
            })
            .collect::<Vec<_>>()
            .join("\n\n");
        let user = format!("{}\n\n--- Conversation so far ---\n{}", req.system, history);
        let mut child = Command::new("codex")
            .args(["exec", "--json", "--skip-git-repo-check", "--cd"])
            .arg(&self.cwd)
            .arg(user)
            .current_dir(&self.cwd)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .context("starting `codex exec --json`")?;
        let stdout = child.stdout.take().context("codex exec has no stdout")?;
        let mut lines = BufReader::new(stdout).lines();
        let mut text = String::new();
        let mut calls = Vec::new();
        let mut items = std::collections::HashMap::<String, usize>::new();
        let mut usage = Usage::default();
        let mut completed = false;
        let mut recorded = Vec::new();
        while let Some(line) = lines.next_line().await? {
            let Ok(v) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if let Some(item) = v.get("item") {
                let typ = item["type"].as_str().unwrap_or("");
                let id = item["id"].as_str().unwrap_or("").to_owned();
                if v["type"] == "item.started"
                    && (typ == "command_execution"
                        || typ == "file_change"
                        || typ == "mcp_tool_call")
                {
                    let name = match typ {
                        "command_execution" => "command",
                        "file_change" => "file change",
                        _ => item["tool"].as_str().unwrap_or("tool"),
                    };
                    let arg = item["command"]
                        .as_str()
                        .or(item["path"].as_str())
                        .unwrap_or("");
                    let index = calls.len();
                    calls.push((
                        format!("codex_{index}"),
                        name.to_owned(),
                        json!({"detail":arg,"output":""}),
                    ));
                    items.insert(id.clone(), index);
                    recorded.push((
                        format!("codex_{index}"),
                        name.to_owned(),
                        json!({"detail":arg,"output":""}),
                    ));
                    on(StreamEvent::ToolCall(name.into()));
                }
                if v["type"] == "item.completed" {
                    if typ == "agent_message" {
                        if let Some(s) = item["text"].as_str() {
                            text.push_str(s);
                            on(StreamEvent::Text(s.into()));
                        }
                    } else if typ == "command_execution" {
                        let idx = *items.entry(id).or_insert_with(|| {
                            let i = calls.len();
                            calls.push((format!("codex_{i}"), "command".into(), json!({})));
                            i
                        });
                        calls[idx].2 = json!({"command":item["command"],"output":item["aggregated_output"],"exit_code":item["exit_code"],"status":item["status"]});
                        recorded.push(calls[idx].clone());
                    } else if typ == "file_change" {
                        let idx = *items.entry(id).or_insert_with(|| {
                            let i = calls.len();
                            calls.push((format!("codex_{i}"), "file change".into(), json!({})));
                            i
                        });
                        calls[idx].2 = json!({"changes":item["changes"],"status":item["status"]});
                        recorded.push(calls[idx].clone());
                    } else if typ == "mcp_tool_call" {
                        let idx = *items.entry(id).or_insert_with(|| {
                            let i = calls.len();
                            calls.push((
                                format!("codex_{i}"),
                                item["tool"].as_str().unwrap_or("tool").to_owned(),
                                json!({}),
                            ));
                            i
                        });
                        calls[idx].2 = json!({"server":item["server"],"tool":item["tool"],"arguments":item["arguments"],"result":item["result"],"error":item["error"],"status":item["status"]});
                    }
                }
            }
            match v["type"].as_str().unwrap_or("") {
                "turn.completed" => {
                    usage.input = v["usage"]["input_tokens"].as_u64().unwrap_or(0);
                    usage.cache_read = v["usage"]["cached_input_tokens"].as_u64().unwrap_or(0);
                    usage.output = v["usage"]["output_tokens"].as_u64().unwrap_or(0);
                    completed = true;
                }
                "turn.failed" | "error" => bail!(
                    "codex exec: {}",
                    v["error"]["message"]
                        .as_str()
                        .or(v["message"].as_str())
                        .unwrap_or("turn failed")
                ),
                _ => {}
            }
        }
        let status = child.wait().await?;
        if !status.success() {
            bail!("codex exec failed with {status}");
        }
        if !completed {
            bail!("codex exec stream ended without turn.completed");
        }
        *self.items.lock().unwrap() = recorded;
        Ok(Response {
            message: assistant_message(String::new(), None, text, calls),
            usage,
            stop: Stop::End,
        })
    }

    pub fn take_items(&self) -> Vec<(String, String, Value)> {
        std::mem::take(&mut *self.items.lock().unwrap())
    }

    pub async fn complete(
        &self,
        req: &Request<'_>,
        on: &mut (dyn FnMut(StreamEvent) + Send),
    ) -> Result<Response> {
        // `exec --json` is the stable public streaming surface available to an installed user
        // CLI. Do not synthesize Codex auth or invoke its backend APIs from Frog.
        self.exec_json(req, on).await
    }
}

pub async fn check_available() -> Result<()> {
    let output = Command::new("codex")
        .args(["login", "status"])
        .output()
        .await
        .context("Codex CLI not found; install it and run `codex login`")?;
    if !output.status.success() {
        bail!("Codex is not logged in; run `codex login` to use codex/default");
    }
    Ok(())
}

/// Codex is listed only when the official CLI reports an active ChatGPT/Codex login.
pub async fn available() -> bool {
    Command::new("codex")
        .args(["login", "status"])
        .output()
        .await
        .is_ok_and(|o| o.status.success())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::Message;
    use std::os::unix::fs::PermissionsExt;

    #[tokio::test]
    async fn exec_fallback_streams_assistant_text_from_fake_codex() {
        let dir = std::env::temp_dir().join(format!("frog-codex-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let bin = dir.join("codex");
        std::fs::write(&bin,"#!/bin/sh\nif [ \"$1\" = \"login\" ]; then exit 0; fi\nif [ \"$1\" = \"app-server\" ]; then exit 2; fi\nprintf '%s\\n' '{\"type\":\"item.completed\",\"item\":{\"id\":\"a\",\"type\":\"agent_message\",\"text\":\"hello from codex\"}}' '{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}'\n").unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
        let old = std::env::var_os("PATH").unwrap_or_default();
        let path = format!("{}:{}", dir.display(), old.to_string_lossy());
        // PATH mutation is process-global; this unit test has no concurrent env access.
        unsafe {
            std::env::set_var("PATH", path);
        }
        let c = Client::new(dir.clone(), "default".into());
        assert!(available().await);
        let msgs = vec![Message {
            role: Role::User,
            content: vec![crate::message::Block::Text { text: "hi".into() }],
        }];
        let req = Request {
            system: "system",
            messages: &msgs,
            tools: &[],
            max_tokens: None,
            format: None,
            think: None,
            think_budget: None,
            cache_key: None,
        };
        let mut streamed = String::new();
        let resp = c
            .complete(&req, &mut |e| {
                if let StreamEvent::Text(s) = e {
                    streamed.push_str(&s)
                }
            })
            .await
            .unwrap();
        assert_eq!(resp.message.text(), "hello from codex");
        assert_eq!(streamed, "hello from codex");
        assert_eq!(resp.usage.input, 10);
        unsafe {
            std::env::set_var("PATH", old);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
}
