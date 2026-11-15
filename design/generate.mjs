#!/usr/bin/env node
// Writes the web's and the Mac's tokens from design/tokens.json, the one design source.
//
//   node design/generate.mjs           write apps/web/src/tokens.css and apps/FrogKit/UI/Basics/Tokens.swift
//   node design/generate.mjs --check   exit 1 if either file has drifted from the JSON
//
// No dependencies. apps/web/test/tokens.test.ts runs the check; FrogTests/TokensTests.swift
// checks the compiled Swift values against the JSON.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
export const paths = {
  json: join(ROOT, "design/tokens.json"),
  css: join(ROOT, "apps/web/src/tokens.css"),
  swift: join(ROOT, "apps/FrogKit/UI/Basics/Tokens.swift"),
};

/** "#rrggbb" or "rgba(r, g, b, a)" → [r, g, b, a], channels 0...255, alpha 0...1. */
export function parseColor(s) {
  const hex = /^#([0-9a-f]{6})$/i.exec(s);
  if (hex) return [0, 2, 4].map((i) => parseInt(hex[1].slice(i, i + 2), 16)).concat(1);
  const rgba = /^rgba\(\s*(\d+),\s*(\d+),\s*(\d+),\s*([\d.]+)\s*\)$/.exec(s);
  if (rgba) return rgba.slice(1).map(Number);
  throw new Error(`unreadable color ${s}`);
}

const HEADER = "generated from design/tokens.json by design/generate.mjs; edit the JSON, not this file";
const num = (n) => (Number.isInteger(n) ? `${n}` : `${n}`);

export function renderCss(t) {
  const colors = (mode) => [...t.color, ...t.shadow].filter((c) => c.css).map((c) => `  --${c.css}: ${c[mode]};`).join("\n");
  const fixed = [
    ...t.size.filter((s) => s.css).map((s) => `  --${s.css}: ${num(s.value)}px;`),
    ...t.radius.filter((r) => r.css).map((r) => `  --${r.css}: ${num(r.value)}px;`),
    ...t.space.filter((s) => s.css).map((s) => `  --${s.css}: ${num(s.value)}px;`),
    ...t.font.map((f) => `  --${f.css}: ${f.value};`),
  ].join("\n");
  const type = t.type
    .map((y) => `.${y.class} { font-family: var(--font-${y.font}); font-size: ${y.size}; line-height: ${y.line}; font-weight: ${y.weight};${y.tracking ? ` letter-spacing: ${y.tracking};` : ""} }`)
    .join("\n");
  return `/* frog — ${HEADER}. */
:root, [data-theme="light"] {
${colors("light")}
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
${colors("dark")}
} }
:root[data-theme="dark"] {
${colors("dark")}
}
:root {
${fixed}
}
${type}
`;
}

const comp = (v) => {
  const s = (Math.round((v / 255) * 1000) / 1000).toString();
  return s.includes(".") ? s : `${s}.0`;
};
const swiftColor = (c) => {
  const tuple = (s) => {
    const [r, g, b, a] = parseColor(s);
    return `(${comp(r)}, ${comp(g)}, ${comp(b)}, ${a})`;
  };
  return `Color(light: ${tuple(c.light)}, dark: ${tuple(c.dark)})`;
};
const docs = (d, pad) => (d ? `${pad}/// ${d}\n` : "");
const cg = (n) => (Number.isInteger(n) ? `${n}` : `${n}`);

export function renderSwift(t) {
  const colors = t.color.filter((c) => c.swift).map((c) => `${docs(c.doc, "    ")}    static let ${c.swift} = ${swiftColor(c)}`).join("\n");
  const group = (list) => list.filter((x) => x.swift).map((x) => `${docs(x.doc, "        ")}        static let ${x.swift}: CGFloat = ${cg(x.value)}`).join("\n");
  return `// ${HEADER}.
import SwiftUI
import CoreText

/// The shell's design tokens, so views read one palette, one type ramp and one set of radii
/// instead of picking their own. The web app's tokens.css comes from the same JSON
/// (docs/design/frog-web/README.md, "One look"): dark is true black and surfaces step up from it
/// (#0a0a0a sidebar, #121212 raised, #1a1a1a wells); light is true white and they step down
/// (#fafafa, #f4f4f4, #ececec). No lines: things separate by fill. The Watch is always dark.
///
/// Rules that come with them: state color lives on glyphs only (a dot, a check, a hairline),
/// never on fills; numbers are tabular; the composer field is the only thing with a shadow.
enum Tokens {
${colors}

    /// Type ramp: five steps, no half-steps between them.
    enum Size {
${group(t.size)}
    }

    enum Radius {
${group(t.radius)}
    }

    enum Space {
${group(t.space)}
    }

    /// The one status pulse: a slow breathe for live dots (Motion.swift keeps the springs).
    static let pulse = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)
}

extension Color {
    /// A translucent color that follows the appearance (components 0...1, alpha last).
    init(light: (Double, Double, Double, Double), dark: (Double, Double, Double, Double)) {
        #if os(watchOS)
        self.init(red: dark.0, green: dark.1, blue: dark.2, opacity: dark.3)
        #elseif os(macOS)
        self.init(nsColor: NSColor(name: nil) { a in
            let c = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
        #else
        self.init(uiColor: UIColor { t in
            let c = t.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: c.3)
        })
        #endif
    }
}

// MARK: - Type

/// IBM Plex, like the web app: Sans for words, Mono for code. Rounded stays SF, since
/// Plex has no rounded cut. Fonts ship in FrogKit/UI/Fonts and register on first use.
public extension Font {
    static func frog(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        guard design != .rounded, PlexFonts.registered else { return .system(size: size, weight: weight, design: design) }
        return .custom(design == .monospaced ? "IBM Plex Mono" : "IBM Plex Sans", fixedSize: size).weight(weight)
    }
}

enum PlexFonts {
    static let registered: Bool = {
        let urls = ["IBMPlexSans", "IBMPlexMono-Regular", "IBMPlexMono-Medium"]
            .compactMap { Bundle.main.url(forResource: $0, withExtension: "ttf") }
        urls.forEach { CTFontManagerRegisterFontsForURL($0 as CFURL, .process, nil) }
        return !urls.isEmpty
    }()
}
`;
}

export const load = () => JSON.parse(readFileSync(paths.json, "utf8"));
export const render = (t = load()) => ({ css: renderCss(t), swift: renderSwift(t) });

/** Files that differ from what the JSON generates. */
export function drift(t = load()) {
  const out = render(t);
  return ["css", "swift"].filter((k) => readFileSync(paths[k], "utf8") !== out[k]).map((k) => paths[k]);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv.includes("--check")) {
    const d = drift();
    if (d.length) {
      console.error(`drifted from design/tokens.json (run node design/generate.mjs):\n  ${d.join("\n  ")}`);
      process.exit(1);
    }
    console.log("tokens: in sync");
  } else {
    const out = render();
    writeFileSync(paths.css, out.css);
    writeFileSync(paths.swift, out.swift);
    console.log(`wrote ${paths.css}\nwrote ${paths.swift}`);
  }
}
