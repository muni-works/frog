//! Headless agent engine. Clients talk to it only through [`protocol::Op`] and [`protocol::Event`].

pub mod approval;
pub mod ask;
pub mod auto;
pub mod background;
pub mod catalog;
pub mod chapter;
pub mod checkpoint;
pub mod codemap;
pub mod config;
pub mod context;
pub mod diagram;
pub mod early;
pub mod energy;
pub mod engine;
pub mod folder;
pub mod follow;
pub mod gist;
pub mod harness;
pub mod image_paths;
pub mod imports;
pub mod irc;
pub mod mcp;
pub mod mcp_oauth;
pub mod memory;
pub mod message;
pub mod models;
pub mod named_files;
pub mod panes;
pub mod policy;
pub mod pond;
pub mod present;
pub mod prompt;
pub mod protocol;
pub mod provider;
pub mod providers;
pub mod recall;
pub mod repomap;
pub mod rules;
pub mod schema;
pub mod session;
pub mod setup;
pub mod shell;
pub mod sidecar;
pub mod skills;
pub mod subagent;
pub mod summary;
mod text_filter;
pub mod thinking;
pub mod title;
pub mod tools;
pub mod worktree;

pub use engine::{Handle, Options, spawn};
pub use follow::follow;
pub use protocol::{
    Decision, Delta, EndReason, EngineError, Envelope, Event, Item, ItemKind, Level, Mode, Op,
    Status, ToolOutcome,
};
