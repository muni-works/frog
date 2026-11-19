// design/settings.json is the one list of settings both apps draw (docs/design/app-shell.md,
// Settings). These hold it to the shape both apps read and to board 7 of the settings canvas
// (2026-11-18): nine sections in order, the 42 rows that survived its cuts (23 both, 12 invite,
// 7 Mac), none of the five it cut, and every reason a row can't work yet written down.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

type Opt = { id: string; label: string; description?: string };
type Row = {
  id: string; section: string; group?: string; label: string; description?: string
  control: string; platform: string; options?: Opt[]; when?: string; page?: string
  web?: { label: string; description?: string }; notYet?: Record<string, string>
};
const file = JSON.parse(readFileSync(new URL("../../../design/settings.json", import.meta.url), "utf8")) as {
  version: number; sections: { id: string; label: string; aliases?: string[] }[]; rows: Row[]
};
const rows = file.rows;
const byId = new Map(rows.map((r) => [r.id, r]));

test("nine sections, in the shell's order, with the old tab names as aliases", () => {
  assert.equal(file.version, 1);
  assert.deepEqual(file.sections.map((s) => s.label), ["General", "Appearance", "Models", "Permissions", "Connections", "Shortcuts", "Usage", "Account", "Billing"]);
  const alias = (a: string) => file.sections.find((s) => s.aliases?.includes(a))?.id;
  assert.equal(alias("mcp"), "connections");
  assert.equal(alias("energy"), "usage");
  assert.equal(alias("lend"), "models");
});

test("every row has a known section, control and platform, and a unique id", () => {
  const sections = new Set(file.sections.map((s) => s.id));
  const controls = new Set(["toggle", "segmented", "menu", "field", "button", "value", "list"]);
  const platforms = new Set(["both", "invite", "mac", "web"]);
  assert.equal(byId.size, rows.length, "duplicate row id");
  for (const r of rows) {
    assert.ok(sections.has(r.section), `${r.id}: section ${r.section}`);
    assert.ok(controls.has(r.control), `${r.id}: control ${r.control}`);
    assert.ok(platforms.has(r.platform), `${r.id}: platform ${r.platform}`);
    assert.ok(r.label && !r.label.endsWith(":"), `${r.id}: a label, no colon`);
    if (r.control === "segmented") assert.ok(r.options && r.options.length >= 2 && r.options.length <= 4, `${r.id}: segmented takes two to four choices`);
    if (r.when) assert.equal(byId.get(r.when)?.control, "toggle", `${r.id}: when names a toggle`);
    if (r.page) assert.ok(r.page === "machine" || r.page === "provider", `${r.id}: page ${r.page}`);
    if (r.web) assert.equal(r.platform, "invite", `${r.id}: only an invitation has web words`);
    for (const [p, why] of Object.entries(r.notYet ?? {})) {
      assert.ok(p === "web" || p === "mac", `${r.id}: notYet.${p}`);
      assert.ok(why.length > 20, `${r.id}: notYet.${p} says why`);
    }
  }
});

test("rows run in section order, so a section is one run of the list", () => {
  const order = file.sections.map((s) => s.id);
  const idx = rows.map((r) => order.indexOf(r.section));
  assert.deepEqual(idx, [...idx].sort((a, b) => a - b));
});

// Board 7 lists 23 both; Frog Cloud (account and credit) in Models is board 2's and board 5's, which
// board 7 left off its list without cutting it, so it stays: 24.
test("board 7's verdicts: 23 both plus Frog Cloud, 12 invite, 7 Mac plus Share usage, and one web-only fact", () => {
  const ids = (p: string) => rows.filter((r) => r.platform === p).map((r) => r.id)
  assert.deepEqual(ids("both"), ["notifications", "auto-note", "theme", "density", "detail", "playful", "sounds", "default-model", "machines", "frog-cloud", "default-mode", "mcp-servers", "shortcuts", "spent", "monthly-cap", "show-energy", "energy-chart", "profile", "sign-ins", "devices", "plan", "credit", "coupon", "credit-history", "prices"]);
  assert.deepEqual(ids("invite"), ["editor", "iphone", "pair-machine", "local-models", "machine-name", "share-models", "other-clouds", "servers", "sandbox", "computer-use", "mcp-sign-in", "measured-energy"]);
  // Plus "Share usage with Frog" (b5edfe37, after the canvas): the Mac app's own opt-in.
  assert.deepEqual(ids("mac"), ["share-usage", "update-pause", "update-wait", "lend-battery", "pair-mac", "provider-models", "allowed-commands", "mcp-config"]);
  assert.deepEqual(ids("web"), ["cloud-sandbox"]);
});

test("board 7's moves: Notifications in General, spend and the cap in Usage, Lend in Models", () => {
  assert.equal(byId.get("notifications")?.section, "general");
  assert.equal(byId.get("spent")?.section, "usage");
  assert.equal(byId.get("monthly-cap")?.section, "usage");
  assert.equal(byId.get("share-models")?.section, "models");
  assert.equal(byId.get("lend-battery")?.when, "share-models");
});

test("board 7's cuts stay cut", () => {
  const labels = rows.map((r) => r.label.toLowerCase());
  for (const gone of ["new messages use", "show cloud models in the picker", "lend this mac", "show energy use"]) {
    assert.ok(!labels.includes(gone), `${gone} is cut`);
  }
  // The four mode explanations are the selected mode's description, not rows of their own.
  const mode = byId.get("default-mode")!;
  assert.deepEqual(mode.options?.map((o) => o.label), ["Ask", "Edits", "Auto", "Yolo"]);
  assert.ok(mode.options?.every((o) => o.description));
  assert.equal(rows.filter((r) => r.section === "permissions" && r.control === "value" && r.platform !== "web").length, 0);
});

test("no 'new' badge anywhere in the words", () => {
  for (const r of rows) assert.doesNotMatch(JSON.stringify(r), /\bnew!|\(new\)|"new"/i, r.id);
});
