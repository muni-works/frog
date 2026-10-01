# FrogKit

One copy of everything the Mac, iPhone, iPad, Watch and the extensions have in common. Each app
compiles these sources in directly (no module boundary, so nothing needs `public`), so a change
here changes every app that shows it.

| folder | what | built into |
|---|---|---|
| `Core` | the engine protocol, pairing, paths, tool names, model context, how frog phrases a question, session state | everything |
| `Model` | `Conversation` (the transcript and what you do to it), turns and items, `TurnFlow` and `ActivityWords` (how a turn reads), `ModelIdentity`, verbosity, stats, sounds | the Mac and iOS apps |
| `UI/Basics` | the frog's face, colors (the frog's green, place colors), motion and haptics, platform bridges | everything, the Watch too |
| `UI/Cards` | diffs with syntax colors, the body of frog's question | the apps and the iOS extensions |
| `UI/Transcript` | the transcript: turns, activity lines, tool calls, the permission card, messages (NSTextView ink on the Mac, SwiftUI ink on iOS), diagrams, MCP apps, the lightbox | the Mac and iOS apps |
| `UI/Sessions` | a conversation in a list: monogram, label, live glyph | the Mac and iOS apps |
| `UI/Composer` | send/queue/stop, queued messages, the mode picker, the context ring | the Mac and iOS apps |

The rules:

- If two targets show or know the same thing, it lives here, once.
- Platform differences stay inside the component (`#if os(...)`), never as a second copy: the
  permission card keeps the Mac's row of buttons and takes a thumb layout on a phone; a message
  renders in AppKit on the Mac and SwiftUI on iOS from the same Markdown blocks.
- What a platform does around a conversation goes through `ConversationEffects` (the Mac's
  sidebar and notifications, the phone's Live Activity); where its engine is goes through
  `ConversationLink` (an `EngineProcess` on the Mac, the bridge on a phone, a recording).
- The Mac decides; the phone asks. Model names and places come from the Mac's models and
  providers (`ModelContext`), sent over the bridge, so both say "Qwen3 4B · On this Mac".
