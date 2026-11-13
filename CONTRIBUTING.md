# Contributing to frog

Thanks for helping. Bug reports, fixes and new tools are all welcome.

## Getting set up

```sh
cargo build
cargo test -p frog-engine
```

Keep changes small and focused, match the style of the code around them, and add a test when
you fix a bug. Run `rustfmt` on the files you touch (please don't reformat whole crates).

### A test written to catch a bug must be shown to fail without the fix

"Add a test when you fix a bug" isn't enough by itself. A test written *to catch a bug* is
worthless until you have watched it go red with the fix removed: a test that passes both with
and without the fix looks exactly like a passing test, and it will tell you nothing the next
time that code changes. Before you call a bug fixed, revert the fix, confirm the test fails,
then put the fix back.

The distinction is *tests written to catch a bug* versus *tests written to describe behaviour*.
A description test (the warning fires, the error names the provider, the button is disabled) is
fine as it stands. A regression test — this used to compute the wrong number, this used to hang,
this used to leak the upstream — needs the red proof.

This is not ceremony. A relay fix once shipped with a test that passed 416/416 with the fix
removed, and the bug it was written to catch was invisible to it.

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
