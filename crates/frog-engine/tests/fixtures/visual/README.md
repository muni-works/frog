# Foreground false-positive regression

The target was generated locally by Z-Image-Turbo (seed 43, eight steps, 256x256)
through real Frog Image. Checkpoint fingerprint:
`sha256:9945b58af7779078087efc44468bd8e4ade38c6c55e87668030b89f56bd1cfa3`.
Prompt: a simple flat green frog-face icon with two eyes and a white background.
The wrong image is a Chromium capture of CSS produced by a real Qwen3 coding run.
It contains a single vertical green ellipse and omits the target's eyes. Gemma 3
4B falsely scored the pair at 95; global SSIM was about 0.814. These retained pixels
verify that coarse foreground overlap prevents that false match. Neither file has
been modified to improve the benchmark result.
