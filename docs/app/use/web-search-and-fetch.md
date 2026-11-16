# Web search and fetch

Frog can search the web and read pages. Each search and fetch shows on its card, with the query or the address.

## Search

<!-- only: web -->
In a Frog Cloud session, search is set up by Frog Cloud; there's nothing to choose on the web.
<!-- end -->

<!-- only: mac, terminal -->
Search uses your own SearXNG if you set one, and Frog Cloud search otherwise. To use your own, set it in `config.toml`:

```toml
web_search = "searxng"
searxng_url = "http://localhost:8080"
```

`web_search` can also be `brave`, `exa`, `tavily` or `frog` (Frog Cloud's search). A key for Brave, Exa or Tavily goes in with `echo $KEY | frog --set-key brave`, or in `BRAVE_SEARCH_API_KEY`, `EXA_API_KEY` or `TAVILY_API_KEY`. With no search set up at all, Frog has no search tool.

If your search can't be reached, Frog Cloud search answers instead when Frog Cloud is connected, and the result says so.
<!-- end -->

## Reading pages

A fetch keeps a page's main text and drops navigation, scripts and media. Pages are kept for 15 minutes in a session, so reading one again doesn't fetch it again.

A link you wrote, or one a search or an earlier fetch returned, is read without asking. A link Frog composed itself is checked first: in Auto by the small model that judges steps, otherwise on a card.

Fetches reach public addresses only. Your own machine and addresses on your local network are refused.

<!-- only: mac, terminal -->
`web_allow_private = true` in `config.toml` lets fetches reach your local network and this machine.
<!-- end -->

When a fetch is refused, paste the link into your message and Frog reads it.
