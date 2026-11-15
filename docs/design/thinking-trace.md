# Thinking trace design (phase 1: visual only)

Approved by Cam on 2026-10-22, from an interactive mockup. Dark theme values are shown; derive light-theme equivalents from existing tokens.

## States
1. **Live, collapsed (default while thinking).** One line: a frog avatar (mood, see below), a shimmering "Thinking · 1m 12s" (elapsed time, live), then an italic muted gist: the latest sentence or heading of the thought, truncated. Clicking expands.
2. **Live, expanded.**
   - A 2 pt left rule (muted green, #3a4a3c) like a margin note; content inset 22 pt.
   - **Timeline scrubber** above the trace: one dot per step (a step = a thinking block or tool-call group). Done steps are dark green, the current one is bright green and pulses, future ones (if a plan is known) are grey. Hovering shows the step summary.
   - **Done steps** collapse to one 12 pt line: "✓ **Title** · short result".
   - **Attention chips:** files or URLs the turn read, as small monospace chips (`TurnView.swift ▸ 40–90`). The one being read now is highlighted green with a thin progress bar.
   - **Current step text:** 12.5 pt, secondary colour, line-height about 1.75, proportional font. Self-talk sentences that start with "Hmm", "Wait", "Actually" or "Hold on" become their own paragraph, slightly dimmer (a "beat").
   - **Code in thinking:** compact rounded blocks, 11.5 pt mono, light syntax colours; inline code as small chips. No raw backticks.
   - **Options weighed** (display only in phase 1): when the thought lists alternatives and picks one, show pills. Rejected ones are struck through and dim; the chosen one is green with ✓. Use simple heuristics or a structured marker if the engine provides one; skip it if unsure.
   - **DECIDED callout:** a sentence where the model commits ("I'll define", "Decision:", "Going with") renders in a green-tinted box labelled DECIDED.
3. **Done.** One muted line, "✓ Thought for 2m 14s · <final gist>", collapsed, clickable to expand. Then the answer and the footer as usual.

## Frog mood avatar (about 22–26 pt)
- Thinking: slow blink.
- Decided: small smile and a brief bounce.
- Stuck or looping (loop guard fired, or no progress for 60 s): slight frown.
- Done: a small hop, then still.
All motion respects Reduce Motion.

## Out of scope (phase 2)
Nudge-mid-thought input and click-to-steer on options (they need engine support).
