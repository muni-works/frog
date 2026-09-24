# Hosted search for frog Pro: APIs, costs, and a docs index

Research date: 2026-09-23. Prices come from vendor pricing pages fetched that day unless noted. Anything I couldn't confirm on a primary page is marked **[unverified]**. Anything that is only the vendor's own claim is marked **[vendor claim]**. Numbers I derived are marked **[calc]**.

Usage assumption from the brief: a heavy user runs **50–200 searches/day**, so **1,500–6,000/month** (30 days), and fetches **2–5 pages per search**, so **3,000–30,000 pages/month**.

---

## TL;DR

- **Primary: Brave Search API** at $5/1k. It has its own index, handles 50 QPS, came top of the one independent agent-search benchmark I found, and its **LLM Context** endpoint returns token-budgeted page extracts for the same $5. That lets many queries skip the fetch entirely. The terms are the main constraint: no storage beyond "transient", no resale, flow-down terms for end users, and no using results to train or benchmark models.
- **Fallback and cheap tier: Parallel Search (Fast/Turbo)** at $1/1k with excerpts. It is 5x cheaper, runs on a different index (so outages don't overlap) and allows 600 req/min. Its terms explicitly ban sharing one user's results with another.
- **Don't build on SERP scrapers** (Serper, SerpApi and similar). They are cheap ($0.30–1/1k), but Google v. SerpApi is still being litigated, and a paid product built on scraped Google is the thing we already ruled out for SearXNG.
- **Keep page fetches local.** WebFetch already runs on the user's machine, which costs frog nothing, puts no provider terms on frog, and keeps browsing private. Only the search call needs to be hosted. That cuts the heavy-user bill to **$7.50–30/month on Brave, or $1.50–6 on Parallel** [calc].
- **$15–20/month doesn't cover unlimited heavy search on Brave.** The 200/day user costs $30. Include about **1,000 searches/month (~$5 COGS)**, send overflow to Parallel or metered credits, and keep BYOK. A user's own Brave key gets its own $5/month credit.
- **Docs index: don't build the full thing yet.** The infra is cheap: roughly **$50–100/month for 2k packages, $100–250 for 10k, $200–500 for 50k**, plus a one-time embedding bill of **$5–300**. The real cost is engineering: parsers for each doc system, keeping versions fresh, and license hygiene. Frog's local `Docs` tool already covers the most valuable case, the API of an *installed* dependency at its exact version. Run a zero-infra MVP first (llms.txt awareness plus logging), then a small hosted pilot with kill criteria (§3.2).
- **No cross-user caching of search results.** Brave's and Parallel's terms forbid it, and agent queries leak code identifiers and error text. The docs index is the right place for cross-user sharing, because its content is public.

---

## 1. Licensed search APIs

### 1.1 Comparison table

Columns:
- **$/1k** is list price per 1,000 searches of 10 results at the cheapest sensible setting.
- **Heavy user/mo** is search calls only, at 1,500 and 6,000 searches/month [calc]. Fetches are local (§3.3), so they add $0.
- **Content?** says whether a search returns enough page text to skip a fetch.

| Provider | $/1k searches | Heavy user/mo (1.5k / 6k) | Content? | Own index? | Rate limit | Terms that matter | Notes |
|---|---|---|---|---|---|---|---|
| **Brave Search** (web or LLM Context) | **$5** ($5/mo free credit, with attribution) | **$7.50 / $30** | LLM Context: extracted chunks, 1k–32k tokens per call | Yes | 50 QPS | Transient storage only. No resale or sublicensing. End users bound by similar terms. No training or benchmarking of AI on results. "Powered by Brave" if results are displayed. | Free tier removed Feb 2026. AI-inference rights are now in the standard plan. |
| Brave Answers | $4 + $5/M tokens | n/a | Answer text | Yes | 2 QPS | Same | Not useful: frog brings its own model. |
| **Exa** | $7 (search) + $1/1k pages per content type | $10.50 / $42 search only. **$18 / $72** with text for 5 results | Yes (text, highlights, summary) | Yes (neural) | 10 QPS search, 100 QPS contents | Standard ToS bans copying or caching except browser cache, and resale without consent. **Needs an MSA** for a paid product. | $10/mo free credit. Deep search $12–15/1k. |
| **Tavily** | $8 PAYG, $5–7.50 on plans (basic = 1 credit, advanced = 2) | $7.50–12 / $30–48 (basic) | Snippets, optional raw content | Mixed **[unverified]** | Not published | No sublicensing. **Tavily may train on your inputs.** | Acquired by Nebius, Feb 2026 ($275M). 1k free credits/mo. |
| **Perplexity Search API** | $5 | $7.50 / $30 | Extracted snippets, `max_tokens_per_page` | Yes **[vendor claim]** | Not captured | API ToS returned 403 **[unverified]** | Top quality score (80) in the Artificial Analysis agent benchmark, Sept 2026. |
| **Linkup** | $5–6 (fast/standard/deep) | $7.50–9 / $30–36 | Yes, plus a fetch endpoint at $1–6/1k | Partly **[unverified]** | Not captured | Not reviewed **[unverified]** | 4k free queries. ZDR on enterprise. |
| **Parallel Search** | **$1** Turbo/Fast. $5 Basic/Advanced | **$1.50 / $6** | Yes (excerpts; Basic has longer ones) | Yes **[vendor claim]** | 600 req/min | Output "primarily for the use of one End Customer only… shall not be copied, cached, stored, or made available to other End Customers". No resale. | Up to $80 free at signup plus $5/mo. Extract $1/1k. |
| **You.com** | $5 | $7.50 / $30 | LLM-ready snippets. Contents $1/1k pages | Yes **[vendor claim]** | Not captured | Not reviewed **[unverified]** | $100 free credit. ZDR available. |
| **Kagi** | $12 | $18 / $72 | No. Extract API $4/1k pages | Mixed (own index plus third parties) | Not published | Not reviewed | Invoiced every 30 days or at $100. |
| **Mojeek** | £2 (Startup) / £3 (Business), ≈ $2.70–4 | ≈ $4–6 / $16–24 | Snippets only | **Yes, fully independent** | 100k–400k/day | AI/ML use allowed on all plans. **1-hour caching**; storage on Business/Enterprise. | Smaller index. Weaker on long-tail developer queries **[unverified]**. |
| **Jina** `s.jina.ai` | ~$0.20–0.50 **[unverified]** (≥10k tokens per search × ~$0.02–0.05/M tokens) | < $3 | Yes (Reader-formatted) | **No** (backend undisclosed) | 100 RPM (1,000 premium) | Not reviewed | Now part of Elastic. Treat as a fetch/reader tool, not an index. |
| **Firecrawl** search | ≈ $1.66 on Standard (2 credits per 10 results; 100k credits for $83/mo billed annually **[verify]**). $6.40 on Hobby | ≈ $2.50 / $10 | Optional scrape, 1 credit per page | Partly. Its own docs say Map uses Google `site:` queries | 10–10,000/min by plan | Google-derived results carry the SERP risk below | Also sells a **Developer Index** (§2.4). |
| Serper | $0.30–1.00 (prepaid packs, valid 6 months) | $0.45–1.50 / $1.80–6 | No | **No (scraped Google)** | By pack | Resells Google results | Legal risk below. |
| SerpApi | $25 → ~$5.50 as tiers grow | $8–37 / $33–150 | No | **No (scraped Google)** | By plan | Offers a "U.S. Legal Shield" (up to $2M) on Production+ plans | Being sued by Google (below). |
| Google Custom Search JSON | $5 (100/day free, 10k/day cap) | n/a | No | Google | 10k/day | **Closed to new customers. Shuts down 2027-01-01.** | Not an option. |
| Gemini / Vertex grounding | $14/1k grounded prompts (Gemini 3.x; 5k/mo free) + model tokens | $21 / $84 + tokens | No: it grounds Gemini's *answer* | Google | n/a | Tied to Gemini output. Display requirements. | Doesn't fit a local-model agent. |
| Bing (Grounding with Bing) | $14/1k | n/a | No | Bing | 150 TPS | **Only inside Azure AI Foundry agents.** Must show citations and a Bing query link. | Bing Search APIs were retired 2025-08-11. |

### 1.2 Notes per provider

**Brave.** The pricing restructure of **2026-02-13** dropped the free tier and the separate "Data for Search / Data for AI / Data with storage rights" plans. They were replaced by Search at $5/1k with $5/month credit "when attribution is provided", 50 QPS, and AI inference rights folded in ([Brave API page](https://brave.com/search/api/), [pricing docs](https://api-dashboard.search.brave.com/documentation/pricing), [AlternativeTo, 2026-02-13](https://alternativeto.net/news/2026/2/brave-updates-its-search-api-with-a-new-llm-context-endpoint-for-ai-and-new-pricing), [Implicator, Feb 2026](https://www.implicator.ai/brave-drops-free-search-api-tier-puts-all-developers-on-metered-billing/)).

The **LLM Context** endpoint (`/res/v1/llm/context`) is priced like web search. It returns ranked extracted chunks (text, tables, code, forum posts) with `maximum_number_of_tokens` from 1,024 to 32,768, default 8,192 ([Brave blog](https://brave.com/blog/most-powerful-search-api-for-ai/), [docs](https://api-dashboard.search.brave.com/documentation/services/llm-context)). For frog's small local models, a budgeted 2–4k-token extract is often better than a full page.

Terms, effective **2026-09-01** ([ToS](https://api-dashboard.search.brave.com/terms-of-service)):
- §3.2: no storing, caching or building a database of results "other than transient storage required for operation of Customer Applications".
- No redistributing, reselling or sublicensing.
- No using results to "create, evaluate, train, re-train, fine-tune, benchmark or otherwise improve artificial intelligence models".
- §4.3: each end user must be bound by a written agreement with substantially similar restrictions.

Using results inside frog Pro, with frog as the Customer Application, is the intended use. Frog Pro's own ToS needs the flow-down clause.

**The training/benchmark ban matters for frog.** Session logs that contain Brave results must be kept out of any fine-tuning or eval corpus. That includes `frog bench` fixtures and any replay work like draft-replay. The alternative is to negotiate enterprise terms.

**Exa.** $7/1k search, $1/1k pages per content type, answer $5/1k, 10 QPS, and more than 25 QPS by contract ([pricing](https://exa.ai/pricing), [rate limits](https://exa.ai/docs/reference/rate-limits)). The public ToS is written for a website user. It bans copying "except for temporary files that are automatically cached by your web browser" and resale "without our prior consent" ([ToS PDF](https://exa.ai/assets/Exa_Labs_Terms_of_Service.pdf)). Embedding it in a paid product needs its MSA. It is good for semantic "find pages like this" queries, and costs the most once contents are included.

**Tavily.** Credits: basic search is 1, advanced 2, and extract is 1 credit per 5 URLs. Plans run from $30/4k to $500/100k credits, or $0.008 PAYG ([credits doc](https://docs.tavily.com/documentation/api-credits)). The terms, updated **2026-05-04**, let Tavily and its AI providers retain customer input and use it for training ([terms](https://www.tavily.com/terms)). That is a privacy problem for code-bearing queries. Nebius bought it in Feb 2026 ([Nebius](https://nebius.com/newsroom/nebius-announces-agreement-to-acquire-tavily-to-add-agentic-search-to-its-ai-cloud-platform), [Bloomberg, 2026-02-10](https://www.bloomberg.com/news/articles/2026-02-10/nebius-agrees-to-buy-ai-agent-search-company-tavily-for-275-million)).

**Perplexity.** The Search API is $5/1k. It returns title, URL, snippet and dates, with extraction controlled by `max_tokens`/`max_tokens_per_page`, and never full pages ([pricing](https://docs.perplexity.ai/getting-started/pricing), [search quickstart](https://docs.perplexity.ai/guides/search-quickstart)). Sonar models add $5–14/1k request fees plus tokens. **I couldn't read the API terms (403) [unverified].**

**Parallel.** Turbo/Fast cost $1/1k (~200 ms / ~700 ms) and Basic/Advanced $5/1k. Each extra 10 results costs $1/1k, and the limit is 600 req/min ([pricing](https://parallel.ai/pricing)). Its terms explicitly forbid caching one end customer's output for another, and forbid resale ([customer terms](https://parallel.ai/customer-terms)).

**Kagi.** Search API $12/1k, Extract $4/1k ([pricing](https://kagi.com/api/pricing)). It has no pricing advantage and I found no agent benchmark showing a quality edge.

**Mojeek.** £2–3 CPM, AI use allowed, 1-hour cache, storage on higher plans ([API page](https://www.mojeek.com/services/search/web-search-api/)). It has the friendliest terms of any independent index. I'd want a dev-query eval before relying on it.

**Jina.** Search requests cost "starting from 10,000 tokens" each. Keys get 10M free tokens, with a limit of 100 RPM for search ([Reader page](https://jina.ai/reader/)). I couldn't load the top-up price page (404) [unverified]. Elastic now owns Jina ([Elastic/Jina](https://www.elastic.co/search-labs/integrations/jina)).

**SERP scrapers.** Google sued SerpApi on 2025-12-19. The DMCA claims were dismissed on **2026-07-20** ([Search Engine Land](https://searchengineland.com/google-loses-key-dmca-claims-against-serpapi-in-scraping-lawsuit-483185)). Google refiled on **2026-08-10** on the basis of its content licensing deals, Reddit's among them, and SerpApi has moved to dismiss again ([MediaPost, 2026-08-12](https://www.mediapost.com/publications/article/417185/google-renews-battle-with-serpapi-over-scraping.html), [SerpApi blog](https://serpapi.com/blog/google-tried-again-were-moving-to-dismiss-their-claims-a-second-time/), [docket](https://www.courtlistener.com/docket/72059948/google-llc-v-serpapi-llc/)). Even if SerpApi wins, frog would be building a paid feature on results that Google's terms prohibit. The legal-shield product exists because the risk is real. Serper pricing is from third-party write-ups ([coldiq](https://coldiq.com/blog/serper-pricing)) and SerpApi's is from its [pricing page](https://serpapi.com/pricing).

**Google and Bing.** Custom Search JSON is closed to new customers and ends on 2027-01-01 ([dev.to summary](https://dev.to/nexgendata/google-kills-custom-search-api-on-jan-1-2027-you-have-9-months-1jg1)) [unverified against a Google page]. Gemini grounding is $14/1k on 3.x ([Gemini pricing](https://ai.google.dev/gemini-api/docs/pricing)). Bing Search APIs were retired on 2025-08-11 ([Microsoft Learn](https://learn.microsoft.com/en-us/lifecycle/announcements/bing-search-api-retirement)). Grounding with Bing is $14/1k and works only inside Azure AI Foundry agents ([Microsoft](https://www.microsoft.com/en-us/bing/apis/grounding-pricing)). Neither fits frog.

### 1.3 Quality evidence (thin)

- **AIMultiple** ([agentic search](https://aimultiple.com/agentic-search)) ran 100 AI/LLM-topic queries across 8 APIs with an LLM judge. Agent scores: **Brave 14.89** (669 ms), Firecrawl 14.58, Exa 14.39, Parallel Pro 14.21, Tavily 13.67, Parallel Base 13.50, Perplexity 12.96, SerpAPI 12.28. The authors say the top 4 are statistically tied, and only Brave beat Tavily measurably. The query topics are close to developer queries, but it's one small study.
- **Artificial Analysis** (2026-09-08, via [TinyFish summary](https://www.tinyfish.ai/blog/search-api-benchmark)) ran a full agent loop on DeepSearchQA, BrowseComp and Omniscience. **Perplexity Search came first (80)**. That is research QA, not coding.
- Exa and Parallel each publish benchmarks that favor themselves ([Exa vs Parallel](https://exa.ai/versus/parallel), [Parallel](https://parallel.ai/benchmarks)) **[vendor claim]**.
- **No benchmark I found targets coding-agent queries** such as error strings, API names or version-specific migration questions. Firecrawl's DevDex (1,179 developer queries, [launch post](https://www.firecrawl.dev/blog/developer-index-launch)) is the closest, and it comes from a vendor. **Frog should build its own 200-query eval from real session logs** before committing to anything (§3.1).

---

## 2. A hosted developer-docs index

### 2.1 What frog already has

`Docs` reads installed dependencies at exact versions, offline: the cargo registry, node_modules and site-packages. That is the highest-value case, the API of the version you actually use. A hosted index adds three things:
1. Packages **not yet installed**, e.g. when choosing a library or before `npm install`.
2. **Prose docs that don't ship in packages**: framework guides, migration notes, MDN, language references.
3. Cross-package search.

Items 2 and 3 are what web search currently handles, at $1–5 per 1k.

### 2.2 Sources: licenses, access, size

Sizes marked [measured] were measured on 2026-09-23. The rest are estimates.

| Source | License / terms | Access | Size |
|---|---|---|---|
| **MDN** | Prose CC-BY-SA 2.5+ (attribution to "Mozilla Contributors", link, note changes). Code CC0/MIT ([MDN licensing](https://developer.mozilla.org/en-US/docs/MDN/Writing_guidelines/Attrib_copyright_license)) | `mdn/content` git repo | **14,670 en-US pages, 60 MB markdown ≈ 15M tokens** [measured] |
| **Python docs** | PSF License v2. Examples also 0BSD ([license](https://docs.python.org/3/license.html)) | Official text archive per version | **3.14: 538 pages, 14.7 MB ≈ 3.7M tokens per version** [measured] |
| **Go** (go.dev, pkg docs) | Content CC-BY 4.0, code BSD ([copyright](https://go.dev/copyright)) | Repo / godoc | ~10–20M tokens incl. stdlib **[estimate]** |
| **Rust std and books** | MIT/Apache-2.0 (rust-lang repos) | rustdoc JSON / repo | ~10–20M tokens **[estimate]** |
| **docs.rs** (crates) | Each crate's license. robots.txt only blocks semver redirect URLs ([robots](https://docs.rs/robots.txt)) | **rustdoc JSON download** for builds since 2025-05-23 ([docs.rs](https://docs.rs/about/rustdoc-json)) | Doc text per crate [measured]: anyhow 27k chars, serde 107k, reqwest 116k, clap 175k, tokio 1.1M. So **~7k–280k tokens**, median-ish ~30–50k with signatures. |
| **Node.js** | MIT (nodejs/node) **[unverified for docs dir]** | Repo `doc/api` | ~5M tokens **[estimate]** |
| **Swift.org** | Apache-2.0 **[unverified]** | Repo | small |
| **Apple developer docs** | Site terms: no "page-scrape, robot, spider… to access, acquire, copy" ([Apple terms, 2009](https://www.apple.com/legal/internet-services/terms/site.html)) | Blocked | **Skip.** Look at local Xcode/DocC data instead **[unverified path]**. |
| **npm / PyPI / crates READMEs** | The package's license. Many have no explicit license text. | Registry tarballs/metadata | npm ~4.0M registry docs (May 2026), PyPI ~899k projects, crates ~337k ([Register](https://www.theregister.com/ai-ml/2026/05/21/npm-registry-sets-stage-for-more-secure-package-publishing/5244527), [PyPI](https://pypi.org/), [lib.rs stats](https://lib.rs/stats)) |
| **Framework doc sites** | Varies. Many are MIT/CC in their repos, some are proprietary. | `llms-full.txt` where present | [measured] Next.js 4.0 MB, Vercel 9.6 MB, Supabase 7.1 MB, Bun 2.1 MB, Svelte 1.2 MB (≈ 0.3–2.4M tokens each). Missing: MDN, Python, Go, Apple, docs.rs, Tailwind. |
| **GitHub READMEs / changelogs** | Repo license. GitHub API rate limits and ToS apply **[unverified: AUP scraping clause]** | API | Firecrawl claims 70M+ READMEs, issues and PRs |
| **Stack Overflow** | CC BY-SA, but the dump download agreement bars LLM training, and dumps stopped going to the Internet Archive in July 2024 ([devclass](https://devclass.com/2024/07/30/stack-exchange-restricts-access-to-dump-of-user-contributed-data-as-critics-complain-license-permits-reuse-for-any-purpose/), [Feep](https://search.feep.dev/blog/post/2025-02-20-state-of-stackexchange)) | Gated dump / paid API | **Skip.** Let web search surface SO pages and fetch them locally per user. |

**llms.txt.** Coverage is patchy but concentrated in developer SaaS:
- 28% of 137k domains publish one, but 97% of those files got zero requests in May 2026, and coding agents were the biggest AI requester at 10.5% ([Ahrefs](https://ahrefs.com/blog/llmstxt-study/)).
- 8.7% of the top 1,000 sites (June 2026) ([Rankability](https://www.rankability.com/data/llms-txt-adoption/)).
- Adoption is "routine among developer-facing SaaS" ([Presenc](https://presenc.ai/research/state-of-llms-txt-2026)).
- Mintlify generates both files automatically for every hosted site ([Mintlify](https://www.mintlify.com/docs/ai/llmstxt)).
- The big language references mostly *don't* have one.

### 2.3 Cost model

Assumptions [estimate]:
- Top packages average ~60k doc tokens (top 2k), 40k (top 10k) and 20k (top 50k, long tail).
- Versions are kept as latest plus ~2 prior minors. Dedup'd chunks come to ≈1.5x one version.
- Core references and framework sites add ~0.3–0.7B tokens.
- Chunks are ~400 tokens.

| | Top 2k | Top 10k | Top 50k |
|---|---|---|---|
| Tokens indexed | ~0.5B | ~1.1B | ~2.2B |
| Chunks | ~1.25M | ~2.75M | ~5.5M |
| **One-time embed**: text-embedding-3-small $0.02/M ($0.01 batch) → voyage-code-3/4 $0.12/M ($0.08 batch) | $5–60 | $11–130 | $22–265 |
| Self-hosted embed (Qwen3-Embedding-0.6B / bge-m3 class, ~$0.8–1.9 per **billion** tokens on A5000–H200 per RunPod) | <$1 GPU time | ~$2 | ~$4 |
| Monthly re-embed (~20% churn) | $1–12 | $2–26 | $4–53 |
| Storage: 1024-d vectors (int8 1 KB, f32 4 KB) + text + BM25 | ~4–8 GB | ~9–17 GB | ~18–35 GB |
| **Serving: one dedicated box** (64–128 GB RAM; tantivy BM25 + HNSW in Rust) | ~$50–100/mo **[unverified host price]** | ~$80–150 | ~$150–300 |
| or turbopuffer (≤$0.33/GB-mo storage, ≤$2/GB writes, $1/PB queried with a 1.28 GB minimum per query ≈ $1.3 per million queries; $16/mo minimum) | ~$16–30 | ~$20–50 | ~$30–100 |
| Crawl/build bandwidth (registry tarballs, rustdoc JSON, git pulls) | negligible on unmetered hosting | tens of GB/mo | ~100+ GB/mo |
| Build compute (Sphinx/TypeDoc builds for packages that don't ship docs) | small | a worker box, $50–100 | $100–200 |
| **Rough infra total/month** | **~$50–100** | **~$100–250** | **~$200–500** |

Sources: [Voyage pricing](https://docs.voyageai.com/docs/pricing); OpenAI $0.02/M via [third-party trackers](https://costgoat.com/pricing/openai-embeddings) (openai.com returned 403) [unverified]; [RunPod embedding benchmark](https://www.runpod.io/blog/gpu-embedding-workloads-benchmark); [turbopuffer pricing log](https://turbopuffer.com/docs/pricing-log) (per-GB rates via [third party](https://mixpeek.com/guides/vector-database-cost-comparison) [unverified]).

Queries cost almost nothing: one ~30-token embedding plus BM25 and ANN on one box handles hundreds of QPS. **Infra is not the cost. People are.** The work is:
- a parser for each doc system (rustdoc JSON, Sphinx, TypeDoc/`.d.ts`, Docusaurus, Mintlify, MkDocs, DocC)
- version tracking per registry
- attribution for CC-BY(-SA) sources
- handling takedowns
- a freshness monitor

That is realistically **a person-month to build, then ongoing maintenance** [estimate].

### 2.4 Prior art

- **Context7 (Upstash).** ~104k–126k libraries depending on the source **[unverified]**. Free tier is 1k calls/mo. Pro is $10/seat with 5k calls, then **$10 per 1k calls** ([plans](https://context7.com/plans)). At that overage rate, docs lookups alone cost more than search does. Users complain that it "injects a huge amount of tokens" ([mcp.directory](https://mcp.directory/blog/context7-vs-deepwiki-vs-ref-vs-docfork-2026)). Firecrawl measured 16.8% overall recall on repo and issue queries, though those are outside Context7's docs-only scope ([Firecrawl, 2026-08-31](https://www.firecrawl.dev/blog/best-context7-alternatives)) **[competitor claim]**.
- **Mintlify Index.** "Publisher-direct" rather than crawled, 200k+ orgs. Mintlify claims 2x faster tasks and +9% accuracy versus Context7 ([Mintlify](https://www.mintlify.com/search-index), [X](https://x.com/mintlify/status/2085410422111494651)) **[vendor claim]**. Free MCP. **Terms for embedding it in another product are unknown.**
- **Firecrawl Developer Index** (launched 2026-08-20). 70M+ READMEs, issues, PRs and docs, refreshed daily. Costs 2 credits per 10 results, about $1.66/1k at Standard ([docs](https://docs.firecrawl.dev/features/developer), [launch](https://www.firecrawl.dev/blog/developer-index-launch)). It is the cheapest "buy" option to benchmark against a build.
- **Ref.tools** (~5k-token capped results, $19/mo), **Docfork** (scopes to `package.json`, MIT), **DeepWiki** (free, LLM-generated wikis that sometimes hallucinate), **GitMCP** ([comparison](https://mcp.directory/blog/context7-vs-deepwiki-vs-ref-vs-docfork-2026)).
- **Kapa.ai** sells docs-QA to vendors, sales-led, with deals reportedly averaging ~$3k/yr and a median ~$19k ([Vendr](https://www.vendr.com/marketplace/kapa-ai)) **[unverified]**. It's the publisher side, not a consumer index.
- **DevDocs** and **Sourcegraph**: I didn't re-research them this round. The knowledge-systems report covers Sourcegraph dropping embeddings for search.
- **Perplexity/Phind**: they run general web indexes, not docs-specific ones. I found no current public detail on docs-specific handling **[unverified]**.
- The **knowledge-systems report** (same folder) found that semantic search *alongside* grep helps (+12.5% in Cursor's numbers), and that pushing ranked, budgeted context helps weak models more than pull-style search does. A docs index fits that pattern only if it returns small, version-matched snippets.

---

## 3. Recommendation

### 3.1 Web search

1. **Primary: Brave Search API.** Use the web endpoint for link lists and the **LLM Context** endpoint when the agent wants an answer. Cap it at 2–4k tokens for small models, so that a search often replaces 1–2 fetches.
2. **Fallback and overflow: Parallel Search Fast** ($1/1k). Use it when Brave errors, rate-limits or times out, and once the user has used up their included Brave searches.
3. **Before launch:** build a **200-query eval from real frog session logs** covering error strings, API names, "how do I X in lib@version" and migration questions. Score Brave, Brave LLM Context, Parallel Fast, Exa and Perplexity with the same judge. Budget ~$10 [calc]. If Parallel Fast ties Brave, flip the default and save 80%. **Don't put any Brave-derived results into eval fixtures** (training/benchmark clause). Record the eval on the non-Brave providers, or get written permission.
4. **Keep BYOK and SearXNG** for free-tier users. A personal Brave key comes with its own $5/month credit, about 1,000 searches.
5. **Legal:** accept Brave's standard terms. Add flow-down restrictions to frog Pro's ToS (§4.3). Show "Powered by Brave" wherever results appear in the UI. Ask for Brave ZDR/enterprise terms once volume justifies it. Exa needs an MSA before it can be used at all.

### 3.2 Docs index: MVP that tests value cheaply

- **Step 0 ($0, about a week).**
  - Classify existing WebSearch/WebFetch calls in session logs as docs lookup vs other, then find which domains get fetched and whether the package was installed locally.
  - Teach WebFetch/Docs to prefer a site's `llms-full.txt`/`llms.txt` when present: fetch it once, cache it locally, and rank its sections with the existing `rank.rs`. That gives version-less framework docs at zero hosted cost.
  - Add rustdoc-JSON download from docs.rs to `Docs` for crates that aren't in the local registry.
- **Step 1 (≈$50–100/month, 4–6 weeks):** a hosted pilot.
  - Content: permissively licensed core references (MDN with attribution, Python, Go, Rust, Node) plus ~300 framework doc sites and the **latest version of the top 2k packages**.
  - Search: BM25-first, with embeddings as a second ranker.
  - Placement: a fallback inside `Docs` for packages that aren't installed.
  - Also run Firecrawl Developer Index and Mintlify Index (if their terms allow) through the same eval.
- **Go/kill criteria.** Keep building if at least one holds:
  - more than ~25% of Pro users' searches are docs lookups, **and** the pilot answers most of them with a measurable `frog bench` gain over web search alone;
  - it saves more web-search spend than it costs.

  Otherwise stop, and use a bought index or plain web search.
- **Don't build:** Stack Overflow ingestion, Apple docs scraping, or per-version history beyond latest plus 2 minors.

### 3.3 Caching, dedup and privacy

- **Page fetches stay on the user's machine.** That means no fetch cost, no provider terms, no shared-cache copyright question, and the user's IP rather than a datacenter's, so blocking is rare.
- **Search results: per-user only.** Dedupe in flight and keep a per-session cache (minutes to hours). That is defensible as "transient storage required for operation" under Brave, and Parallel's terms allow single-end-customer use. **Don't share a result cache across users.** Both Brave (§3.2) and Parallel forbid it, and for agents the hit rate would be low anyway, because queries carry project-specific identifiers.
- **Privacy.** Agent queries leak code: symbol names, internal hostnames, error text, occasionally secrets. So the pipeline should:
  - run the existing secret-redaction pass on queries before they leave the machine
  - avoid logging query text on the proxy, keeping only counts and hashed per-user rate limits
  - choose providers that don't train on inputs, which **rules out Tavily's default terms**
  - move to ZDR terms once volume allows
- **The docs index is the right place for cross-user dedup.** Its content is public and shared, one crawl serves everyone, and queries against it can stay anonymous.

### 3.4 Cost envelope per Pro user (search only)

| Usage | Brave only | Parallel Fast only | Blended (first 1k on Brave, rest on Parallel) |
|---|---|---|---|
| Light (10/day, 300/mo) | $1.50 | $0.30 | $1.50 |
| Median guess (30/day, 900/mo) | $4.50 | $0.90 | $4.50 |
| Heavy low (50/day, 1.5k/mo) | $7.50 | $1.50 | $5.50 |
| Heavy high (200/day, 6k/mo) | $30.00 | $6.00 | $10.00 |

Hosted fetch/extraction would add $3–30/month for a heavy user at $1/1k pages (Exa, You.com or Parallel Extract). That's the reason to keep fetches local.

- **Budget rule:** search COGS should stay at or under ~25% of the price, i.e. about **$4–5 on a $15–20 plan**, next to payment fees (~$0.75–1) and docs-index infra amortized across users.
- The blended plan meets that budget up to about 1,000 searches, then costs about $1 per extra 1k.
- **Sensible packaging:** "1,000 premium searches/month, then fast search included up to a fair-use cap (e.g. 6k), then credits."
- Even the 200/day user then costs about **$10/month** [calc]. The docs index, if built, adds under $0.10/user/month at a few thousand users.

---

## Unverified or missing

- The Perplexity API terms (403), OpenAI's embedding pricing page (403) and Jina's token top-up price (404) couldn't be loaded.
- No terms reviewed for Linkup, You.com, Kagi or Mintlify Index.
- Tavily rate limits and whether Tavily has its own index; the index behind Jina search.
- Firecrawl plan billing period.
- Turbopuffer's per-GB list rates; dedicated-server prices.
- Context7's library count.
- Node/Swift docs licenses, GitHub AUP scraping language, Xcode local docs.
- All docs size figures except MDN, Python, the docs.rs samples and the llms-full.txt files, which were measured.
- No coding-specific search benchmark exists. The quality ranking above is weak evidence.
