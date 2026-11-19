// Draws the where menu on an account with forty repos (parity/composer.html?menu=where) as
// where-many-web-<theme>.png into $FROG_COMPOSER_SHOTS, else docs/design/composer/.
// `node --import tsx test/shoot-where.ts`
import { fileURLToPath } from "node:url";
import { chrome, screenshot, serve } from "./chrome.ts";

const out = process.env.FROG_COMPOSER_SHOTS ?? fileURLToPath(new URL("../../../docs/design/composer/", import.meta.url));
if (!chrome) throw new Error("no Chrome");
const s = await serve();
try {
  for (const theme of ["dark", "light"]) {
    await screenshot(`${s.origin}/parity/composer.html?state=new-cloud&menu=where&theme=${theme}`, 760, 1300, `${out}/where-many-web-${theme}.png`);
  }
} finally { await s.close(); }
