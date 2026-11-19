import { Fragment, useEffect, useRef, type ReactNode } from 'react'
import { CLOUD_READS, CUSTOMIZE_INVITES, CUSTOMIZE_SECTIONS, customizeLabel, customizePath, docsSlugFor, EXPLAINERS, weekDays, type CustomizeAt, type CustomizeSection } from '../customize'
import type { RepoList } from '../cloud/protocol'
import { InvitePill } from './DownloadChip'
import { ICON, Icon } from './icons'

// Customize mode (docs/design/app-shell.md): the shell's sidebar becomes Back to app and the five
// sections; the main area is one page with breadcrumbs in the header, built like Settings. Each
// list page opens with an explainer card. On the web, what a Frog Cloud session really reads from
// a repo is said plainly; what lives on a Mac is an invitation under "On your Mac". The designs for
// each list (weight card, activity marks, tool squares, sheets, rail, week grid) draw only from an
// engine report (docs/customize-api.md): with none, no figure is shown.

/** Back to app, then one row per section. */
export function CustomizeSidebar({ current, onBack, onOpen }: { current: CustomizeSection; onBack: () => void; onOpen: (s: CustomizeSection) => void }) {
  return (
    <div className="docs-side settings-side customize-side">
      <nav aria-label="Customize" className="nav">
        <button type="button" className="row big" onClick={onBack}><Icon d={ICON.arrowLeft} size={17} /><span style={{ flex: 1 }}>Back to app</span><span className="kb">esc</span></button>
      </nav>
      <div className="docs-list">
        {CUSTOMIZE_SECTIONS.map((s) => (
          <a key={s.id} href={customizePath({ section: s.id })} className={`srow${s.id === current ? ' on' : ''}`} aria-current={s.id === current ? 'page' : undefined}
            onClick={(e) => { if (plain(e)) { e.preventDefault(); onOpen(s.id) } }}>
            <span className="stitle">{s.label}</span>
          </a>
        ))}
      </div>
    </div>
  )
}

/** The Customize row for the app sidebar's foot (the sidebar's owner places it, beside Settings). */
export function CustomizeRow({ onOpen }: { onOpen: () => void }) {
  return (
    <button type="button" className="row big customize-row" onClick={onOpen}>
      <Icon d={ICON.wand} size={17} />
      <span style={{ flex: 1 }}>Customize</span>
    </button>
  )
}

/** A plain left click, which routes in place; anything else is the browser's (a new tab). */
const plain = (e: React.MouseEvent) => !(e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0)

export interface CustomizeProps {
  at: CustomizeAt
  /** The repos Frog Cloud can open (GET /v1/repos). */
  repos?: RepoList
  /** Your machines, so a paired Mac turns the invitation into "Open in Frog for Mac". */
  machines?: readonly { thisMac?: boolean }[]
  /** Documentation's page slugs, for each explainer's link. */
  docSlugs: readonly string[]
  onOpen: (at: CustomizeAt) => void
  onDocs: (slug: string) => void
  /** The bar above the page: the phone's menu button, the sidebar toggle when it's folded. */
  bar?: ReactNode
}

/** One page. */
export function CustomizePage(p: CustomizeProps) {
  const scroller = useRef<HTMLDivElement>(null)
  const key = customizePath(p.at)
  useEffect(() => { scroller.current?.scrollTo?.(0, 0) }, [key])
  return (
    <main className="main docs-main settings-main customize-main">
      <div className="titlebar">{p.bar}<Crumbs at={p.at} onOpen={p.onOpen} /><HeaderRight {...p} /></div>
      <div className="scroll" ref={scroller}>
        <div className="col settings-page customize-page" aria-label={pageLabel(p.at)} data-page={key}>
          <Body {...p} />
        </div>
      </div>
    </main>
  )
}

const pageLabel = (at: CustomizeAt) => at.page === 'skill' ? at.name : at.page === 'add' ? 'Add' : at.page === 'review' ? at.id : customizeLabel(at.section)

