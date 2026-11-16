# No web results

**The short answer:** the search backend couldn't be reached or found nothing. Try different words, or paste a link you already know.

## What you'll see

- `No results for "…"` on the search card: the backend answered with nothing.
- A line saying a search couldn't be reached and the results are from Frog Cloud search: your own search was down, and Frog Cloud search answered instead.
- A line saying your search couldn't be reached, naming `web_search` and `searxng_url` and suggesting you connect Frog Cloud: your own search was down and Frog Cloud isn't connected.
- `search failed` with an HTTP status: the backend refused the request, often a wrong or used-up key.
- No search card at all: no search is set up, so Frog has no search tool.

## What to do

Ask again with plainer or different words, or give Frog the page: a link in your message is read without asking.

<!-- only: mac, terminal -->
If your own search is down, start it again or check the address in `searxng_url`. A search that can't be connected to fails after 4 seconds; one that connects and then hangs fails after 20.
<!-- end -->

## The setting

<!-- only: web -->
In a Frog Cloud session, search is set up by Frog Cloud; there's no setting on the web.
<!-- end -->

<!-- only: mac, terminal -->
`web_search` and `searxng_url` in `config.toml`; see Web search and fetch.
<!-- end -->
