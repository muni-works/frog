// Draws the Preview tab's states into docs/design/inspector as preview-<state>-web-<theme>.png
// (parity/preview.tsx in headless Chrome; macOS, for sips). `node --import tsx test/shoot-preview.ts`
import { fileURLToPath } from "node:url";
import { chrome, screenshot, serve } from "./chrome.ts";

const out = fileURLToPath(new URL("../../../docs/design/inspector/", import.meta.url));
// [file name, parity state, inspector width]
const SHOTS: [string, string, number][] = [
  ["empty", "empty", 420], ["loaded", "loaded", 420], ["narrow", "loaded", 360], ["loading", "loading", 420],
  ["failed", "failed", 420], ["unavailable", "unavailable", 420], ["phone", "phone", 420], ["tablet", "tablet", 420],
  ["desktop", "desktop", 420], ["devices", "devices", 420], ["more", "more", 360],
];
if (!chrome) throw new Error("no Chrome");
const s = await serve();
try {
  for (const theme of ["dark", "light"]) for (const [name, state, w] of SHOTS) {
    await screenshot(`${s.origin}/parity/preview.html?state=${state}&w=${w}&h=560&theme=${theme}`, w, 560, `${out}preview-${name}-web-${theme}.png`);
  }
} finally { await s.close(); }
