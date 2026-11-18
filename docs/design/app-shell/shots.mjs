// The shots capture.mjs takes: a path, localStorage, a size, and steps (JS run in the page, or a
// pause in ms). Signed-in shots seed a key the mock gateway takes as an account.
const SIGNED_IN = { "frog.key": "frog_capture" };
const click = (sel, text) => text
  ? `[...document.querySelectorAll(${JSON.stringify(sel)})].find((e) => e.textContent.trim().startsWith(${JSON.stringify(text)})).click()`
  : `document.querySelector(${JSON.stringify(sel)}).click()`;

export default [
  { name: "web-signed-out-home", path: "/" },
  { name: "web-signed-out-docs", path: "/docs/frog-cloud" },
  { name: "web-signed-out-signin", path: "/", steps: [click(".signin-row > button")] },
  { name: "web-signed-in-chip", path: "/", storage: SIGNED_IN },
  { name: "web-signed-out-drawer-375", path: "/", size: [375, 812], steps: [click(".burger")] },
];
