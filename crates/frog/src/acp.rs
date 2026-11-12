//! `frog --acp`: frog as an Agent Client Protocol (v1) agent, for editors like Zed, JetBrains
//! and Neovim. JSON-RPC over stdio, one frog engine per ACP session. Engine events become
//! `session/update` notifications (message and thought chunks, tool calls with locations and
//! diffs, the todo list as a plan), and permission prompts become `session/request_permission`.
//! Types come from the official schema crate, so the wire shapes match the spec.

use agent_client_protocol_schema::ProtocolVersion;
use agent_client_protocol_schema::v1::{
    AgentCapabilities, CancelNotification, Content, ContentBlock, ContentChunk, Diff,
    EmbeddedResourceResource, Implementation, InitializeResponse, McpCapabilities, McpServer,
    NewSessionRequest, NewSessionResponse, PermissionOption, PermissionOptionKind, Plan, PlanEntry,
    PlanEntryPriority, PlanEntryStatus, PromptCapabilities, PromptRequest, PromptResponse,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse, SessionMode,
    SessionModeState, SessionNotification, SessionUpdate, SetSessionModeRequest, StopReason,
    TextContent, ToolCall, ToolCallContent, ToolCallLocation, ToolCallStatus, ToolCallUpdate,
    ToolCallUpdateFields, ToolKind,
};
use anyhow::Result;
use frog_engine::config::{Config, Profile};
use frog_engine::protocol::{
    Decision, Delta, EndReason, Event, FileDiff, Item, ItemKind, LineKind,
};
use frog_engine::{Mode, Options};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{mpsc, oneshot};

/// Everything shared between the stdin loop and the per-session pumps.
struct Conn {
    out: mpsc::UnboundedSender<String>,
    next_id: AtomicI64,
    /// Our requests to the client (permission prompts), waiting for answers.
    waiting: Mutex<HashMap<i64, oneshot::Sender<Value>>>,
}

impl Conn {
    fn send(&self, msg: Value) {
        let _ = self.out.send(msg.to_string());
    }

    fn respond(&self, id: &Value, result: impl serde::Serialize) {
        self.send(json!({"jsonrpc": "2.0", "id": id, "result": result}));
    }

    fn fail(&self, id: &Value, code: i64, message: impl Into<String>) {
        self.send(
            json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message.into()}}),
        );
    }

    fn update(&self, session: &str, update: SessionUpdate) {
        let n = SessionNotification::new(session.to_string(), update);
        self.send(json!({"jsonrpc": "2.0", "method": "session/update", "params": n}));
    }

    /// A request to the client; resolves with its `result` (or `Null` on error).
    async fn request(&self, method: &str, params: impl serde::Serialize) -> Value {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.waiting.lock().unwrap().insert(id, tx);
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        rx.await.unwrap_or(Value::Null)
    }
}

struct Session {
    ops: mpsc::UnboundedSender<frog_engine::protocol::Op>,
    /// The running prompt, answered when its turn ends.
    turn: Arc<Mutex<Option<oneshot::Sender<StopReason>>>>,
    /// A memory command (`/remember` …), answered by the engine's notice instead of a turn.
    command: Arc<Mutex<Option<oneshot::Sender<StopReason>>>>,
}

