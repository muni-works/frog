# Contributing to frog

Thanks for helping. Bug reports, fixes and new tools are all welcome.

## Getting set up

```sh
cargo build
cargo test -p frog-engine
```

Keep changes small and focused, match the style of the code around them, and add a test when
you fix a bug. Run `rustfmt` on the files you touch (please don't reformat whole crates).

## License and sign-off

frog is dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
Contributions are accepted under the same terms (inbound = outbound): unless you say otherwise,
anything you submit is licensed as MIT OR Apache-2.0, with no additional terms.

We use the [Developer Certificate of Origin](https://developercertificate.org/) instead of a
CLA. Sign off each commit to certify you wrote it or have the right to submit it:

```sh
git commit -s
```

which adds a line like `Signed-off-by: Your Name <you@example.com>`.

## Security

Please don't file security issues publicly; see [SECURITY.md](SECURITY.md).
