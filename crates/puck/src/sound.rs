//! The cue sounds: 24 kHz mono 16-bit WAVs, synthesized by `assets/sfx/synth.py`.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cue {
    Boot,
    Wake,
    ListenStart,
    ListenEnd,
    Tick,
    Ask,
    Approve,
    Deny,
    Done,
    Error,
    /// A conversation other than the one in front needs you.
    OtherFrog,
}

impl Cue {
    pub fn wav(self) -> &'static [u8] {
        match self {
            Cue::Boot => include_bytes!("../assets/sfx/boot.wav"),
            Cue::Wake => include_bytes!("../assets/sfx/wake.wav"),
            Cue::ListenStart => include_bytes!("../assets/sfx/listen_start.wav"),
            Cue::ListenEnd => include_bytes!("../assets/sfx/listen_end.wav"),
            Cue::Tick => include_bytes!("../assets/sfx/tick.wav"),
            Cue::Ask => include_bytes!("../assets/sfx/ask.wav"),
            Cue::Approve => include_bytes!("../assets/sfx/approve.wav"),
            Cue::Deny => include_bytes!("../assets/sfx/deny.wav"),
            Cue::Done => include_bytes!("../assets/sfx/done.wav"),
            Cue::Error => include_bytes!("../assets/sfx/error.wav"),
            Cue::OtherFrog => include_bytes!("../assets/sfx/chime_other.wav"),
        }
    }
}