pub async fn serve(
    cfg: Config,
    profile_name: String,
    profile: Profile,
    store: PathBuf,
    sandbox: bool,
) -> Result<()> {
    let (out_tx, mut out_rx) = mpsc::unbounded_channel::<String>();
    tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(line) = out_rx.recv().await {
            if stdout
                .write_all(format!("{line}\n").as_bytes())
                .await
                .is_err()
            {
                break;
            }
            let _ = stdout.flush().await;
        }
    });
    let conn = Arc::new(Conn {
        out: out_tx,
        next_id: AtomicI64::new(1),
        waiting: Mutex::new(HashMap::new()),
    });
    let mut sessions: HashMap<String, Session> = HashMap::new();
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        let Ok(msg) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        let id = msg.get("id").cloned();
        let method = msg["method"].as_str().unwrap_or("");
        let params = msg.get("params").cloned().unwrap_or(Value::Null);

        // A response to one of our requests.
        if method.is_empty() {
            if let Some(n) = id.as_ref().and_then(Value::as_i64)
                && let Some(tx) = conn.waiting.lock().unwrap().remove(&n)
            {
                let _ = tx.send(msg.get("result").cloned().unwrap_or(Value::Null));
            }
            continue;
        }
        let id = id.unwrap_or(Value::Null);
        match method {
            "initialize" => {
                let caps = AgentCapabilities::new()
                    .prompt_capabilities(
                        PromptCapabilities::new().embedded_context(true).image(true),
                    )
                    .mcp_capabilities(McpCapabilities::new().http(true));
                conn.respond(
                    &id,
                    InitializeResponse::new(ProtocolVersion::V1)
                        .agent_capabilities(caps)
                        .agent_info(Implementation::new("frog", env!("CARGO_PKG_VERSION"))),
                );
            }
            "authenticate" => conn.respond(&id, json!({})),
            "session/new" => match serde_json::from_value::<NewSessionRequest>(params) {
                Ok(req) => {
                    let mut cfg = cfg.clone();
                    add_mcp_servers(&mut cfg, &req.mcp_servers);
                    let opts = Options {
                        cfg,
                        profile_name: profile_name.clone(),
                        profile: profile.clone(),
                        cwd: req.cwd.clone(),
                        mode: Mode::Default,
                        can_ask: true,
                        resume: None,
                        store: Some(store.clone()),
                        sandbox,
                        rich: false,
                        subagent: false,
                        chat: false,
                    };
                    match frog_engine::spawn_checked(opts).await {
                        Ok(handle) => {
                            let session_id = frog_engine::session::new_id();
                            let turn = Arc::new(Mutex::new(None));
                            let command = Arc::new(Mutex::new(None));
                            let ops = handle.ops.clone();
                            tokio::spawn(pump(
                                handle,
                                session_id.clone(),
                                req.cwd.clone(),
                                conn.clone(),
                                turn.clone(),
                                command.clone(),
                            ));
                            sessions.insert(session_id.clone(), Session { ops, turn, command });
                            conn.respond(
                                &id,
                                NewSessionResponse::new(session_id).modes(modes(Mode::Default)),
                            );
                        }
                        Err(e) => conn.fail(&id, -32603, format!("{e:#}")),
                    }
                }
                Err(e) => conn.fail(&id, -32602, e.to_string()),
            },
            "session/prompt" => {
                let req = match serde_json::from_value::<PromptRequest>(params) {
                    Ok(r) => r,
                    Err(e) => {
                        conn.fail(&id, -32602, e.to_string());
                        continue;
                    }
                };
                let Some(s) = sessions.get(&*req.session_id.0) else {
                    conn.fail(&id, -32602, "unknown session");
                    continue;
                };
                let (tx, rx) = oneshot::channel();
                let text = prompt_text(&req.prompt);
                let slot = if frog_engine::memory::is_command(&text) {
                    &s.command
                } else {
                    &s.turn
                };
                *slot.lock().unwrap() = Some(tx);
                let _ = s.ops.send(frog_engine::protocol::Op::Submit {
                    text,
                    images: prompt_images(&req.prompt),
                    more: Vec::new(),
                });
                let conn = conn.clone();
                tokio::spawn(async move {
                    let reason = rx.await.unwrap_or(StopReason::Cancelled);
                    conn.respond(&id, PromptResponse::new(reason));
                });
            }
            "session/cancel" => {
                if let Ok(n) = serde_json::from_value::<CancelNotification>(params)
                    && let Some(s) = sessions.get(&*n.session_id.0)
                {
                    let _ = s.ops.send(frog_engine::protocol::Op::Interrupt);
                }
            }
            "session/set_mode" => match serde_json::from_value::<SetSessionModeRequest>(params) {
                Ok(req) => {
                    let mode = match &*req.mode_id.0 {
                        "accept_edits" => Mode::AcceptEdits,
                        "auto" => Mode::Auto,
                        "yolo" => Mode::Yolo,
                        _ => Mode::Default,
                    };
                    if let Some(s) = sessions.get(&*req.session_id.0) {
                        let _ = s.ops.send(frog_engine::protocol::Op::SetMode { mode });
                    }
                    conn.respond(&id, json!({}));
                }
                Err(e) => conn.fail(&id, -32602, e.to_string()),
            },
            _ if id.is_null() => {}
            other => conn.fail(&id, -32601, format!("{other} isn't supported")),
        }
    }
    for s in sessions.values() {
        let _ = s.ops.send(frog_engine::protocol::Op::Shutdown);
    }
    Ok(())
}

