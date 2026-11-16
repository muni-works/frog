# Your own keys

With an account at a model provider, Frog can use that provider's models with your key. Requests go straight to the provider, and the provider bills you.

<!-- only: mac -->
In the Mac app, a model that needs a key has Add Key… next to it.
<!-- end -->

<!-- only: web -->
The web app uses Frog Cloud's models only. Your own keys work in the terminal.
<!-- end -->

<!-- only: terminal -->
| Provider | Models as | Key in |
| --- | --- | --- |
| Anthropic | `anthropic/<model>` | `ANTHROPIC_API_KEY` |
| OpenAI | `openai/<model>` | `OPENAI_API_KEY` |
| OpenRouter | `openrouter/<model>` | `OPENROUTER_API_KEY` |
| Vercel AI Gateway | `vercel/<model>` | `AI_GATEWAY_API_KEY` |

To store a key with Frog instead of in the environment:

```sh
echo "$KEY" | frog --set-key anthropic
```

An empty key removes it. `frog --providers` shows which providers have a key.
<!-- end -->
