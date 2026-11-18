import { useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { docsPath, neighbors, search, type Page } from '../docs/docs'
import { ICON, Icon } from './icons'
import { Markdown } from './Markdown'

// Documentation mode (docs/design/app-shell.md): the same window, with the left sidebar listing
// pages and the main area showing one. The thread you were in stays mounted underneath, hidden,
// so going back finds its transcript, draft, running turn and right sidebar tab as they were.

/** Threads, Documentation, or Settings (./Settings.tsx): what the sidebar lists and the main area shows. */
export type ShellMode = 'threads' | 'docs' | 'settings'

/** Shown or hidden, never unmounted: React keeps the subtree's state while it's hidden. */
export function Keep({ on, children }: { on: boolean; children: ReactNode }) {
  return <div className="shell-keep" style={{ display: on ? 'contents' : 'none' }}>{children}</div>
}

interface ShellProps {
  mode: ShellMode
  className: string
  /** Before the sidebar (the phone drawer's scrim). */
  before?: ReactNode
  /** The sidebar's first row, the same in every mode. */
  brand: ReactNode
  side: { threads: ReactNode; docs: ReactNode; settings?: ReactNode }
  main: { threads: ReactNode; docs: ReactNode; settings?: ReactNode }
  /** The right sidebar: it belongs to a thread, so it's hidden outside Threads mode. */
  inspector?: ReactNode
  /** Palette, overlays, toasts: over every mode. */
  after?: ReactNode
}

/** The window's shell. Threads mode's sidebar, main area and right sidebar are always mounted;
 *  Documentation and Settings modes add their own and hide them. */
export function Shell({ mode, className, before, brand, side, main, inspector, after }: ShellProps) {
  const threads = mode === 'threads'
  return (
    <div className={className}>
      {before}
      <aside className="side">
        {brand}
        <Keep on={threads}>{side.threads}</Keep>
        {mode === 'docs' && side.docs}
        {mode === 'settings' && side.settings}
      </aside>
      <Keep on={threads}>{main.threads}</Keep>
      {mode === 'docs' && main.docs}
      {mode === 'settings' && main.settings}
      <Keep on={threads}>{inspector}</Keep>
      {after}
    </div>
  )
}

/** The Documentation row at the bottom of Threads mode's sidebar. */
export function DocsRow({ onOpen }: { onOpen: () => void }) {
  return (
    <button type="button" className="row big docs-row" onClick={onOpen}>
      <Icon d={ICON.book} size={17} />
      <span style={{ flex: 1 }}>Documentation</span>
    </button>
  )
}

/** A same-window link to a docs page: a real href (so it opens in a new tab too), routed in place on a plain click. */
function PageLink({ page, onOpen, className, children }: { page: Page; onOpen: (slug: string) => void; className?: string; children: ReactNode }) {
  return (
    <a className={className} href={docsPath(page.slug)} onClick={(e) => {
      if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0) return
      e.preventDefault()
      onOpen(page.slug)
    }}>{children}</a>
  )
}

interface SidebarProps {
  pages: readonly Page[]
  current: string
  version: string
  onBack: () => void
  onOpen: (slug: string) => void
}

/** Back to app, Search docs, then the pages under their sections, and the version at the bottom. */
export function DocsSidebar({ pages, current, version, onBack, onOpen }: SidebarProps) {
  const [q, setQ] = useState('')
  // Search docs is a row, like the thread sidebar's Search, until it's clicked; then it's a field.
  const [searching, setSearching] = useState(false)
  const found = useMemo(() => search(pages, q), [pages, q])
  const sections = useMemo(() => {
    const out: { title: string; pages: Page[] }[] = []
    for (const p of found) {
      const last = out[out.length - 1]
      if (last && last.title === p.section) last.pages.push(p)
      else out.push({ title: p.section, pages: [p] })
    }
    return out
  }, [found])
  return (
    <div className="docs-side">
      <nav aria-label="Documentation" className="nav">
        <button type="button" className="row big" onClick={onBack}><Icon d={ICON.arrowLeft} size={17} /><span style={{ flex: 1 }}>Back to app</span><span className="kb">esc</span></button>
        {searching || q ? (
          <div className="row big docs-search">
            <Icon d={ICON.search} size={17} />
            <input autoFocus value={q} placeholder="Search docs" aria-label="Search docs"
              onChange={(e) => setQ(e.target.value)}
              onBlur={() => setSearching(false)}
              onKeyDown={(e) => { if (e.key === 'Enter' && found[0]) onOpen(found[0].slug) }} />
            {q && <button type="button" className="ic-btn docs-clear" aria-label="Clear the search" onMouseDown={(e) => e.preventDefault()} onClick={() => setQ('')}>
              <svg aria-hidden="true" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round"><path d="M6 6l12 12M18 6L6 18" /></svg>
            </button>}
          </div>
        ) : (
          <button type="button" className="row big" onClick={() => setSearching(true)}><Icon d={ICON.search} size={17} /><span style={{ flex: 1 }}>Search docs</span></button>
        )}
      </nav>
      <div className="docs-list">
        {sections.length === 0 && <div className="det wrap" style={{ padding: '10px 8px' }}>No page matches.</div>}
        {sections.map((s) => (
          <div key={s.title}>
            <div className="docs-h">{s.title}</div>
            {s.pages.map((p) => (
              <PageLink key={p.slug} page={p} onOpen={onOpen} className={`srow${p.slug === current ? ' on' : ''}`}>
                <span className="stitle" aria-current={p.slug === current ? 'page' : undefined}>{p.title}</span>
              </PageLink>
            ))}
          </div>
        ))}
      </div>
      <div className="det docs-ver">Frog {version}</div>
    </div>
  )
}

interface PageProps {
  pages: readonly Page[]
  slug: string
  /** The bar above the page: the phone's menu button, the sidebar toggle when it's folded. */
  bar?: ReactNode
  onOpen: (slug: string) => void
}

/** One page: its section, its title, the page, then the previous and next pages. */
export function DocsPage({ pages, slug, bar, onOpen }: PageProps) {
  const page = pages.find((p) => p.slug === slug)
  const { prev, next } = neighbors(pages, slug)
  const scroller = useRef<HTMLDivElement>(null)
  // A new page starts at its top.
  useEffect(() => { scroller.current?.scrollTo?.(0, 0) }, [slug])
  return (
    <main className="main docs-main">
      <div className="titlebar">{bar}</div>
      <div className="scroll" ref={scroller}>
        <article className="col docs-page" aria-label={page?.title ?? 'Page not found'}>
          {page ? (<>
            <div className="docs-sec">{page.section}</div>
            <h1 className="docs-title">{page.title}</h1>
            <Markdown text={page.body} />
            <nav className="docs-pager" aria-label="More pages">
              {prev ? <PageLink page={prev} onOpen={onOpen} className="docs-step"><span className="det">Previous</span><span>{prev.title}</span></PageLink> : <span />}
              {next ? <PageLink page={next} onOpen={onOpen} className="docs-step next"><span className="det">Next</span><span>{next.title}</span></PageLink> : <span />}
            </nav>
          </>) : (<>
            <h1 className="docs-title">Page not found</h1>
            <div className="det wrap">There's no page at this address in this version of Frog.</div>
            {pages[0] && <div><PageLink page={pages[0]} onOpen={onOpen}>{pages[0].title}</PageLink></div>}
          </>)}
        </article>
      </div>
    </main>
  )
}
