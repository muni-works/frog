// Stroke icon paths (24×24, round caps) shared by the transcript's activity lines and the
// inspector. The Mac draws the same shapes from SF Symbols: doc.text, doc.badge.plus, terminal,
// globe, plusminus.

export const ICON = {
  doc: 'M6 3h8l4 4v14H6zM14 3v4h4',
  docPlus: 'M6 3h8l4 4v14H6zM14 3v4h4M12 11v6M9 14h6',
  terminal: 'M4 6l5 5-5 5M11 17h8',
  /** A terminal window: a rounded box with a prompt in it (the inspector's Terminal tab). */
  terminalBox: 'M6 4h12a3 3 0 0 1 3 3v10a3 3 0 0 1-3 3H6a3 3 0 0 1-3-3V7a3 3 0 0 1 3-3zM7 9l3 3-3 3M12 15h5',
  globe: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18',
  plusMinus: 'M12 3v8M8 7h8M8 18h8',
  /** An open book (the sidebar's Documentation row; the Mac's book). */
  book: 'M12 6.5C10.5 5 8.2 4.5 4 4.5v13c4.2 0 6.5.5 8 2 1.5-1.5 3.8-2 8-2v-13c-4.2 0-6.5.5-8 2zM12 6.5v13',
  /** Search (the Mac's magnifyingglass; the thread sidebar's Search row). */
  search: 'M11 4a7 7 0 1 0 0 14a7 7 0 1 0 0-14M20 20l-4-4',
  /** Back to app (the Mac's arrow.left). */
  arrowLeft: 'M19 12H5M11 6l-6 6 6 6',
} as const

/** One of those paths as an inline icon in the current text colour. */
export function Icon({ d, size = 14, stroke = 1.8, className }: { d: string; size?: number; stroke?: number; className?: string }) {
  return (
    <svg aria-hidden="true" className={className} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round"><path d={d} /></svg>
  )
}
