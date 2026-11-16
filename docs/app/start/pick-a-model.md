# Pick a model

The model menu in the composer lists the models you can use and where each one runs.

<!-- only: web -->
On the web every session runs in Frog Cloud, so the menu's Frog Cloud models are the ones you can pick. Each shows its price in dollars per million tokens. Once your Mac is paired, its models are listed too, but they run from the Mac app.

A new session starts on the model you picked last, while Frog Cloud still lists it. The menu in an open session changes that session's model.
<!-- end -->

<!-- only: mac, terminal -->
Models run in three kinds of place:

- **On your Mac:** free, and your code stays on the Mac.
- **Your own servers and keys:** a machine you run, or an account you have with a model provider.
- **Frog Cloud:** hosted models, billed per token.
<!-- end -->

<!-- only: terminal -->
Which model a session starts on, first match wins:

1. `-m provider/model`
2. `FROG_MODEL`, then `default_model` in `~/.config/frog/config.toml`
3. the last model you used, in any session
4. with `FROG_API_KEY` set in the environment, Frog Cloud's default
5. the first that works here: `local/qwen3-4b` on frog's own engine, a model in ollama, LM Studio, Apple Intelligence (`apple/on-device`), Frog Cloud's default if you're signed in, a cloud model you turned on with `--enable-model`, or Anthropic when `ANTHROPIC_API_KEY` is set

Inside a session, `/model` switches. `frog --providers` lists providers and whether each is connected.
<!-- end -->
