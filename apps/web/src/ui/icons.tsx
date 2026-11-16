// Stroke icon paths (24×24, round caps) shared by the transcript's activity lines and the
// inspector. The Mac draws the same shapes from SF Symbols: doc.text, doc.badge.plus, terminal,
// globe, plusminus.

export const ICON = {
  doc: 'M6 3h8l4 4v14H6zM14 3v4h4',
  docPlus: 'M6 3h8l4 4v14H6zM14 3v4h4M12 11v6M9 14h6',
  terminal: 'M4 6l5 5-5 5M11 17h8',
  globe: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c3 3.5 3 14.5 0 18M12 3c-3 3.5-3 14.5 0 18',
  plusMinus: 'M12 3v8M8 7h8M8 18h8',
} as const

/** One of those paths as an inline icon in the current text colour. */
export function Icon({ d, size = 14, stroke = 1.8, className }: { d: string; size?: number; stroke?: number; className?: string }) {
  return (
    <svg aria-hidden="true" className={className} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round"><path d={d} /></svg>
  )
}