/** "Customize › Skills › /release-notes": parents are links, the page itself is bold. */
export function Crumbs({ at, onOpen }: { at: CustomizeAt; onOpen: (at: CustomizeAt) => void }) {
  const trail: { label: string; to?: CustomizeAt; mono?: boolean }[] = [{ label: customizeLabel(at.section), to: { section: at.section } }]
  if (at.page === 'skill') trail.push({ label: `/${at.name}`, mono: true })
  if (at.page === 'add' || at.page === 'review') trail.push({ label: 'Add', to: { section: at.section, page: 'add' } as CustomizeAt })
  if (at.page === 'review') trail.push({ label: at.id })
  return (
    <nav className="crumbs" aria-label="Breadcrumb">
      <span>Customize</span>
      {trail.map((c, i) => {
        const last = i === trail.length - 1
        return (
          <Fragment key={i}>
            <span className="crumb-sep" aria-hidden="true">›</span>
            {last
              ? <b aria-current="page" className={c.mono ? 'mono' : undefined}>{c.label}</b>
              : <button type="button" onClick={() => c.to && onOpen(c.to)} title={`Back to ${c.label}`}>{c.label}</button>}
          </Fragment>
        )
      })}
    </nav>
  )
}

/** The header's right side: the section's Add button. */
function HeaderRight({ at, onOpen }: CustomizeProps) {
  if (at.page) return null
  const add = at.section === 'skills' ? 'Add a skill' : at.section === 'connections' ? 'Add a connection' : null
  if (!add) return null
  return (
    <div className="cust-hdr-rt">
      <button type="button" className="cust-pill" onClick={() => onOpen({ section: at.section as 'skills' | 'connections', page: 'add' })}>{add}</button>
    </div>
  )
}

function Body(p: CustomizeProps) {
  const { at } = p
  if (at.page === 'skill') return <Lists {...p} at={{ section: 'skills' }} />
  if (at.page === 'add' || at.page === 'review') return <FindPage {...p} />
  return <Lists {...p} />
}

/** A list page: the explainer, the section's own design, then the Mac's half as invitations. */
function Lists(p: CustomizeProps) {
  const s = p.at.section
  return (<>
    <Explainer section={s} docSlugs={p.docSlugs} onDocs={p.onDocs} />
    {s === 'skills' && <SkillsList {...p} />}
    {s === 'connections' && <ConnectionsList {...p} />}
    {s === 'rules' && <RulesList {...p} />}
    {s === 'memory' && <MemoryList />}
    {s === 'automations' && <AutomationsList />}
    <Invites section={s} machines={p.machines} />
  </>)
}

/** The card every list page opens with: what the thing is, one more sentence, and a docs link. */
export function Explainer({ section, docSlugs, onDocs }: { section: CustomizeSection; docSlugs: readonly string[]; onDocs: (slug: string) => void }) {
  const x = EXPLAINERS[section]
  const slug = docsSlugFor(section, docSlugs)
  return (
    <div className="cust-card cust-explain">
      <p><b>{x.lead}</b> {x.rest}</p>
      {slug && <a href={`/docs/${slug}`} onClick={(e) => { if (plain(e)) { e.preventDefault(); onDocs(slug) } }}>{x.link}</a>}
    </div>
  )
}

/** The Mac's half of a section, under one label at the foot, the pill where the control would be. */
function Invites({ section, machines }: { section: CustomizeSection; machines?: readonly { thisMac?: boolean }[] }) {
  const rows = CUSTOMIZE_INVITES[section]
  if (!rows.length) return null
  return (<>
    <div className="set-h">On your Mac</div>
    <div className="set-group set-invites">
      {rows.map((r) => (
        <div key={r.id} className="set-row" data-row={r.id}>
          <div style={{ flex: 1, minWidth: 0 }}><b>{r.label}</b><div className="det wrap">{r.description}</div></div>
          <InvitePill section={section} open={`frog://customize/${section}`} machines={machines} />
        </div>
      ))}
    </div>
  </>)
}

/** What a cloud session reads from a repo, and the repos it can open. */
function InRepos({ label, description, repos }: { label: string; description: ReactNode; repos?: RepoList }) {
  const n = repos?.repos.length ?? 0
  return (<>
    <div className="set-h">In your repos</div>
    <div className="set-group">
      <div className="set-row">
        <div style={{ flex: 1, minWidth: 0 }}><b>{label}</b><div className="det wrap">{description}</div></div>
      </div>
      <div className="set-row">
        <div style={{ flex: 1, minWidth: 0 }}><b>Repos Frog Cloud can open</b><div className="det wrap">{n ? repos!.repos.slice(0, 4).map((r) => r.name).join(', ') + (n > 4 ? `, and ${n - 4} more` : '') : repos?.install ? 'None yet. Choose which repos Frog can open on GitHub.' : 'None yet.'}</div></div>
        {n > 0 && <span className="det num">{n}</span>}
        {repos?.install && <a className="cust-pill" href={repos.install} target="_blank" rel="noreferrer" title="The Frog GitHub App's settings">Choose repos</a>}
      </div>
    </div>
  </>)
}

