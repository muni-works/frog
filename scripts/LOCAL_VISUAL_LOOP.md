# Real local visual-loop benchmark

`test_local_visual_loop.py` drives the real Frog agent against existing local chat,
image and screenshot services. It does not select tool calls with a fixture, write
the implementation or supply comparison scores. The model must generate a target,
write editable HTML/CSS, capture it and reach a bounded Compare match at score 85.
Outputs include the generated asset manifests, implementation, screenshots, all
protocol events and a native Frog replay file, including on failure.

```sh
python3 scripts/test_local_visual_loop.py \
  --frog /path/to/frog \
  --base-url http://127.0.0.1:18913/v1 \
  --model /path/to/local-chat-model \
  --image-endpoint http://127.0.0.1:18913/v1/images/generations \
  --screenshot-endpoint http://127.0.0.1:18914/v1/screenshots \
  --output /path/to/new-benchmark-directory
```

Use `--tool-mode text` for a server without constrained JSON generation. The output
directory must be new. Only loopback endpoints are accepted; write permissions are
limited to that directory, and shell/task permissions are denied. Read follows
Frog's ordinary permissions. Run only with local services and files intended for
the benchmark. A completed tool integration test does not establish coding quality.

For a separate local coding model and vision judge, add `--judge-base-url` and
`--judge-model`. Add `--coder-no-vision` if the coding model cannot consume images;
it must then use the vision judge's differences rather than claiming direct visual
inspection. This option requires the separate judge profile. Both endpoints must
remain local. The existing Z-Image Qwen3 text encoder can be exposed through an
isolated model-directory view with its tokenizer, without downloading new weights.

Initial Gemma 3 4B JSON-mode runs generated targets and CSS pages but stopped before
Compare; one emitted a fenced valid action, now recovered by Frog, while subsequent
replies broke the format or failed the implementation requirements. Those runs do
not pass the benchmark. Keep failed event logs rather than manually fixing output.
