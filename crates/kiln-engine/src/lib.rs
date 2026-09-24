//! Headless agent engine. Clients talk to it only through [`protocol::Op`] and [`protocol::Event`].

pub mod auto;
pub mod catalog;
pub mod checkpoint;
pub mod codemap;
pub mod config;
pub mod context;
pub mod diagram;
pub mod engine;
pub mod harness;
pub mod image_paths;
pub mod mcp;
pub mod memory;
pub mod message;
pub mod models;
pub mod prompt;
pub mod protocol;
pub mod provider;
pub mod providers;
pub mod session;
pub mod sidecar;
pub mod skills;
pub mod subagent;
mod text_filter;
pub mod thinking;
pub mod tools;

pub use engine::{Handle, Options, spawn};
pub use protocol::{
    Decision, Delta, EndReason, EngineError, Envelope, Event, Item, ItemKind, Level, Mode, Op,
    Status, ToolOutcome,
};
