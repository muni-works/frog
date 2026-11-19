import { Fragment, useEffect, useRef, useState, type ReactNode } from 'react'
import { savedAutoNote, setAutoNote } from '../settings'
import {
  activityLevels, CLOUD_READS, CUSTOMIZE_INVITES, customizeLabel, customizePath, docsSlugFor, EXPLAINERS, railDay, tokens, toolsLabel, usedLabel, weekDays, weightBars,
  type Automation, type Connection, type CustomizeAt, type CustomizeSection, type Report, type RulesFile, type RunMark, type Skill, type Tool, type Use,
} from '../customize'
import type { RepoList } from '../cloud/protocol'
import { InvitePill } from './DownloadChip'

// Settings' middle run (docs/design/app-shell.md): Skills, Connections, Rules, Memory and
// Automations, each a Settings section with a page of its own and breadcrumbs in the header
// ("Settings › Skills"). Each list page opens with an explainer card. On the web, what a Frog Cloud session really reads from
// a repo is said plainly; what lives on a Mac is an invitation under "On your Mac". The designs for
// each list (weight card, activity marks, tool squares, sheets, rail, week grid) draw only from an
// engine report (docs/customize-api.md): with none, no figure is shown.

/** A plain left click, which routes in place; anything else is the browser's (a new tab). */
const plain = (e: React.MouseEvent) => !(e.metaKey || e.ctrlKey || e.shiftKey || e.altKey || e.button !== 0)

export interface CustomizeProps {
  at: CustomizeAt
  /** The repos Frog Cloud can open (GET /v1/repos). */
  repos?: RepoList
  /** An engine report, when a session has answered one. None today on the web: figures stay hidden. */
  report?: Report | null
  /** Automations, once they exist. */
  automations?: Automation[]
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
  const skill = p.at.page === 'skill' ? p.report?.skills.items.find((s) => s.name === (p.at as { name: string }).name) : undefined
  return (
    <main className="main docs-main settings-main customize-main">
      <div className="titlebar">{p.bar}<Crumbs at={p.at} skill={skill} onOpen={p.onOpen} /><HeaderRight {...p} /></div>
      <div className="scroll" ref={scroller}>
        <div className="col settings-page customize-page" aria-label={pageLabel(p.at)} data-page={key}>
          <Body {...p} skill={skill} />
        </div>
      </div>
    </main>
  )
}

const pageLabel = (at: CustomizeAt) => at.page === 'skill' ? at.name : at.page === 'add' ? 'Add' : at.page === 'review' ? at.id : customizeLabel(at.section)

