//! Headless agent engine. Clients talk to it only through [`protocol::Op`] and [`protocol::Event`].

pub mod config;
pub mod context;
pub mod engine;
pub mod harness;
pub mod message;
pub mod models;
pub mod prompt;
pub mod protocol;
pub mod provider;
pub mod session;
mod text_filter;
pub mod tools;

pub use engine::{Handle, Options, spawn};
pub use protocol::{
    Decision, Delta, EndReason, EngineError, Envelope, Event, Item, ItemKind, Level, Mode, Op,
    Status, ToolOutcome,
};
