# SVG asset tracing

`Image` can save generated PNG assets and generation manifests directly in a project.
Keep those originals. For flat icons and sprites, the optional VTracer utility produces
a new SVG plus a source-hash/tracing manifest, without overwriting existing assets.

```sh
python3 -m venv .venv
.venv/bin/pip install -r /path/to/frog/scripts/asset-requirements.txt
.venv/bin/python /path/to/frog/scripts/vectorize_asset.py assets/icon.png assets/icon.svg
```

Run from the project root or pass `--workspace /path/to/project`. Both paths must
stay inside that workspace, including symlink resolution. Sources must be still
PNG, JPEG or WebP, at most 4096 pixels per axis and eight million pixels total.
The utility rejects photos by default using dominant-color coverage; `--force`
explicitly overrides that heuristic. `--mode none` preserves pixel-art corners.
Tracing is lossy and requires visual review; it does not recover source typography.

Render the SVG with `Screenshot` at the raster's viewport and use `Compare` with the
original PNG target. Keep one bounded loop_id and fix or retain the raster if the
trace fails to match. The utility's manifest identifies the source bytes; retain the
Image generation manifest alongside the source for prompt, backend, seed and steps.

Validation: a real local Z-Image icon generated through Frog was traced, captured by
the Chromium sidecar and compared using local Gemma vision. The bounded match and
restart checks passed. Fixture chat selected the tools; this is an asset-path test,
not an unattended coding benchmark. Synthetic transparency/color checks, photo
rejection, workspace containment and existing-output preservation also passed.

VTracer's [Python API](https://pypi.org/project/vtracer/) provides the tracing implementation.
