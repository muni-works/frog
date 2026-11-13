# What frog counts

Frog has no telemetry. The Mac app, the CLI and the node send nothing about you or your work
to us for counting. Everything we count is counted on our servers, from requests that already
reach them, and kept as anonymous totals. Some features do make network calls of their own;
[every one is listed below](#network-calls-frog-makes).

## Never collected

- prompts, model responses, or anything you type
- your code, file names, file paths, or file contents
- repository names, branch names, or git remotes
- IP addresses (not stored, not logged by us, not used for counting)
- device names, hardware ids, or any id that tells one install or Mac from another
- cookies or fingerprints on frog.toys

## Network calls frog makes

Besides the model provider you pick (your prompts and code go there, and nowhere else, to get
an answer), frog reaches these on its own:

| what | where | when | what's sent |
|---|---|---|---|
| iPhone push relay | `https://frog.toys/api/push` (override: `FROG_PUSH_RELAY`) | Mac app only, and only once a paired iPhone has registered and a push secret is set (Settings › General or `FROG_PUSH_SECRET`). Fires when a session asks permission, when frog's `Ask` tool asks you something, when the model calls `Notify`, and to update a Live Activity | the phone's APNs device token, the conversation title and project folder name, and the question: for a command, the command line (first 300 characters); for an edit, the file name and the reason; for `Ask`, the question text (first 300 characters); a short diff preview; for `Notify`, its message. The relay forwards it to Apple's push service and keeps nothing. No secret set: real-phone pushes never leave the Mac |
| model catalog | `https://models.dev/api.json` | when a model list is built (the picker, `--list-models`), at most every 6 hours; cached | nothing beyond an ordinary HTTPS request |
| provider model lists | each connected provider's own models endpoint (OpenRouter, Vercel, OpenAI, Frog Cloud, ollama, LM Studio, …) | same as above, per connected provider, cached | your key for that provider, to that provider only |
| model downloads | Hugging Face (`huggingface.co`) | when you download a local model (setup, the picker, `frog setup`) | the repo and file names being downloaded |
| local servers | `localhost:11434` (ollama), `localhost:1234` (LM Studio) | when picking a default model or listing models | nothing beyond a request on this machine |
| updates | `https://frog.toys/appcast.xml` | Mac app, about once a day (counted below) | the app version in the User-Agent |
| installer | `api.github.com/repos/muni-works/frog/releases/latest`, then `github.com` release assets | `install.sh` with no `FROG_VERSION`, and `/node` (tang from `github.com`) | an ordinary HTTPS request; GitHub's own logging applies |

## What's counted

### Installs (frog.toys)

One data point each time someone fetches `/install.sh` (the CLI), `/node` (the node
installer) or `/download` (the Mac app):

| field | example | where it comes from |
|---|---|---|
| path | `/download` | the URL |
| platform | `mac`, `linux`, `windows`, `unknown` | `?platform=` or the operating system named in the User-Agent; the User-Agent itself isn't kept |
| country | `DE` | Cloudflare's two-letter country for the request |
| time | | when it happened |

Lives in Cloudflare Workers Analytics Engine (dataset `frog_site`), which keeps data for three
months. Written by `site/worker.js`.

### Active Macs and versions (frog.toys)

The Mac app checks `https://frog.toys/appcast.xml` for updates about once a day (Sparkle).
Each check is one data point: the app version from the request's User-Agent (`Frog/0.2.0`),
the country, and the time. That's how we estimate how many Macs run frog and which version
they're on. It's a count of checks, not of people: there's no id to tell two Macs apart.
Same dataset as installs. Every released version since 0.1.1-rc3 checks this URL.

### Website visits (frog.toys)

Cloudflare Web Analytics, which is cookieless: page views, referrer, country, browser and
device type, and page load timing, as totals. No cookies, no local storage, no fingerprinting.

### Frog Cloud

If you sign up for Frog Cloud, your account (email, name, sign-in method), your purchases
(through Stripe) and per-request usage (model, token counts, cost, timing — never prompt or
response content) live in Frog Cloud's databases so we can bill you. See
[frog.toys's privacy policy](https://api.frog.toys/privacy) for the full account terms.

From those we post anonymous lines to our team's Discord channel:

- a new sign-up: its country only
- credit bought: the amount, and whether it's that account's first purchase
- a subscription started, cancelled or failed: the plan and price

No names, emails, device names or ids are posted. Sign-ins aren't posted at all.

### The daily digest

Once a day our team's Discord gets totals for the last 24 hours: installs by kind and
platform, estimated active Macs and their version split, sign-ups and total accounts, paying
accounts, revenue, and tokens by model. Plus milestones: the 100th and 1,000th install, and a
new release passing half of active Macs. All of it is sums; nothing in it can name a person.