fn modes(current: Mode) -> SessionModeState {
    let id = match current {
        Mode::AcceptEdits => "accept_edits",
        Mode::Auto => "auto",
        Mode::Yolo => "yolo",
        _ => "default",
    };
    SessionModeState::new(
        id,
        vec![
            SessionMode::new("default", "Ask")
                .description("Every edit and command asks first".to_string()),
            SessionMode::new("accept_edits", "Accept Edits")
                .description("File edits are allowed; commands still ask".to_string()),
            SessionMode::new("auto", "Auto").description(
                "A local classifier approves steps that plainly serve your request".to_string(),
            ),
            SessionMode::new("yolo", "Yolo")
                .description("Everything runs without asking".to_string()),
        ],
    )
}

/// The editor's MCP servers join frog's own for this session.
fn add_mcp_servers(cfg: &mut Config, servers: &[McpServer]) {
    for s in servers {
        let (name, server) = match s {
            McpServer::Stdio(s) => (
                s.name.clone(),
                frog_engine::mcp::ServerConfig {
                    command: Some(s.command.display().to_string()),
                    args: s.args.clone(),
                    env: s
                        .env
                        .iter()
                        .map(|e| (e.name.clone(), e.value.clone()))
                        .collect(),
                    enabled: true,
                    ..Default::default()
                },
            ),
            McpServer::Http(s) => (
                s.name.clone(),
                frog_engine::mcp::ServerConfig {
                    url: Some(s.url.clone()),
                    headers: s
                        .headers
                        .iter()
                        .map(|h| (h.name.clone(), h.value.clone()))
                        .collect(),
                    enabled: true,
                    ..Default::default()
                },
            ),
            _ => continue,
        };
        cfg.mcp_servers.insert(name, server);
    }
}

/// Images in the prompt (pasted into the editor's chat).
fn prompt_images(blocks: &[ContentBlock]) -> Vec<frog_engine::protocol::Image> {
    blocks
        .iter()
        .filter_map(|b| match b {
            ContentBlock::Image(i) => Some(frog_engine::protocol::Image {
                mime: i.mime_type.clone(),
                data: i.data.clone(),
            }),
            _ => None,
        })
        .collect()
}

/// The prompt as frog text: text as is, linked files as `@path` mentions, embedded files inline.
fn prompt_text(blocks: &[ContentBlock]) -> String {
    let mut parts = Vec::new();
    for b in blocks {
        match b {
            ContentBlock::Text(t) => parts.push(t.text.clone()),
            ContentBlock::ResourceLink(l) => match l.uri.strip_prefix("file://") {
                Some(path) => parts.push(format!("@{path}")),
                None => parts.push(l.uri.clone()),
            },
            ContentBlock::Resource(r) => {
                if let EmbeddedResourceResource::TextResourceContents(t) = &r.resource {
                    let path = t.uri.strip_prefix("file://").unwrap_or(&t.uri);
                    parts.push(format!("<file path=\"{path}\">\n{}\n</file>", t.text));
                }
            }
            _ => {}
        }
    }
    parts.join("\n")
}

