# Your first session

<!-- only: web -->
Type what you want done in the box on the new session page and send it. Pick a repo first with the repo menu, or send without one for a session with no repo. Frog starts a sandbox in Frog Cloud with a copy of the repo and works there; the first message waits while the sandbox starts.

Each session has its own address, so you can come back to it from the sidebar, a bookmark or another device.
<!-- end -->

<!-- only: mac -->
Pick a folder, type what you want done, and send it. The model menu in the composer says which model the session uses and where it runs.
<!-- end -->

<!-- only: terminal -->
```sh
cd your-repo
frog
```

The banner says which model is in use and whether it's billed.
<!-- end -->

Ask in plain words:

```
the login test is flaky. find out why and fix it.
```

## While it works

Frog reads files, runs commands and edits code, and each step shows in the transcript. When a step needs your say, a card asks you to allow or deny it.

<!-- only: web -->
Messages you send while Frog works wait in a queue and go as the next turn. The stop button ends the turn.
<!-- end -->

<!-- only: terminal -->
- `@path` attaches a file, `!cmd` runs a command and attaches its output.
- ctrl+c interrupts a turn, alt+enter inserts a newline.
<!-- end -->

## Coming back

<!-- only: web -->
A session's sandbox sleeps when it's idle. Opening the session wakes it, and the conversation and changes are where you left them.
<!-- end -->

<!-- only: terminal -->
```sh
frog -c                 # continue the last session here
frog --sessions         # list this folder's sessions
frog --fork <id>@3      # branch a session after turn 3
```
<!-- end -->
