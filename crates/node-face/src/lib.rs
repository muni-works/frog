//! The frog node's face: Pip's Soft Blocks eyes, drawn at the head's panel resolution.
//!
//! - [`face`]: the character. An emotion (valence, arousal), a gaze, and listening / thinking / talking
//!   levels, all on springs, folded from what [`puck::model::Puck`] says frog is doing.
//! - [`draw`]: the eyes as 64-point outlines (so they morph into glyphs), pupils, the blink
//!   membrane, blush, thinking motes and the glow, into a [`puck::canvas::Canvas`].
//!
//! The look was settled in `cortex/face/soft-blocks-lab.html` (the rose repo); this is its port.

pub mod draw;
pub mod face;

/// The two heads' panels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Panel {
    /// The mini head: Waveshare 4" 720×720.
    Mini,
    /// The full-size head: 7" 1024×600 stood on end.
    Full,
}

impl Panel {
    pub fn size(self) -> (usize, usize) {
        match self {
            Panel::Mini => (720, 720),
            Panel::Full => (600, 1024),
        }
    }
}
