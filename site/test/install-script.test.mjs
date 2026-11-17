import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, chmodSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

const script = new URL("../install.sh", import.meta.url).pathname;

// Runs install.sh against a local "release": a fake curl serves files from a folder by name.
function install(files) {
  const root = mkdtempSync(join(tmpdir(), "frog-install-"));
  const fake = join(root, "fakebin");
  const rel = join(root, "release");
  const dir = join(root, "bin");
  mkdirSync(fake);
  mkdirSync(rel);
  const env0 = { PATH: `${fake}:/usr/bin:/bin`, HOME: root };
  const target = execFileSync("sh", [script], { env: { ...env0, FROG_INSTALL_DRY_RUN: "1" }, encoding: "utf8" })
    .match(/^target=(.*)$/m)[1];
  const name = `frog-v9.9.9-${target}`;
  mkdirSync(join(rel, name));
  for (const f of files) {
    writeFileSync(join(rel, name, f), `#!/bin/sh\necho ${f}\n`);
    chmodSync(join(rel, name, f), 0o755);
  }
  execFileSync("tar", ["-C", rel, "-czf", join(rel, `${name}.tar.gz`), name]);
  const sum = createHash("sha256").update(readFileSync(join(rel, `${name}.tar.gz`))).digest("hex");
  writeFileSync(join(rel, `${name}.tar.gz.sha256`), `${sum}  ${name}.tar.gz\n`);
  // curl -fsSL URL -o OUT: copy the URL's last path segment out of the release folder.
  writeFileSync(join(fake, "curl"), `#!/bin/sh\nsrc="${rel}/$(basename "$2")"\n[ -f "$src" ] || exit 22\ncp "$src" "$4"\n`);
  chmodSync(join(fake, "curl"), 0o755);
  const out = execFileSync("sh", [script], {
    env: { ...env0, FROG_VERSION: "v9.9.9", FROG_INSTALL_DIR: dir },
    encoding: "utf8",
  });
  return { out, dir };
}

test("installs frog-apple next to frog when the tarball has it", () => {
  const { out, dir } = install(["frog", "frog-apple"]);
  assert.match(out, /installed frog v9\.9\.9/);
  assert.equal(execFileSync(join(dir, "frog"), { encoding: "utf8" }).trim(), "frog");
  assert.equal(execFileSync(join(dir, "frog-apple"), { encoding: "utf8" }).trim(), "frog-apple");
});

test("a tarball with only frog installs only frog", () => {
  const { dir } = install(["frog"]);
  assert.ok(existsSync(join(dir, "frog")));
  assert.ok(!existsSync(join(dir, "frog-apple")));
});
