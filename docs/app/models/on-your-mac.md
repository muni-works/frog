# On your Mac

A model on your Mac is free to use, and your code doesn't leave the Mac.

<!-- only: web -->
Sessions on the web run in Frog Cloud, so they can't use a model on your Mac. Once your Mac is paired, the model menu lists its models; they run from the Mac app.
<!-- end -->

<!-- only: mac, terminal -->
## Frog's own engine

Frog runs Qwen3 models on the Mac's GPU with its own engine. `local/qwen3-4b` and `local/qwen3-32b` are short for the 4-bit `mlx-community/Qwen3-4B-4bit` and `Qwen3-32B-4bit`; any Hugging Face repo or folder with a Qwen3 checkpoint works too.

<!-- end -->

<!-- only: mac -->
## Apple Intelligence

On a Mac with Apple Intelligence turned on, Frog can use Apple's on-device model. It has an 8k context, so it suits short tasks.
<!-- end -->

<!-- only: mac, terminal -->
## Ollama and LM Studio

Models installed in Ollama show up in the model list while Ollama runs, as `ollama/<model>`. A model in LM Studio is used as `lmstudio/<model>` when you name it, or when Frog picks a model on its own and LM Studio is running.
<!-- end -->

<!-- only: terminal -->
`frog setup` installs the engine and downloads a model's weights (`qwen3-4b` unless you name another). The first time a local model is used, Frog sends it a few small test requests to learn how it handles tools, and keeps the result.
<!-- end -->
