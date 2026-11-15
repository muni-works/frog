# frog on Linux

frog builds as one static binary (musl, rustls; no OpenSSL or glibc needed):

```
docker run --rm -v $PWD:/src -w /src rust:1-alpine \
  sh -c 'apk add musl-dev && cargo build --release -p frog'
install -m755 target/release/frog ~/.local/bin/frog
```

**Config.** `~/.config/frog/config.toml` wins; without one, frog reads the machine's `/etc/frog/config.toml` (`FROG_SYSTEM_CONFIG` overrides the path). That's how an OS image sets a default model. A tang server elsewhere on the network is an OpenAI-compatible profile; `api_key_file` reads its key from a file (first line, `~/` allowed) after `api_key` and `api_key_env`:

```toml
default_model = "tang"

[models.tang]
provider = "openai"
base_url = "http://mew:8420/v1"            # tang-llm serve --host 0.0.0.0 --port 8420
model = "mlx-community/Qwen3-8B-4bit"
api_key_file = "~/.config/frog/tang.key"   # the server's --api-key-file
context_window = 32768

[models.sonnet]                            # cloud: ANTHROPIC_API_KEY
provider = "anthropic"
model = "claude-sonnet-5"
```

`frog -m <profile>` picks another for one run; the `tang/` provider is the Mac-only Metal sidecar and isn't used here.

**The app** (`apps/linux`, `eco.frog.Frog`): a native GTK 4 + libadwaita client that runs `frog --serve`, like the Mac app, in frog's own look translated to GNOME's conventions (header bars, a sessions sidebar that folds away on narrow windows, the system accent colour and light/dark). It shows the conversation streaming, thinking folded to a line, tool calls that open to their output or diff (GtkSourceView), permission cards (Allow, the "always" option, Deny; ctrl+enter / ctrl+.), the model's questions, every folder's sessions to continue or fork (right click), and a model picker (ctrl+k).

```
cargo build --release -p frog -p frog-gtk   # needs gtk4, libadwaita, gtksourceview5 -devel
apps/linux/install.sh                        # -> /usr/local; PREFIX=~/.local for one user
frog-app [DIR]                               # open; new conversations work in DIR
frog-app --ask "why does the build fail?"    # open and send
frog-app --resume <id> | --new | --quit
```

One instance per user (GApplication): a second `frog-app` hands its arguments to the first. It finds frog through `FROG_BIN`, beside itself, then `PATH`. `FROG_APP_REPLAY=<session.jsonl>` plays a recorded session instead of a model, and `frog-app --shot PATH` saves the window as a PNG, for screenshots (`apps/linux/screenshots/`). The workspace's default members leave it out, so `cargo build` on a Mac doesn't need GTK.

**Flatpak:** `apps/linux/eco.frog.Frog.json` builds frog and the app on the GNOME 49 runtime (`flatpak-builder --user --install build apps/linux/eco.frog.Frog.json`). It fetches crates during the build, which is fine locally but not on Flathub (that needs `flatpak-cargo-generator` sources), and inside the sandbox frog's Bash tool runs in the Flatpak runtime rather than on the host.

On **muon** (the niri image) both ship in the image: `/usr/bin/frog`, `/usr/bin/frog-app`, the Frog dock pin and launcher entry, and an `/etc/frog/config.toml` pointing at the fleet's tang. There it's an ordinary GTK app that muon's GTK theme styles.

