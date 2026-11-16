# Web search and fetch

Frog can search the web and read pages.

## Search

Search uses your own SearXNG if you set one, and Frog Cloud search otherwise. To use your own, set it in `config.toml`:

```toml
web_search = "searxng"
searxng_url = "http://localhost:8080"
```

If your search can't be reached, Frog Cloud search answers instead when Frog Cloud is connected, and the result says so.

## Reading pages

A link you wrote, or one a search or an earlier fetch returned, is read without asking. A link Frog composed itself is checked first.

When a fetch is refused, paste the link into your message and Frog reads it.
