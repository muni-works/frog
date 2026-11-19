// Where the web app can point at the Mac app: the download chip's two gates, as plain predicates
// so they're testable without a browser and a test can prove each one is load-bearing.

/** A finger, not a mouse. iOS and Android browsers report their primary pointer as coarse. */
export const COARSE_POINTER = '(pointer: coarse)'

/** A `matchMedia` query, injected in tests. */
export type Matches = (query: string) => boolean

const media: Matches = (q) => {
  try {
    return typeof matchMedia === 'function' && matchMedia(q).matches
  } catch {
    return false
  }
}

/** Gate 1: a phone or tablet. The web app can't pair a machine or run a local model there, and
 *  iOS won't run a .dmg at all. Not `drawer` (App.tsx): that's the sidebar, which also opens on a
 *  narrow desktop window and is closed on a phone until the burger is tapped. */
export function isPhone(matches: Matches = media): boolean {
  return matches(COARSE_POINTER)
}

/** Gate 2: they already have the app. A paired local machine — `Machine.thisMac` on any row —
 *  is the Mac app's own node, so the heaviest users aren't the ones shown the prompt most. */
export const hasThisMac = (machines: readonly { thisMac?: boolean }[] = []): boolean =>
  machines.some((m) => m.thisMac === true)

/** Whether the download chip shows at all: off a phone, and only when the Mac app is missing. */
export function showsDownloadChip({ thisMac, phone }: { thisMac: boolean; phone: boolean }): boolean {
  return !phone && !thisMac
}

/** The same decision for a site that also has to hide something else when the chip is there. */
export function downloadChipShown(machines: readonly { thisMac?: boolean }[] = [], phone: boolean = isPhone()): boolean {
  return showsDownloadChip({ thisMac: hasThisMac(machines), phone })
}

/** A Mac with a mouse: what a Mac-only setting's invitation needs before it offers the app. An
 *  iPad says "Macintosh" too, so a coarse pointer rules it out. */
export function isMacVisitor(matches: Matches = media, ua: string = typeof navigator === 'object' ? navigator.userAgent : ''): boolean {
  return !isPhone(matches) && /Macintosh|Mac OS X/.test(ua)
}

/** What an invitation row (a setting that works in the Mac app) offers where its control would
 *  be: the download, the app they already have, or nothing off a Mac. */
export type Invite = 'get' | 'open' | 'elsewhere'
export function inviteFor({ mac, thisMac }: { mac: boolean; thisMac: boolean }): Invite {
  if (!mac) return 'elsewhere'
  return thisMac ? 'open' : 'get'
}

/** Where picking a local model in the web's model menu goes, by the same invitation: Frog for
 *  Mac's Models page when the account has the app (the Mac handles only `frog://settings/<section>`
 *  and `frog://customize/<section>` today, so the model and the typed message can't ride along),
 *  the download on a Mac without it, and the Mac app's page anywhere else. */
export function macHandoff(invite: Invite): { href: string; does: string; title: string } {
  if (invite === 'open') return { href: 'frog://settings/models', does: 'opens Frog for Mac', title: 'Opens in Frog for Mac' }
  if (invite === 'get') return { href: '/download', does: 'get Frog for Mac', title: 'Runs in Frog for Mac. Download it free' }
  return { href: '/mac', does: 'learn about Frog for Mac', title: 'Runs on a Mac, in Frog for Mac' }
}
