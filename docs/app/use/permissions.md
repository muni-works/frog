# Permissions and auto mode

Frog asks before steps that change things. How often it asks is the session's mode, shown in the composer and changed there.

| Mode | What it does |
| --- | --- |
| Auto | Runs what plainly serves your request and asks about the rest. New sessions start here. |
| Ask | Asks before edits and commands. |
| Accept edits | Edits run without asking; commands still ask. |
| Yolo | Never asks. |

Reading files and plain web reads never ask, in any mode.

## Auto

In Auto, a step that would ask goes to a small model first, which judges it against your recent messages and either lets it run or asks you. A step it lets run says why on its card; when it asks, the card says why.

Some steps always ask, whatever the small model says: `sudo`, `git push`, discarding changes or rewriting history (`reset --hard`, `rebase`), piping a download into a shell, `rm -rf` outside the project, publishing, changing system settings, stopping processes, and writes outside the project.

## Cards

A card shows the step and asks you to allow or deny it. Denying a step ends the turn; say how to go on, or send a new task.

<!-- only: web -->
⌘↩ allows and ⌘. denies the step on screen.
<!-- end -->

<!-- only: terminal -->
**shift+tab** cycles the mode. `--mode default|auto|accept-edits|yolo`, or `--auto`, `--accept-edits` and `--yolo`, picks one at start. A `--resume` with no mode flag keeps the mode the session saved.
<!-- end -->

<!-- only: mac, terminal -->
## The sandbox

Shell commands run in a sandbox: seatbelt on macOS, bubblewrap on Linux. A sandboxed command can write only inside the project, temp folders and toolchain caches, and can't read credentials such as `~/.ssh` or `~/.aws`. Because of that, sandboxed commands run without asking. A command that needs more asks first, and the card says why.

`sandbox_shell = false` in `config.toml`, or `--no-shell-sandbox`, turns the sandbox off; every command then asks.
<!-- end -->