/// Turn one session's engine events into ACP updates, and its permission prompts into requests.
async fn pump(
    mut handle: frog_engine::Handle,
    session: String,
    cwd: PathBuf,
    conn: Arc<Conn>,
    turn: Arc<Mutex<Option<oneshot::Sender<StopReason>>>>,
    command: Arc<Mutex<Option<oneshot::Sender<StopReason>>>>,
) {
    let finish = |reason: StopReason| {
        if let Some(tx) = turn.lock().unwrap().take() {
            let _ = tx.send(reason);
        }
    };
    // The session's `provider/model`, so an error can name the service to fix.
    let mut model: Option<String> = None;
    while let Some(env) = handle.events.recv().await {
        match &env.event {
            Event::Status(s) => model = Some(s.model.clone()),
            Event::ModelChanged { model: m } => model = Some(m.clone()),
            _ => {}
        }
        match env.event {
            // A memory command's whole answer is one notice.
            Event::Notice { message, .. } if command.lock().unwrap().is_some() => {
                conn.update(
                    &session,
                    SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                        TextContent::new(message),
                    ))),
                );
                if let Some(tx) = command.lock().unwrap().take() {
                    let _ = tx.send(StopReason::EndTurn);
                }
            }
            Event::ItemDelta { delta, .. } => match delta {
                Delta::Text { text } => conn.update(
                    &session,
                    SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                        TextContent::new(text),
                    ))),
                ),
                Delta::Reasoning { text } => conn.update(
                    &session,
                    SessionUpdate::AgentThoughtChunk(ContentChunk::new(ContentBlock::Text(
                        TextContent::new(text),
                    ))),
                ),
                Delta::Output { .. } | Delta::ImagePreview { .. } => {}
            },
            Event::ItemStarted {
                id,
                kind: ItemKind::ToolCall { name, arg },
            } => {
                let mut call = ToolCall::new(id, title(&name, &arg))
                    .kind(kind(&name))
                    .status(ToolCallStatus::InProgress);
                if let Some(path) = file_arg(&name, &arg, &cwd) {
                    call = call.locations(vec![ToolCallLocation::new(path)]);
                }
                conn.update(&session, SessionUpdate::ToolCall(call));
            }
            Event::ItemCompleted {
                id,
                item:
                    Item::ToolCall {
                        name,
                        input,
                        outcome,
                        output,
                        display,
                        diff,
                        ..
                    },
            } => {
                let ok = outcome == frog_engine::protocol::ToolOutcome::Ok;
                let content = match &diff {
                    Some(d) => ToolCallContent::Diff(acp_diff(d, &cwd)),
                    None => {
                        let text = display.unwrap_or(output);
                        let text: String = text.chars().take(8_000).collect();
                        ToolCallContent::Content(Content::new(ContentBlock::Text(
                            TextContent::new(text),
                        )))
                    }
                };
                let fields = ToolCallUpdateFields::new()
                    .status(if ok {
                        ToolCallStatus::Completed
                    } else {
                        ToolCallStatus::Failed
                    })
                    .content(vec![content])
                    .raw_input(input.clone());
                conn.update(
                    &session,
                    SessionUpdate::ToolCallUpdate(ToolCallUpdate::new(id, fields)),
                );
                if name == "TodoWrite" && ok {
                    conn.update(&session, SessionUpdate::Plan(plan(&input)));
                }
            }
            Event::PermissionRequest {
                id,
                item,
                name,
                arg,
                always,
                ..
            } => {
                let conn = conn.clone();
                let session = session.clone();
                let ops = handle.ops.clone();
                tokio::spawn(async move {
                    let call = ToolCallUpdate::new(
                        item,
                        ToolCallUpdateFields::new()
                            .title(title(&name, &arg))
                            .kind(kind(&name)),
                    );
                    let options = vec![
                        PermissionOption::new("allow", "Allow", PermissionOptionKind::AllowOnce),
                        PermissionOption::new(
                            "always",
                            capitalize(&always),
                            PermissionOptionKind::AllowAlways,
                        ),
                        PermissionOption::new("deny", "Deny", PermissionOptionKind::RejectOnce),
                    ];
                    let answer = conn
                        .request(
                            "session/request_permission",
                            RequestPermissionRequest::new(session, call, options),
                        )
                        .await;
                    let decision = match serde_json::from_value::<RequestPermissionResponse>(answer)
                    {
                        Ok(RequestPermissionResponse {
                            outcome: RequestPermissionOutcome::Selected(s),
                            ..
                        }) => match &*s.option_id.0 {
                            "allow" => Decision::Allow,
                            "always" => Decision::AllowAlways,
                            _ => Decision::Deny,
                        },
                        _ => Decision::Deny,
                    };
                    let _ = ops.send(frog_engine::protocol::Op::Permission {
                        id,
                        decision,
                        note: None,
                    });
                });
            }
            Event::TurnEnded { reason, .. } => finish(match reason {
                EndReason::Complete | EndReason::Denied | EndReason::BlockedOnApproval { .. } => {
                    StopReason::EndTurn
                }
                // Out of credit: the turn stopped for the user (money), like a denial.
                EndReason::BillingLimit { window, .. } => {
                    conn.update(
                        &session,
                        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                            TextContent::new(format!(
                                "\n\nfrog stopped: out of credit ({window}); add credit to keep going"
                            )),
                        ))),
                    );
                    StopReason::EndTurn
                }
                // An app update suspended the turn; it carries on when the host resumes
                // this session, so from the outside it looks like it just stopped.
                EndReason::Suspended => StopReason::Cancelled,
                EndReason::Cancelled => StopReason::Cancelled,
                EndReason::MaxTokens { .. } => StopReason::MaxTokens,
                EndReason::Looping | EndReason::StepLimit => StopReason::MaxTurnRequests,
                EndReason::Error { error } => {
                    conn.update(
                        &session,
                        SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                            TextContent::new(format!(
                                "\n\nfrog stopped: {}",
                                crate::render::describe_error(&error, model.as_deref())
                            )),
                        ))),
                    );
                    StopReason::EndTurn
                }
            }),
            Event::Error { error } => {
                conn.update(
                    &session,
                    SessionUpdate::AgentMessageChunk(ContentChunk::new(ContentBlock::Text(
                        TextContent::new(format!(
                            "frog error: {}",
                            crate::render::describe_error(&error, model.as_deref())
                        )),
                    ))),
                );
                finish(StopReason::EndTurn);
            }
            _ => {}
        }
    }
    finish(StopReason::Cancelled);
    if let Some(tx) = command.lock().unwrap().take() {
        let _ = tx.send(StopReason::Cancelled);
    }
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    c.next()
        .map(|f| f.to_uppercase().chain(c).collect())
        .unwrap_or_default()
}

