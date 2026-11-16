# Frog Cloud

Frog Cloud runs models for you, so a session doesn't need a fast machine. You pay for what you use: each model has a price in dollars per million tokens, for the tokens it reads and the tokens it writes, and cached input (the part of the prompt the model has already seen, such as earlier turns) has its own lower price. [frog.toys/pricing](https://frog.toys/pricing) lists them all.

Models served through OpenRouter cost what each request cost there plus 10%. The menu shows where each model's price starts; a request OpenRouter routes to a dearer provider costs more. For GLM-5.3 Flash and DeepSeek V4.1 Flash, that is capped at the model maker's own price plus 10%.

Plans, Pro, Max and Ultra, include $5, $25 and $50 of usage a week. Past it, turns go on using credit at the same prices. Signing up and connecting GitHub gives $1 of credit, once per GitHub account.

<!-- only: web -->
On the web, every session runs in Frog Cloud: the model, and a sandbox with a copy of your repo where Frog runs commands and edits files.

Your credit is under your name at the bottom of the sidebar. Settings › Billing adds credit or picks a plan.
<!-- end -->

<!-- only: terminal -->
## Signing in

```sh
frog login            # signs in with GitHub in your browser; --google for Google
```

`frog login` saves this machine's key in the Keychain. On Linux, with no Keychain, it prints an `export FROG_API_KEY=…` line instead. `frog logout` deletes the saved key. Signing in needs a browser on the same machine.

Frog Cloud's models are `cloud/<model>`; `frog --models` lists them. `frog account` shows the default model you set (`FROG_MODEL`, then `default_model`) and whether it's billed, without using the network.
<!-- end -->

## When Frog Cloud is busy

A busy model is retried a few times, waiting longer each time, with one line saying so. If it's still busy, another Frog Cloud model answers that call, and the transcript says so. If Frog Cloud can't answer at all, the turn stops with the error and the thread stays as it was; send again once it's back. Frog never moves a thread to a model on your machine by itself.

<!-- only: mac, terminal -->
`cloud_fallback = false` in `config.toml` stops Frog from handing a call to another model: the turn ends instead.
<!-- end -->

## Out of credit

When your credit runs out, the turn stops and says so. Nothing is lost: add credit and send again.

<!-- only: web -->
The out-of-credits card in the thread has a Billing button, and "I added credit, keep going" picks up where it stopped.
<!-- end -->

## Other agents

Frog Cloud's models also work in other coding agents. It speaks the OpenAI API at `https://api.frog.toys/v1`, with your `frog_` key.