/** "Settings › Skills › /release-notes": parents are links, the page itself is bold. */
export function Crumbs({ at, skill, onOpen }: { at: CustomizeAt; skill?: Skill; onOpen: (at: CustomizeAt) => void }) {
  const trail: { label: string; to?: CustomizeAt; mono?: boolean }[] = [{ label: customizeLabel(at.section), to: { section: at.section } }]
  if (at.page === 'skill') trail.push({ label: `/${skill?.name ?? at.name}`, mono: true })
  if (at.page === 'add' || at.page === 'review') trail.push({ label: 'Add', to: { section: at.section, page: 'add' } as CustomizeAt })
  if (at.page === 'review') trail.push({ label: at.id })
  return (
    <nav className="crumbs" aria-label="Breadcrumb">
      <span>Settings</span>
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

/** The header's right side: a section's total weight when a report has it, and its Add button. */
function HeaderRight({ at, report, onOpen }: CustomizeProps) {
  if (at.page) return null
  const weight = report ? sectionTokens(report, at.section) : null
  const add = at.section === 'skills' ? 'Add a skill' : at.section === 'connections' ? 'Add a connection' : null
  if (weight == null && !add) return null
  return (
    <div className="cust-hdr-rt">
      {weight != null && <span className="num">{tokens(weight)} a turn</span>}
      {add && <button type="button" className="cust-pill" onClick={() => onOpen({ section: at.section as 'skills' | 'connections', page: 'add' })}>{add}</button>}
    </div>
  )
}

const sectionTokens = (r: Report, s: CustomizeSection): number | null =>
  s === 'skills' ? r.skills.tokens : s === 'connections' ? r.connections.tokens : s === 'rules' ? r.rules.tokens : s === 'memory' ? r.memory.tokens : null

function Body(p: CustomizeProps & { skill?: Skill }) {
  const { at } = p
  if (at.page === 'skill') return p.skill ? <SkillPage skill={p.skill} /> : <Lists {...p} at={{ section: 'skills' }} />
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
    {s === 'memory' && <MemoryList {...p} />}
    {s === 'automations' && <AutomationsList {...p} />}
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
          <InvitePill section={section} open={`frog://settings/${section}`} machines={machines} />
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

// ---------- Skills (F1Skills) ----------

function SkillsList(p: CustomizeProps) {
  const r = p.report
  return (<>
    {r && <WeightCard skills={r.skills.items} used={r.skills.tokens} budget={r.skills.budget_tokens} />}
    {r
      ? <ScopeGroups items={r.skills.items} row={(s) => <SkillRow key={s.id} skill={s} onOpen={() => p.onOpen({ section: 'skills', page: 'skill', name: s.name })} />} />
      : <InRepos repos={p.repos} label="Skills in a repo" description={<>A cloud session uses the skills in the repo it opens, from <Paths list={CLOUD_READS.skills} />: a folder per skill, with a <code>SKILL.md</code> inside.</>} />}
  </>)
}

/** What every turn carries: one bar per skill's summary, out of the budget. */
export function WeightCard({ skills, used, budget }: { skills: Skill[]; used: number; budget: number }) {
  const bars = weightBars(skills, budget)
  return (
    <div className="cust-card cust-weight">
      <div className="cust-weight-h"><b>Weight on every turn</b><span className="num">{used.toLocaleString('en-US')} of {tokens(budget)}</span></div>
      <div className="cust-strip" role="img" aria-label={`What each skill adds to a turn, out of a budget of ${tokens(budget)}`}>
        {bars.map((b) => <i key={b.name} className={b.idle ? 'idle' : undefined} style={{ width: `${b.share * 100}%` }} title={b.name} />)}
        <i className="room" />
      </div>
      <p className="det wrap">Each bar is one skill's summary.{bars.some((b) => b.idle) ? " The outlined one hasn't been used in 30 days." : ''}</p>
    </div>
  )
}

/** "In <project>" then "Everywhere": a report's items by scope. */
function ScopeGroups<T extends { scope: 'project' | 'everywhere' }>({ items, row, project }: { items: T[]; row: (x: T) => ReactNode; project?: string }) {
  const groups: [string, T[]][] = [[project ? `In ${project}` : 'In this repo', items.filter((x) => x.scope === 'project')], ['Everywhere', items.filter((x) => x.scope === 'everywhere')]]
  return groups.filter(([, xs]) => xs.length).map(([g, xs]) => (
    <Fragment key={g}><div className="set-h">{g}</div><div className="cust-rows">{xs.map(row)}</div></Fragment>
  ))
}

function SkillRow({ skill: s, onOpen }: { skill: Skill; onOpen: () => void }) {
  const idle = !s.on || s.use.count === 0
  return (
    <a className={`cust-skill${idle ? ' idle' : ''}`} href={customizePath({ section: 'skills', page: 'skill', name: s.name })} onClick={(e) => { if (plain(e)) { e.preventDefault(); onOpen() } }}>
      <div style={{ minWidth: 0 }}><span className="cust-nm mono">/{s.name}</span><span className="det wrap">{s.description}</span></div>
      <Activity use={s.use} />
      <span className="cust-n num">{!s.on ? 'off' : s.use.count || 'never'}</span>
      <OnOff on={s.on} label={s.name} />
    </a>
  )
}

/** The last 30 days, one mark a day: tall for a busy day, short for some, a dot for none. */
export function Activity({ use }: { use: Use }) {
  return (
    <span className="cust-act" role="img" aria-label={usedLabel(use)}>
      {activityLevels(use.days).map((c, i) => <i key={i} className={c ? `cust-${c}` : undefined} />)}
    </span>
  )
}

/** On or off, as a read-only switch: changes need a session's change call, which the web hasn't. */
function OnOff({ on, label }: { on: boolean; label: string }) {
  return <span className={`cust-tog${on ? ' on' : ''}`} role="switch" aria-checked={on} aria-readonly="true" aria-label={label} title={on ? 'On' : 'Off'} />
}

// ---------- Skill (F2Skill) ----------

function SkillPage({ skill: s }: { skill: Skill }) {
  const last = s.use.last
  return (
    <div className="set-group">
      <div className="set-row"><div style={{ flex: 1, minWidth: 0 }}><b>Use this skill</b><div className="det wrap">{s.description}</div></div><OnOff on={s.on} label="Use this skill" /></div>
      <div className="set-row"><div style={{ flex: 1, minWidth: 0 }}><b>Weight</b><div className="det wrap">Its summary on every turn. The full text, {tokens(s.full_tokens)}, only when it's used.</div></div><span className="det num">{tokens(s.tokens)} a turn</span></div>
      <div className="set-row"><div style={{ flex: 1, minWidth: 0 }}><b>Used</b><div className="det wrap">{last ? `Last on ${railDay(last.at)}${last.title ? `, in "${last.title}"` : ''}. ` : ''}The marks are the last 30 days.</div></div><Activity use={s.use} /><span className="det num">{s.use.count === 1 ? 'once' : `${s.use.count} times`}</span></div>
      {s.path && <div className="set-row"><div style={{ flex: 1, minWidth: 0 }}><b>File</b><div className="det wrap mono">{s.path}</div></div></div>}
    </div>
  )
}

// ---------- Connections (F3Connections) ----------

function ConnectionsList(p: CustomizeProps) {
  const r = p.report
  if (!r) return <InRepos repos={p.repos} label="Servers in a repo's .mcp.json" description={<>A cloud session reads its repo's <code>{CLOUD_READS.connections}</code> and tries to start the servers it lists. A sandbox can only read the open web, so a server that signs in or writes to a service won't work there yet.</>} />
  return (<>
    <div className="cust-rows">{r.connections.items.map((c) => <ConnectionRow key={c.name} c={c} />)}</div>
    {r.connections.items.length > 0 && <SquaresKey />}
  </>)
}

function ConnectionRow({ c }: { c: Connection }) {
  const on = c.tools.filter((t) => t.state === 'on').length
  const held = c.tools.filter((t) => t.state === 'withheld').length
  const needs = c.state === 'needs_sign_in' || c.waiting != null
  return (
    <div className="cust-conn">
      <div className="cust-conn-nm">{needs && <span className="cust-dot" role="img" aria-label="Needs you" />}{c.name}</div>
      <Squares tools={c.tools} unknown={c.state === 'needs_sign_in' ? 'Tools unknown until you sign in' : undefined} />
      <div className="cust-conn-ctl">{c.on && c.tokens > 0 && <span className="num">{tokens(c.tokens)}</span>}<OnOff on={c.on} label={c.name} /></div>
      <div className="cust-conn-say det wrap">
        {c.state === 'needs_sign_in' ? "Wants you to sign in. Frog can't see its tools until you do."
          : c.state === 'failed' ? c.error ?? "Didn't start."
          : <><b>{on} of {c.tools.length} tools on.</b>{held ? ` ${held} ${held === 1 ? 'is' : 'are'} withheld: ${held === 1 ? 'its description reads' : 'their descriptions read'} like instructions to the model.` : ''} {c.use.count ? `${c.use.count} calls this month.` : 'Never called.'}</>}
      </div>
    </div>
  )
}

/** One square per tool: filled for on, outlined for off, struck for withheld. */
export function Squares({ tools, unknown }: { tools: Pick<Tool, 'state' | 'name'>[]; unknown?: string }) {
  return (
    <span className="cust-sq" role="img" aria-label={unknown ?? toolsLabel(tools)}>
      {tools.map((t) => <i key={t.name} className={t.state === 'on' ? undefined : t.state === 'withheld' ? 'held' : 'off'} title={t.name} />)}
    </span>
  )
}

function SquaresKey() {
  return (
    <div className="cust-key det" aria-hidden="true">
      <span><i className="sq" />a tool Frog can use</span><span><i className="sq off" />off</span><span><i className="sq held" />withheld</span>
    </div>
  )
}

// ---------- Rules (F4Instructions, titled Rules) ----------

function RulesList(p: CustomizeProps) {
  const r = p.report
  if (!r) return <InRepos repos={p.repos} label="A file at the repo's root" description={<>A cloud session reads <Paths list={CLOUD_READS.rules} /> from the root of the repo it opens, on every turn.</>} />
  return (<>
    {r.rules.files.map((f) => <Sheet key={f.path} file={f} />)}
    {r.rules.files.some((f) => f.lines.some((l) => l.follows != null)) && <p className="det cust-foot">The number beside a line is how many turns followed it in the last 30 days.</p>}
  </>)
}

/** A rules file as a sheet of lines, numbered as in an editor. */
function Sheet({ file }: { file: RulesFile }) {
  return (
    <section className="cust-sheet" aria-label={`${file.scope === 'project' ? 'In this repo' : 'Everywhere'}, ${file.path}`}>
      <div className="cust-sheet-h"><b>{file.scope === 'project' ? 'In this repo' : 'Everywhere'}</b><span className="mono">{file.path.split('/').slice(-2).join('/')}</span></div>
      {file.lines.map((l) => (
        <div key={l.n} className="cust-ln"><span className="cust-g num">{l.follows ?? ''}</span><span>{l.text}</span></div>
      ))}
    </section>
  )
}

// ---------- Memory (F5Memory) ----------

/** Noting on its own (`auto-note`): sent to every open session's engine as it changes. */
function AutoNoteRow() {
  const [on, setOn] = useState(savedAutoNote())
  return (
    <div className="set-group">
      <label className="set-row" data-row="auto-note">
        <div style={{ flex: 1, minWidth: 0 }}><b>Notes on its own</b><div className="det wrap">Frog keeps short notes from what you tell it and what it reads in your repo, with Undo under the reply.</div></div>
        <input type="checkbox" role="switch" aria-label="Notes on its own" checked={on} onChange={(e) => { setAutoNote(e.target.checked); setOn(e.target.checked) }} />
      </label>
    </div>
  )
}

function MemoryList(p: CustomizeProps) {
  return (<><AutoNoteRow /><MemoryNotes {...p} /></>)
}

function MemoryNotes(p: CustomizeProps) {
  const notes = p.report?.memory.notes ?? []
  if (!notes.length) return (<>
    <div className="set-h">In Frog Cloud</div>
    <div className="set-group">
      <div className="set-row"><div style={{ flex: 1, minWidth: 0 }}><b>No notes kept</b><div className="det wrap">Each cloud session starts on a fresh machine, so nothing it noted is carried to the next one. Anything worth keeping can go in the repo's rules file, which every session reads.</div></div></div>
    </div>
  </>)
  return (
    <ol className="cust-rail" aria-label="Notes, newest first">
      {notes.map((n, i) => (
        <li key={n.id} className={`cust-ev${i === 0 ? ' fresh' : ''}`}>
          <time className="cust-when num" dateTime={n.created}>{railDay(n.created)}</time>
          <span className="cust-node" aria-hidden="true" />
          <div style={{ minWidth: 0 }}><span className="cust-note">{n.text}</span>{n.title && <span className="det">from "{n.title}"</span>}</div>
          <span className="det cust-scope">{n.scope === 'project' ? 'this repo' : 'everywhere'}</span>
        </li>
      ))}
    </ol>
  )
}

// ---------- Automations (F6Automations) ----------

const MARK: Record<RunMark, { cls: string; say: string }> = {
  did: { cls: '', say: 'ran and did something' },
  idle: { cls: 'idle', say: 'ran, nothing to do' },
  ask: { cls: 'ask', say: 'waiting on you' },
  fail: { cls: 'fail', say: 'failed' },
}

function AutomationsList({ automations = [] }: CustomizeProps) {
  const days = weekDays()
  return (<>
    <div className="cust-week" role="table" aria-label="Automations, the last seven days">
      <div className="cust-week-row cust-week-h" role="row">
        <span role="columnheader" className="cust-au">Automation</span>
        <span className="cust-wk" role="presentation">{days.map((d, i) => <span key={i} role="columnheader" className={`cust-dh${i === 6 ? ' now' : ''}`}>{d}</span>)}</span>
      </div>
      {automations.map((a) => (
        <div key={a.id} className="cust-week-row" role="row">
          <div role="rowheader" className="cust-au"><span className="cust-au-nm">{a.waiting && <span className="cust-dot" role="img" aria-label="Needs you" />}{a.name}</span><span className="det">{[a.when, a.where].join(', ')}</span></div>
          <span className="cust-wk" role="presentation">
            {a.week.map((runs, i) => (
              <span key={i} role="cell" className={`cust-c${i === 6 ? ' now' : ''}`} aria-label={`${days[i]}: ${runs.length ? runs.map((r) => MARK[r].say).join(', ') : 'no runs'}`}>
                {runs.map((r, j) => <i key={j} className={MARK[r].cls || undefined} />)}
              </span>
            ))}
          </span>
          <OnOff on={a.on} label={a.name} />
        </div>
      ))}
    </div>
    {automations.length > 0 && (
      <div className="cust-key det" aria-hidden="true">
        {(Object.keys(MARK) as RunMark[]).map((m) => <span key={m}><i className={`mk ${MARK[m].cls}`} />{MARK[m].say}</span>)}
      </div>
    )}
    {!automations.length && (
      <div className="cust-empty">
        <b>Nothing repeats yet.</b>
        <p className="det wrap">When automations arrive, you'll make one by doing the task once in a conversation and saying "keep doing this". Each run will show on its day here: what it did, what's waiting on you and what failed.</p>
      </div>
    )}
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
      <div className="set-row" data-row="find"><div style={{ flex: 1, minWidth: 0 }}><b>{skills ? 'Find a skill' : 'Find a connection'}</b><div className="det wrap">Search tested skills and servers, read every tool before it's added, and switch each one on or off.</div></div><InvitePill section={p.at.section} open={`frog://settings/${p.at.section}`} machines={p.machines} /></div>
    </div>
  </>)
}
