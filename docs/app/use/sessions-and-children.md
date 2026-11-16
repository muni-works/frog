# Sessions and children

A session is one conversation with Frog and the work it does. Sessions are listed in the sidebar by day.

<!-- only: web -->
Each session runs in its own Frog Cloud sandbox with its own copy of the repo, and has its own address. A session's menu, next to its title, renames, archives or deletes it. Archived sessions are under View options › Archived. Deleting a session removes its sandbox, changes and conversation for good.
<!-- end -->

<!-- only: terminal -->
A session is saved as a log under `~/.local/share/frog/sessions/` as it happens, so it survives a crash.

```sh
frog -c                    # continue the last session in this folder
frog -r <id>               # resume a session
frog --fork <id>@3         # a new session from turn 3 of another
frog --rewind <id>@3       # undo turn 3 and everything after it
frog --sessions            # list this folder's sessions
```
<!-- end -->

## Subagents

For a self-contained investigation, such as finding where something is used across many files, Frog can hand the work to a subagent: a helper with its own context that reads and reports back. Only its report joins the conversation, so a long search costs the session little. Its steps show live in its card, and stopping the turn stops it.

<!-- only: mac -->
## Sessions that start sessions

In the Mac app a session can start other sessions for parallel work, and message them. A session's row in the sidebar has the sessions it started nested under it.
<!-- end -->
