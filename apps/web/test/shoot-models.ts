// Draws the composer's model menu (parity/models.html?view=picker) at desktop and phone width,
// for each machines fixture, as models-<machines>-<width>.png into $FROG_MODEL_SHOTS (default:
// the scratch dir you pass). Headless: nothing takes the screen.
// `FROG_MODEL_SHOTS=/tmp/x node --import tsx test/shoot-models.ts`
import { writeFileSync } from "node:fs";
import { chrome, serve } from "./chrome.ts";
import { open, pause } from "./cdp.ts";

const out = process.env.FROG_MODEL_SHOTS;
if (!out) throw new Error("set FROG_MODEL_SHOTS");
if (!chrome) throw new Error("no Chrome");
const s = await serve();
try {
  for (const machines of ["none", "node", "all"]) {
    for (const [w, h, phone] of [[760, 760, false], [390, 844, true]] as const) {
      const top = phone ? 520 : 440, pad = phone ? 8 : 24;
      const page = await open(`${s.origin}/parity/models.html?view=picker&theme=dark&machines=${machines}&top=${top}&pad=${pad}`, w, h);
      if (phone) {
        await page.call("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 2, mobile: false });
        await page.call("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 });
        await page.call("Page.reload");
      }
      await pause(2500);
      const shot = (await page.call("Page.captureScreenshot", { format: "png" })) as { data: string };
      writeFileSync(`${out}/models-${machines}-${w}.png`, Buffer.from(shot.data, "base64"));
      await page.close();
    }
  }
} finally { await s.close(); }
