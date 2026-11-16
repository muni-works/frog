# Your own nodes

A node is a Linux machine of yours, usually one with a GPU, that runs models for Frog. Your code goes to that machine and nowhere else.

## Set one up

On the Linux machine:

```sh
curl -fsSL https://frog.toys/node | sh
```

It installs Frog's model server (the CUDA build when it finds an NVIDIA GPU, else the CPU build), runs it as a service that announces itself on your local network, and prints a pairing code. Running it again upgrades it. `sh -s -- --uninstall` removes it.

<!-- only: mac -->
Then, in the Mac app, Settings › Models › Pair a machine…, and enter the code.
<!-- end -->

<!-- only: web -->
Pair the node from the Mac app. Sessions on the web run in Frog Cloud, so they don't use your nodes.
<!-- end -->

<!-- only: terminal -->
## Other servers

Any server that speaks the OpenAI API works as a provider:

```sh
frog --add-provider gpu http://gpu.local:8000/v1
frog -m gpu/<model>
```

`--provider-kind ollama` adds an Ollama server instead. `--remove-provider gpu` removes it.
<!-- end -->