fn kind(name: &str) -> ToolKind {
    match name {
        "Read" => ToolKind::Read,
        "Edit" | "Write" => ToolKind::Edit,
        "Grep" | "Glob" | "CodeMap" | "McpTools" | "WebSearch" | "Docs" => ToolKind::Search,
        "WebFetch" => ToolKind::Fetch,
        "Bash" => ToolKind::Execute,
        "Task" | "TodoWrite" | "Skill" => ToolKind::Think,
        _ => ToolKind::Other,
    }
}

fn title(name: &str, arg: &str) -> String {
    let name = match name.strip_prefix("mcp__") {
        Some(rest) => rest.replacen("__", " › ", 1),
        None => name.to_string(),
    };
    if arg.is_empty() {
        name
    } else {
        format!("{name} {arg}")
    }
}

/// The file a Read/Edit/Write is about, for the editor to follow along.
fn file_arg(name: &str, arg: &str, cwd: &Path) -> Option<PathBuf> {
    matches!(name, "Read" | "Edit" | "Write")
        .then(|| cwd.join(arg))
        .filter(|_| !arg.is_empty())
}

/// frog's hunks as the before and after text ACP diffs carry.
fn acp_diff(d: &FileDiff, cwd: &Path) -> Diff {
    let (mut old, mut new) = (Vec::new(), Vec::new());
    for (i, h) in d.hunks.iter().enumerate() {
        if i > 0 {
            old.push("…".to_string());
            new.push("…".to_string());
        }
        for l in &h.lines {
            match l.kind {
                LineKind::Context => {
                    old.push(l.text.clone());
                    new.push(l.text.clone());
                }
                LineKind::Remove => old.push(l.text.clone()),
                LineKind::Add => new.push(l.text.clone()),
            }
        }
    }
    let diff = Diff::new(cwd.join(&d.path), new.join("\n"));
    if d.created {
        diff
    } else {
        diff.old_text(old.join("\n"))
    }
}

fn plan(input: &Value) -> Plan {
    let todos = match &input["todos"] {
        Value::String(s) => serde_json::from_str(s).unwrap_or(Value::Null),
        v => v.clone(),
    };
    let entries = todos
        .as_array()
        .into_iter()
        .flatten()
        .map(|t| {
            let status = match t["status"].as_str() {
                Some("completed") => PlanEntryStatus::Completed,
                Some("in_progress") => PlanEntryStatus::InProgress,
                _ => PlanEntryStatus::Pending,
            };
            PlanEntry::new(
                t["content"].as_str().unwrap_or(""),
                PlanEntryPriority::Medium,
                status,
            )
        })
        .collect();
    Plan::new(entries)
}
