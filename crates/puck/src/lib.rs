//! The frog puck: a round 466×466 AMOLED that fronts one or more frog sessions.
//!
//! Everything here is plain Rust over a pixel buffer, so the same code drives the desktop
//! simulator (`puck-sim`) and, later, the ESP32 firmware:
//! - [`eyes`]: the pupils, a pair of phyz pendulums hanging in the eye sockets.
//! - [`canvas`] and [`text`]: anti-aliased drawing into a framebuffer.
//! - [`ui`]: the screens from the mockup, drawn from a [`model::Puck`].
//! - [`model`]: frog's `--serve` event stream folded into what the screen shows.
//! - [`sound`]: the cue sounds, embedded as WAVs.

pub mod canvas;
pub mod eyes;
pub mod model;
pub mod sound;
pub mod text;
pub mod ui;

/// The panel is 466×466; the glass is the circle inscribed in it.
pub const SCREEN: f32 = 466.0;
/// Center of the glass in screen coordinates.
pub const C: f32 = 233.0;
