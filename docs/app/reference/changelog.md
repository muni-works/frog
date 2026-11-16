# Changelog

## 0.6.0

### One right sidebar on the Mac and the web

- Changes, Terminal and Preview are always there as tabs with an icon and a label, in a panel you can drag wider or narrower, from 360 to 560. File rows are one line: name, folder, lines added and removed. Commit and Open PR sit at the bottom.
- Preview on the web, which shows a Frog Cloud session's dev server in the Preview tab, is built but not switched on yet.
- On the Mac, the preview's before-and-after view opens from the toolbar and from the timeline.
- When a command you ran in the Terminal tab fails, the model hears about it without being asked.

### The web, handled better

- A link you wrote, or one an earlier search or fetch returned, is read without a card. Only links Frog composes itself get the stricter check.
- When a fetch is denied, Frog is told the refusal is about the site, so it doesn't reach for `curl` instead.
- When your own SearXNG can't be reached, Frog Cloud search answers instead when Frog Cloud is connected, and the result says so. A search that can't be connected to fails in 4 seconds, not 20.

### Turns that just stopped

- A model that returns nothing at all is asked once more; a second empty reply ends the turn with a line saying so.
- A resumed session serves only from its own folder.

### Frog Cloud pricing

- Models served through OpenRouter cost what each request cost there plus 10%. The pricing page shows where each model's price starts; a request costs more when OpenRouter routes it to a dearer provider.
- The plans are Pro, Max and Ultra: $5, $25 and $50 of usage a week, for $20, $100 and $200 a month.
- Sign-up credit is $1.

### Smaller things

- On the Mac, typing after clicking a message in the transcript goes to the composer.
- `open_pr_when_done = "auto"` under `[git]` in `config.toml` opens a draft pull request when the work is done.
