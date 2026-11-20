// node --import tsx probe.ts <path|@session|@fresh-session> <width> <js...>  (each js evaluated in turn, results printed)
import { rig, shot } from "./phone-rig.ts";
import { until, pause } from "./cdp.ts";
const [, , where, width, ...js] = process.argv;
const r = await rig();
try {
  const k = "frog_probe";
  await r.call(k, "/v1/mock/account", { credit_cents: 25, history: [] });
  let path = where;
  if (where === "@session") path = `/s/${await r.session(k, ["Make a tiny pomodoro timer"])}`;
  if (where === "@out") path = "/";
  const p = await r.phone(path, Number(width), Number(width) > 370 ? 844 : 780, where === "@out" ? null : k);
  await pause(2500);
  for (const j of js) {
    if (j.startsWith("shot:")) { await shot(p, j.slice(5)); console.log("shot", j.slice(5)); continue; }
    if (j.startsWith("wait:")) { await pause(Number(j.slice(5))); continue; }
    console.log(JSON.stringify(await p.eval(j)));
  }
  await p.close();
} finally { await r.close(); }
