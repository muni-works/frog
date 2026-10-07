# reedline 0.51.0, patched for frog

Unmodified from crates.io except `Painter::print_external_message`
(`src/painting/painter.rs`, marked `frog:`). External messages print starting at the
input row, so a prompt with lines above its input (`render_prompt_left` containing
newlines) left those lines behind in the scrollback each time something printed. The
patch starts printing at the prompt's first row instead.

Dev-dependencies and examples are dropped from `Cargo.toml`. To update: copy the new
release's `src` and `LICENSE`, reapply the patch, and send it upstream.
