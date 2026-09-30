# FrogKit

One copy of everything the Mac, iPhone, iPad, Watch and the extensions have in common. Each app
compiles these sources in directly (no module boundary), so a change here changes every app.

| folder | what | built into |
|---|---|---|
| `Core` | the engine protocol, the transcript model and how events fold into it, tool words, model naming, pairing | everything |
| `UI/Basics` | the frog's face, colors, motion | everything (the Watch too) |
| `UI/Transcript` | turns, activity, tool calls, diffs, questions, messages | the Mac and iOS apps, iOS extensions |

The rule: if two targets show or know the same thing, it lives here, once. Platform differences
stay inside the component (`#if os(...)`), never as a second copy.
