import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, chmodSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = new URL("../node.sh", import.meta.url).pathname;

// Runs node.sh --dry-run in a scratch HOME, with a PATH that has (or lacks) a fake nvidia-smi.
function dry(args = [], { gpu = null, arch = "x86_64" } = {}) {
  const home = mkdtempSync(join(tmpdir(), "frog-node-"));
  const fake = join(home, "fakebin");
  execFileSync("mkdir", ["-p", fake]);
  if (gpu) {
    writeFileSync(join(fake, "nvidia-smi"), `#!/bin/sh\necho "${gpu}"\n`);
    chmodSync(join(fake, "nvidia-smi"), 0o755);
  }
  const env = { HOME: home, PATH: `${fake}:/usr/bin:/bin`, TANG_NODE_OS: "Linux", TANG_NODE_ARCH: arch };
  const out = execFileSync("sh", [script, "--dry-run", ...args], { env, encoding: "utf8" });
  return { out, home };
}

test("NVIDIA box gets the CUDA build, a user unit, and a pairing step", () => {
  const { out, home } = dry([], { gpu: "NVIDIA GeForce RTX 3090" });
  assert.match(out, /releases\/latest\/download\/tang-llm-x86_64-unknown-linux-gnu-cuda12\.tar\.gz/);
  assert.match(out, /RTX 3090/);
  assert.match(out, new RegExp(`write ${home}/\\.config/systemd/user/tang-node\\.service`));
  assert.match(out, /ExecStart=.*\/\.local\/bin\/tang-llm serve --host 0\.0\.0\.0 --port 8911/);
  assert.match(out, /WantedBy=default\.target/);
  assert.match(out, /systemctl --user enable tang-node\.service/);
  assert.match(out, /\[dry-run\] .*tang-llm pair$/m);
  assert.doesNotMatch(out, /sudo/);
  assert.ok(!existsSync(join(home, ".local/bin")), "dry run must not touch the disk");
});

test("no GPU, arm64, pinned version, a model and a port", () => {
  const { out } = dry(["--model", "Qwen/Qwen3-4B", "--port", "9000", "--no-pair"], { arch: "aarch64" });
  assert.match(out, /tang-llm-aarch64-unknown-linux-gnu\.tar\.gz/);
  assert.match(out, /serve Qwen\/Qwen3-4B --host 0\.0\.0\.0 --port 9000/);
  assert.doesNotMatch(out, /\[dry-run\] .* pair/);
});

test("--cpu ignores the GPU; --system uses sudo and a system unit", () => {
  assert.doesNotMatch(dry(["--cpu"], { gpu: "RTX" }).out, /cuda12/);
  const { out } = dry(["--system"]);
  assert.match(out, /sudo systemctl enable tang-node\.service/);
  assert.match(out, /write \/etc\/systemd\/system\/tang-node\.service/);
  assert.match(out, /User=/);
  assert.match(out, /WantedBy=multi-user\.target/);
});

test("--uninstall disables the unit and removes the binary", () => {
  const { out, home } = dry(["--uninstall"]);
  assert.match(out, /systemctl --user disable --now tang-node\.service/);
  assert.match(out, new RegExp(`rm -f ${home}/\\.local/bin/tang-llm`));
});

test("bad options fail", () => {
  assert.throws(() => dry(["--port", "abc"]));
  assert.throws(() => dry(["--bogus"]));
});
