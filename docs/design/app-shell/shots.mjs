// The shots capture.mjs takes: a path, localStorage, a size, and steps (JS run in the page, or a
// pause in ms). Signed-in shots seed a key the mock gateway takes as an account.
const SIGNED_IN = { "frog.key": "frog_capture" };
const click = (sel, text) => text
  ? `[...document.querySelectorAll(${JSON.stringify(sel)})].find((e) => e.textContent.trim().startsWith(${JSON.stringify(text)})).click()`
  : `document.querySelector(${JSON.stringify(sel)}).click()`;

const typeInto = (sel, value) => `const i = document.querySelector(${JSON.stringify(sel)}); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(i, ${JSON.stringify(value)}); i.dispatchEvent(new Event("input", { bubbles: true }))`;
const redeem = (code) => [typeInto('[aria-label="Coupon code"]', code), click('.coupon button[type="submit"]'), 800, `document.querySelector(".coupon").scrollIntoView({ block: "center" })`];

export default [
  { name: "web-signed-out-home", path: "/" },
  { name: "web-signed-out-docs", path: "/docs/frog-cloud" },
  { name: "web-signed-out-signin", path: "/", steps: [click(".signin-row > button")] },
  { name: "web-signed-in-chip", path: "/", storage: SIGNED_IN },
  { name: "web-signed-out-drawer-375", path: "/", size: [375, 812], steps: [click(".burger")] },
  { name: "web-settings-account", path: "/settings/account", storage: SIGNED_IN },
  { name: "web-settings-general", path: "/settings/general", storage: SIGNED_IN },
  { name: "web-settings-appearance", path: "/settings/appearance", storage: SIGNED_IN },
  { name: "web-settings-permissions", path: "/settings/permissions", storage: SIGNED_IN },
  { name: "web-settings-connections", path: "/settings/connections", storage: SIGNED_IN },
  { name: "web-settings-shortcuts", path: "/settings/shortcuts", storage: SIGNED_IN },
  { name: "web-settings-usage", path: "/settings/usage", storage: SIGNED_IN },
  { name: "web-settings-models", path: "/settings/models", storage: SIGNED_IN },
  { name: "web-settings-machine", path: "/settings/models", storage: SIGNED_IN, steps: [click(".set-machine")] },
  { name: "web-settings-billing", path: "/settings/billing", storage: SIGNED_IN },
  { name: "web-settings-coupon-added", path: "/settings/billing", storage: SIGNED_IN, steps: redeem("LAUNCH5") },
  { name: "web-settings-coupon-error", path: "/settings/billing", storage: SIGNED_IN, steps: redeem("SPRING24") },
  { name: "web-settings-drawer-375", path: "/settings/billing", storage: SIGNED_IN, size: [375, 812], steps: [click(".burger")] },
];
