"""frog-anim: the Frog mascot in motion, as a pure function of time.

    from frog_anim import ACTIONS, layout, render_frame, frames, write
    from frog_anim import sprite, place, rest, hop      # the building blocks, for compositors

See README.md."""
from .actions import ACTIONS, Action, Ctx, draw, hop, rest, seed_phase
from .mark import MARK, Palette, hex_rgb
from .motion import MOODS, REST, Move, ease, lerp, seg
from .render import Layout, frames, layout, render_frame, write
from .sprite import place, sprite

__all__ = ["ACTIONS", "Action", "Ctx", "draw", "hop", "rest", "seed_phase", "MARK", "Palette", "hex_rgb",
           "MOODS", "REST", "Move", "ease", "lerp", "seg", "Layout", "frames", "layout", "render_frame",
           "write", "place", "sprite"]
__version__ = "0.1.0"
