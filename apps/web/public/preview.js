// Frog's preview capture script, injected into every page of a web Preview pane by the Frog
// Cloud gateway (zest sandbox/src/preview.ts serves it at /__frog/preview.js on the preview's
// own origin). A port of the Mac app's WKWebView script (apps/macos/Frog/Views/PreviewPane.swift
// `PreviewHost.script`): it forwards console output, errors, failed requests and title changes,
// answers read/click/type/eval, and does inspect mode's highlight and mention on click. Keep
// the two in step. The pane's side is apps/web/src/preview.ts.
(() => {
  if (window.__frogPreview || window.parent === window) return;
  // To the Preview pane in frog web, this frame's parent. Messages carry `frog: 1` so the pane
  // can tell them from the page's own postMessages.
  const post = (m) => { try { window.parent.postMessage(Object.assign({ frog: 1 }, m), "*"); } catch (e) {} };
  const fmt = (a) => {
    if (typeof a === "string") return a;
    if (a instanceof Error) return a.stack || a.message;
    try { return JSON.stringify(a); } catch (e) { return String(a); }
  };
  const where = () => {
    try {
      const lines = (new Error().stack || "").split("\n").filter(l => !/__frog|console\.|<anonymous>$/.test(l));
      const m = lines[1] && lines[1].match(/(https?:\/\/[^\s)]+|file:[^\s)]+)/);
      if (!m) return "";
      return m[1].replace(location.origin, "");
    } catch (e) { return ""; }
  };
  // Console.
  for (const level of ["log", "info", "warn", "error", "debug"]) {
    const orig = console[level];
    console[level] = function (...args) {
      post({ type: "console", level: level === "warn" ? "warn" : level === "error" ? "error" : "info", message: args.map(fmt).join(" "), source: where() });
      return orig.apply(this, args);
    };
  }
  // Errors.
  window.addEventListener("error", (e) => {
    const src = e.filename ? `${(e.filename || "").replace(location.origin, "")}:${e.lineno}:${e.colno}` : "";
    post({ type: "error", message: (e.message || String(e.error)) + (src ? `  (${src})` : ""), url: location.href });
  });
  window.addEventListener("unhandledrejection", (e) => {
    post({ type: "error", message: "Unhandled promise rejection: " + fmt(e.reason), url: location.href });
  });
  // Failed requests.
  const ofetch = window.fetch;
  if (ofetch) {
    window.fetch = function (input, init) {
      const url = typeof input === "string" ? input : (input && input.url) || String(input);
      return ofetch.apply(this, arguments).then((r) => {
        if (r.status >= 400) post({ type: "network", message: `${(init && init.method) || "GET"} ${url} → ${r.status}`, url, status: r.status });
        return r;
      }, (err) => {
        post({ type: "network", message: `${(init && init.method) || "GET"} ${url} failed: ${err && err.message}`, url, status: null });
        throw err;
      });
    };
  }
  const oopen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__frogURL = String(url); this.__frogMethod = method;
    this.addEventListener("loadend", () => {
      if (this.status >= 400 || this.status === 0) {
        post({ type: "network", message: `${method} ${url} → ${this.status || "network error"}`, url: String(url), status: this.status || null });
      }
    });
    return oopen.apply(this, arguments);
  };
  // Title.
  let lastTitle = "";
  const watchTitle = () => {
    const t = document.querySelector("title");
    const tell = () => { if (document.title !== lastTitle) { lastTitle = document.title; post({ type: "title", message: document.title }); } };
    tell();
    if (t) new MutationObserver(tell).observe(t, { childList: true, characterData: true, subtree: true });
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", watchTitle); else watchTitle();

  // Selectors and names.
  const esc = (s) => (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^\w-]/g, "\\$&");
  const unique = (sel) => { try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; } };
  const selector = (el) => {
    if (el.id && unique("#" + esc(el.id))) return "#" + esc(el.id);
    const tag = el.tagName.toLowerCase();
    for (const attr of ["name", "data-testid", "aria-label"]) {
      const v = el.getAttribute(attr);
      if (v) { const s = `${tag}[${attr}="${v.replace(/"/g, '\\"')}"]`; if (unique(s)) return s; }
    }
    const parts = [];
    let node = el;
    while (node && node.nodeType === 1 && node !== document.body && parts.length < 5) {
      let part = node.tagName.toLowerCase();
      if (node.id) { parts.unshift("#" + esc(node.id)); break; }
      const sibs = Array.from(node.parentNode ? node.parentNode.children : []).filter(c => c.tagName === node.tagName);
      if (sibs.length > 1) part += `:nth-of-type(${sibs.indexOf(node) + 1})`;
      parts.unshift(part);
      node = node.parentNode;
    }
    return parts.join(" > ");
  };
  const text = (el) => (el.innerText || el.textContent || "").replace(/\s+/g, " ").trim();
  const label = (el) => {
    if (el.labels && el.labels.length) return text(el.labels[0]);
    return el.getAttribute("aria-label") || el.getAttribute("placeholder") || el.getAttribute("title") || "";
  };
  const role = (el) => {
    const r = el.getAttribute("role"); if (r) return r;
    const tag = el.tagName.toLowerCase();
    return ({ a: "link", button: "button", input: el.type === "submit" || el.type === "button" ? "button" : "input", select: "select", textarea: "input",
              h1: "heading", h2: "heading", h3: "heading", h4: "heading", nav: "nav", main: "main", header: "header", footer: "footer", form: "form", img: "image" })[tag] || tag;
  };
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (!r.width && !r.height) return false;
    const s = getComputedStyle(el);
    return s.visibility !== "hidden" && s.display !== "none";
  };
  const source = (el) => {
    const ds = el.getAttribute("data-source") || el.getAttribute("data-inspector-relative-path");
    if (ds) return ds;
    for (const k of Object.keys(el)) {
      if (k.startsWith("__reactFiber$")) {
        let f = el[k];
        while (f) { if (f._debugSource) return `${f._debugSource.fileName}:${f._debugSource.lineNumber}`; f = f.return; }
      }
    }
    const vc = el.__vueParentComponent;
    if (vc && vc.type && vc.type.__file) return vc.type.__file;
    return "";
  };

  // Read: an outline the model can act on.
  const read = () => {
    const out = [`Title: ${document.title}`, `URL: ${location.href}`, ""];
    const seen = new Set();
    const walk = (node, depth) => {
      if (out.join("\n").length > 4000) return;
      for (const el of node.children) {
        if (!visible(el) || seen.has(el)) continue;
        const tag = el.tagName.toLowerCase();
        const r = role(el);
        const pad = "  ".repeat(Math.min(depth, 6));
        const t = text(el).slice(0, 120);
        if (["script", "style", "noscript", "svg", "path"].includes(tag)) continue;
        if (["nav", "main", "header", "footer", "form", "aside", "section", "article", "dialog"].includes(tag) || el.getAttribute("role")) {
          out.push(`${pad}[${r}]${el.id ? " #" + el.id : ""}${label(el) ? " " + JSON.stringify(label(el)) : ""}`);
          seen.add(el); walk(el, depth + 1); continue;
        }
        if (/^h[1-6]$/.test(tag)) { out.push(`${pad}${tag}: ${t}  {${selector(el)}}`); seen.add(el); continue; }
        if (tag === "a") { out.push(`${pad}link "${t}" → ${el.getAttribute("href") || ""}  {${selector(el)}}`); seen.add(el); continue; }
        if (tag === "button" || (tag === "input" && ["submit", "button"].includes(el.type))) {
          out.push(`${pad}button "${t || el.value || label(el)}"${el.disabled ? " (disabled)" : ""}  {${selector(el)}}`); seen.add(el); continue;
        }
        if (tag === "input" || tag === "textarea" || tag === "select") {
          const v = tag === "select" ? (el.selectedOptions[0] ? el.selectedOptions[0].text : "") : el.type === "password" ? "•••" : el.value;
          out.push(`${pad}${tag === "select" ? "select" : "input"}${el.type ? "[" + el.type + "]" : ""} "${label(el) || el.name || ""}" = ${JSON.stringify(v || "")}  {${selector(el)}}`);
          seen.add(el); continue;
        }
        if (tag === "img") { out.push(`${pad}image "${el.alt || ""}"`); continue; }
        if (el.children.length === 0 || ["p", "li", "td", "th", "label", "span", "pre", "code", "blockquote"].includes(tag)) {
          if (t) out.push(`${pad}${t}`);
          continue;
        }
        walk(el, depth);
      }
    };
    walk(document.body, 0);
    let s = out.join("\n");
    if (s.length > 4000) s = s.slice(0, 4000) + "\n…";
    return s;
  };
  const find = (sel) => {
    const el = document.querySelector(sel);
    if (!el) throw new Error(`no element matches ${sel}`);
    return el;
  };
  const click = (sel) => {
    const el = find(sel);
    el.scrollIntoView({ block: "center" });
    el.focus && el.focus();
    el.click();
    return { ok: true, selector: sel, text: text(el).slice(0, 80) };
  };
  const type = (sel, value) => {
    const el = find(sel);
    el.focus && el.focus();
    const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, "value");
    if (setter && setter.set && ("value" in el)) setter.set.call(el, value); else if (el.isContentEditable) el.textContent = value; else el.value = value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return { ok: true, selector: sel, value };
  };

  // Inspect mode: highlight under the pointer, mention on click.
  let overlay = null, hovered = null, on = false;
  const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").split("-").slice(0, 2).join("-");
  const token = (el) => {
    const tag = el.tagName.toLowerCase();
    if (el.id) return "@#" + el.id;
    const name = el.getAttribute("name") || el.getAttribute("data-testid");
    if (name) return `@${tag}.${slug(name)}`;
    if (/^h[1-6]$/.test(tag)) return "@" + tag;
    const t = slug(text(el) || label(el) || el.getAttribute("aria-label") || "");
    const base = t ? `@${role(el)}.${t}` : `@${tag}`;
    const same = Array.from(document.querySelectorAll(tag)).filter(e => slug(text(e) || label(e) || "") === t);
    return same.length > 1 ? `${base}-${same.indexOf(el) + 1}` : base;
  };
  const move = (e) => {
    const el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === overlay || el === hovered) return;
    hovered = el;
    const r = el.getBoundingClientRect();
    overlay.style.left = (r.left + window.scrollX) + "px"; overlay.style.top = (r.top + window.scrollY) + "px";
    overlay.style.width = r.width + "px"; overlay.style.height = r.height + "px";
    overlay.firstChild.textContent = token(el);
  };
  const pick = (e) => {
    e.preventDefault(); e.stopPropagation();
    const el = document.elementFromPoint(e.clientX, e.clientY);
    if (!el || el === overlay) return;
    const r = el.getBoundingClientRect();
    const src = source(el);
    const ctx = [
      `tag: ${el.tagName.toLowerCase()}`, `role: ${role(el)}`,
      text(el) ? `text: ${JSON.stringify(text(el).slice(0, 160))}` : null,
      label(el) ? `label: ${JSON.stringify(label(el))}` : null,
      `selector: ${selector(el)}`,
      `box: ${Math.round(r.left)},${Math.round(r.top)} ${Math.round(r.width)}×${Math.round(r.height)}`,
      src ? `source: ${src}` : null,
      `page: ${location.href}`,
    ].filter(Boolean).join("\n");
    post({ type: "mention", token: token(el), context: ctx });
    inspect(false);
  };
  // Esc stops inspecting (the Mac's onExitCommand; here the key lands in the frame).
  const stop = (e) => { if (e.key === "Escape") { e.preventDefault(); inspect(false); post({ type: "inspect", on: false }); } };
  const inspect = (enable) => {
    if (enable === on) return;
    on = enable;
    if (enable) {
      overlay = document.createElement("div");
      overlay.style.cssText = "position:absolute;pointer-events:none;z-index:2147483647;border:2px solid #34c759;background:rgba(52,199,89,0.15);border-radius:3px;box-sizing:border-box;";
      const tip = document.createElement("span");
      tip.style.cssText = "position:absolute;left:0;top:-20px;background:#34c759;color:#fff;font:11px -apple-system,system-ui,sans-serif;padding:1px 6px;border-radius:3px;white-space:nowrap;";
      overlay.appendChild(tip);
      document.documentElement.appendChild(overlay);
      document.addEventListener("mousemove", move, true);
      document.addEventListener("click", pick, true);
      document.addEventListener("keydown", stop, true);
      document.documentElement.style.cursor = "crosshair";
    } else {
      document.removeEventListener("mousemove", move, true);
      document.removeEventListener("click", pick, true);
      document.removeEventListener("keydown", stop, true);
      if (overlay) overlay.remove();
      overlay = null; hovered = null;
      document.documentElement.style.cursor = "";
    }
  };
  window.__frogPreview = { read, click, type, inspect };

  // What the Mac's navigation delegate sees, said from inside the page: it committed at this
  // URL, or (a gateway page with frog-preview-error) it couldn't load.
  const committed = () => {
    const failed = document.querySelector('meta[name="frog-preview-error"]');
    if (failed) post({ type: "load_failed", message: failed.getAttribute("content") || "the page didn't load" });
    else post({ type: "navigated", url: location.href });
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", committed); else committed();

  // The pane's requests (the Mac's evaluateJavaScript), only from the parent frame.
  window.addEventListener("message", async (e) => {
    const m = e.data;
    if (e.source !== window.parent || !m || m.frog !== 1) return;
    if (m.type === "inspect") return inspect(!!m.on);
    if (m.type === "back") return history.back();
    if (m.type === "reload") return location.reload();
    if (m.type !== "call") return;
    try {
      let result;
      if (m.fn === "read") result = read();
      else if (m.fn === "click") result = click(m.selector);
      else if (m.fn === "type") result = type(m.selector, m.text || "");
      else if (m.fn === "eval") result = await (0, eval)(m.js);
      else throw new Error("unknown call " + m.fn);
      try { result = result === undefined ? null : JSON.parse(JSON.stringify(result)); } catch (err) { result = String(result); }
      post({ type: "reply", n: m.n, result });
    } catch (err) {
      post({ type: "reply", n: m.n, error: (err && err.message) || String(err) });
    }
  });
})();
