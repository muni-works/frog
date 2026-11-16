# A fetch was refused

**The short answer:** paste the link into your message. A link you wrote is read without asking.

## What you'll see

- A denied card for a `WebFetch`: the link was one Frog composed itself, and you or the small model that judges steps in Auto said no. Frog is told the refusal is about the site, so it doesn't try the same site another way.
- `frog only fetches public addresses`: the link points at this machine or your local network.
- An HTTP error from the site: the site itself refused, which a setting in Frog can't change.

## What to do

Paste the link into your message. A link you wrote, or one a search or an earlier fetch returned, is read without asking.

## The setting

There's no per-site allow list yet.

<!-- only: mac, terminal -->
`web_allow_private = true` in `config.toml` lets fetches reach this machine and your local network.
<!-- end -->