const Paths = ({ list }: { list: readonly string[] }) => <>{list.map((x, i) => <Fragment key={x}>{i ? (i === list.length - 1 ? ' or ' : ', ') : ''}<code>{x}</code></Fragment>)}</>

// ---------- The lists ----------
// Each section's own design (weight card and marks, tool squares, sheets, rail, week grid) draws
// from an engine report; until one reaches the web, each page says what a cloud session reads.

function SkillsList(p: CustomizeProps) {
  return <InRepos repos={p.repos} label="Skills in a repo" description={<>A cloud session uses the skills in the repo it opens, from <Paths list={CLOUD_READS.skills} />: a folder per skill, with a <code>SKILL.md</code> inside.</>} />
}

function ConnectionsList(p: CustomizeProps) {
  return <InRepos repos={p.repos} label="Servers in a repo's .mcp.json" description={<>A cloud session reads its repo's <code>{CLOUD_READS.connections}</code> and tries to start the servers it lists. A sandbox can only read the open web, so a server that signs in or writes to a service won't work there yet.</>} />
}

function RulesList(p: CustomizeProps) {
  return <InRepos repos={p.repos} label="A file at the repo's root" description={<>A cloud session reads <Paths list={CLOUD_READS.rules} /> from the root of the repo it opens, on every turn.</>} />
}

function MemoryList() {
  return (<>
    <div className="set-h">In Frog Cloud</div>
    <div className="set-group">
      <div className="set-row"><div style={{ flex: 1, minWidth: 0 }}><b>No notes kept</b><div className="det wrap">Each cloud session starts on a fresh machine, so nothing it noted is carried to the next one. Anything worth keeping can go in the repo's rules file, which every session reads.</div></div></div>
    </div>
  </>)
}

/** The week grid's head, today last, over the empty state. */
function AutomationsList() {
  const days = weekDays()
  return (<>
    <div className="cust-week" role="table" aria-label="Automations, the last seven days">
      <div className="cust-week-row cust-week-h" role="row">
        <span role="columnheader" className="cust-au">Automation</span>
        <span className="cust-wk" role="presentation">{days.map((d, i) => <span key={i} role="columnheader" className={`cust-dh${i === 6 ? ' now' : ''}`}>{d}</span>)}</span>
      </div>
    </div>
    <div className="cust-empty">
      <b>Nothing repeats yet.</b>
      <p className="det wrap">When automations arrive, you'll make one by doing the task once in a conversation and saying "keep doing this". Each run will show on its day here: what it did, what's waiting on you and what failed.</p>
    </div>
  </>)
}


// ---------- Add (F9Find) and Review (F10Review) ----------

/** Adding on the web: the repo is how a cloud session gets a skill or a server, so the page says
 *  how; search, review and one-click add are Frog for Mac's. */
function FindPage(p: CustomizeProps) {
  const skills = p.at.section === 'skills'
  return (<>
    <div className="set-h">In a repo</div>
    <div className="set-group">
      <div className="set-row" data-row="add-skill-repo"><div style={{ flex: 1, minWidth: 0 }}><b>Add a skill to a repo</b><div className="det wrap">Commit a folder with a <code>SKILL.md</code> under <code>.frog/skills</code>. Every cloud session on that repo picks it up.</div></div></div>
      <div className="set-row" data-row="add-server-repo"><div style={{ flex: 1, minWidth: 0 }}><b>Add a connection to a repo</b><div className="det wrap">List the server in <code>.mcp.json</code> at the repo's root. A cloud session tries to start it; one that signs in or writes to a service won't work from a sandbox yet.</div></div></div>
    </div>
    <div className="set-h">On your Mac</div>
    <div className="set-group set-invites">
      <div className="set-row" data-row="find"><div style={{ flex: 1, minWidth: 0 }}><b>{skills ? 'Find a skill' : 'Find a connection'}</b><div className="det wrap">Search tested skills and servers, read every tool before it's added, and switch each one on or off.</div></div><InvitePill section={p.at.section} open={`frog://customize/${p.at.section}`} machines={p.machines} /></div>
    </div>
  </>)
}
