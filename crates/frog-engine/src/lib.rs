//! Headless agent engine. Clients talk to it only through [`protocol::Op`] and [`protocol::Event`].

pub mod ask;
pub mod auto;
pub mod catalog;
pub mod checkpoint;
pub mod codemap;
pub mod config;
pub mod context;
pub mod diagram;
pub mod early;
pub mod energy;
pub mod engine;
pub mod folder;
pub mod harness;
pub mod image_paths;
pub mod imports;
pub mod mcp;
pub mod memory;
pub mod message;
pub mod models;
pub mod named_files;
pub mod policy;
pub mod panes;
pub mod pond;
pub mod present;
pub mod prompt;
pub mod protocol;
pub mod provider;
pub mod providers;
pub mod recall;
pub mod repomap;
pub mod rules;
pub mod session;
pub mod setup;
pub mod sidecar;
pub mod skills;
pub mod subagent;
pub mod summary;
mod text_filter;
pub mod thinking;
pub mod tools;

pub use engine::{Handle, Options, spawn};
pub use protocol::{
    Decision, Delta, EndReason, EngineError, Envelope, Event, Item, ItemKind, Level, Mode, Op,
    Status, ToolOutcome,
};
