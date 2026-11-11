# tang Linux release artifacts (what `frog.toys/node` downloads)

`site/node.sh` downloads from `https://github.com/muni-works/tang/releases/latest/download/`
(or `/releases/download/$TANG_VERSION/`), same naming as `mac-release.yml`:

| Asset | Built with |
| --- | --- |
| `tang-llm-x86_64-unknown-linux-gnu-cuda12.tar.gz` | `--no-default-features --features cuda`, CUDA 12.8 |
| `tang-llm-x86_64-unknown-linux-gnu.tar.gz` | CPU, default features |
| `tang-llm-aarch64-unknown-linux-gnu-cuda12.tar.gz` | CUDA 12.x (Jetson Orin/Thor class) |
| `tang-llm-aarch64-unknown-linux-gnu.tar.gz` | CPU |

Each tarball holds one file, `tang-llm`, at its root, with a `<asset>.sha256` beside it
(`sha256sum` output; the installer checks it).

## The job tang needs

`.github/workflows/linux-release.yml`, on `push: tags: v*` plus `workflow_dispatch` with a
`tag` input, like `mac-release.yml`:

- matrix over the four assets. x86_64 on `ubuntu-22.04` (glibc 2.35 floor), aarch64 on
  `ubuntu-22.04-arm`.
- CUDA legs: container `nvidia/cuda:12.8.1-devel-ubuntu22.04` (needs no GPU to build).
  `cargo build --release -p tang-llm --no-default-features --features cuda --target <triple>`.
  Driver floor for users is then 570+; the RTX 3090 on mew runs 580.
- Package: `tar -C dist -czf $ASSET tang-llm; sha256sum $ASSET > $ASSET.sha256`;
  `gh release upload "$TAG" ... --clobber` (create the release if the mac job hasn't).

Until it exists, `TANG_NODE_TARBALL=/path/to/tang-llm.tar.gz sh node.sh` installs a local build.

## Engine behaviour the installer and the Mac toggle assume

- `tang-llm serve` with no model (the unit runs `serve --host 0.0.0.0 --port 8911`; the Mac
  runs port 8920). Today `serve` requires a model; `--model M` in the installer works around it.
- `tang-llm pair [--port P]` → `POST /pair/open` on loopback, prints code + fingerprint.
