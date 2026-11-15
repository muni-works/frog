// The composer's behaviour: a pure reducer (docs/plans/2026-11-12-composer-tray.md). The view
// renders `State` plus `derive(state)` and sends intents; effects come back as data for a thin
// runner to perform, which feeds results back as intents. The Mac has the same reducer in
// FrogKit (ComposerModel.swift); both pass docs/design/composer/cases.json.

export type Mode = 'auto' | 'default' | 'accept_edits' | 'yolo'
export type Place = 'local' | 'cloud'
export type Busy = 'idle' | 'working' | 'sending' | 'loading_model'
export type PrState = 'draft' | 'checks' | 'failing' | 'approved' | 'merged' | 'closed'
export type Action = 'dictate' | 'send' | 'stop' | 'queue'
export type GitAction = 'commit' | 'open_pr' | 'push' | 'fix' | 'merge' | 'archive' | 'reopen'

export interface Attachment { name: string; size: number; type: string }
export interface Model { id: string; name: string; place: Place; node?: string | null }
export interface Pr { repo: string; number: number; title: string; state: PrState; checks: { ok: number; total: number }; access?: boolean }

export type Where =
  | { kind: 'folder'; folder: string; branch: string; worktree: boolean; git: boolean; dirty: boolean }
  | { kind: 'cloud'; repo: string; branch: string }
  | { kind: 'chat' }
  | { kind: 'session'; repo: string | null; branch: string; worktree: boolean; worktreePath: string | null; diff: { add: number; del: number; files: number }; dirty: boolean; ahead: number; prs: Pr[] }

export interface ComposerError {
  code: string
  message: string
  actions: string[]
  control: string | null
  detail: string | null
  retryIn: number | null
}

export interface State {
  draft: { text: string; attachments: Attachment[]; caret: number }
  lastSent: string
  mode: Mode
  yoloConfirmed: boolean
  model: Model
  defaults: { local: Model | null; cloud: Model | null }
  signedIn: boolean
  where: Where
  busy: Busy
  /** What the send in flight carries: the draft (cleared on ack) or a git action's own text. */
  pending: 'draft' | 'aside' | null
  queued: number
  error: ComposerError | null
  notice: string | null
  confirm: 'yolo' | 'merge' | 'archive' | null
  stackOpen: boolean
  memory: { modelByPlace: Record<string, Model>; worktreeByRepo: Record<string, boolean>; branchByRepo: Record<string, string> }
  /** `[git] open_pr_when_done`. Absent: "ask", the default. "auto" reads as "ask". */
  openPrWhenDone?: OpenPrSetting
  /**
   * What `shouldOpenPr` decides on. Absent: unknown, and the chip stays plain — the web's cloud
   * sessions report no worktree and no session tree, so they never earn the emphasis. The Mac,
   * which knows all of it, is where `ask` actually shows.
   */
  openPr?: OpenPrInput
}

/** `[git] open_pr_when_done`: "auto" is parsed but deliberately not wired (see OpenPr.swift). */
export type OpenPrSetting = 'off' | 'ask' | 'auto'

/** The facts the Open PR predicate needs. Mirrors FrogKit's `OpenPR.Input`. */
export interface OpenPrInput {
  worktree: boolean
  ahead: number
  hasPR?: boolean
  depth?: number
  hasChildren?: boolean
  readOnly?: boolean
  optedOut?: boolean
}

export type Intent =
  | { type: 'type'; text: string; caret?: number }
  | { type: 'attach'; files: Attachment[] }
  | { type: 'remove_attachment'; index: number }
  | { type: 'suggestion'; text: string }
  | { type: 'recall' }
  | { type: 'send' }
  | { type: 'action' }
  | { type: 'ack' }
  | { type: 'send_failed'; code: string; retryIn?: number }
  | { type: 'turn_done' }
  | { type: 'stop' }
  | { type: 'esc' }
  | { type: 'model_loading' }
  | { type: 'model_ready' }
  | { type: 'mic_denied' }
  | { type: 'set_mode'; mode: Mode }
  | { type: 'cycle_mode' }
  | { type: 'confirm' }
  | { type: 'cancel_confirm' }
  | { type: 'pick_model'; model: Model }
  | { type: 'choose_folder'; folder: string; branch: string; git: boolean; dirty: boolean }
  | { type: 'choose_cloud'; repo: string; branch: string }
  | { type: 'just_chat' }
  | { type: 'pick_branch'; branch: string }
  | { type: 'switch_branch'; branch: string }
  | { type: 'toggle_worktree' }
  | { type: 'failed'; code: string; detail?: string }
  | { type: 'error_action'; action: string }
  | { type: 'dismiss_error' }
  | { type: 'git_action' }
  | { type: 'pr_click'; index: number; alt?: boolean }
  | { type: 'open_stack' }
  | { type: 'close_stack' }
  | { type: 'bind_pr'; ref: string }
  | { type: 'prs'; prs: Pr[] }

export type Effect = { type: string } & Record<string, unknown>

export interface Derived {
  action: Action
  sendDisabled: boolean
  gitAction: GitAction | null
  prSummary: { count: number; worst: PrState; label: string } | null
  canSwitchBranch: boolean
  /** Open PR is the predicate's (the work is done, and opening one is wanted). */
  openPr: boolean
}

export const MAX_ATTACHMENT = 20_000_000
const MODES: Mode[] = ['auto', 'default', 'accept_edits', 'yolo']
/** Worst first: the stack pill and the action follow the worst PR. */
export const PR_ORDER: PrState[] = ['failing', 'checks', 'draft', 'approved', 'closed', 'merged']
const PR_WORD: Record<PrState, string> = { failing: 'failing', checks: 'checking', draft: 'draft', approved: 'approved', closed: 'closed', merged: 'merged' }

/** Every error both apps show, worded once: [message, actions, control]. */
const ERRORS: Record<string, [string, string[], string | null]> = {
  engine_stopped: ["Frog's engine stopped", ['restart_engine'], null],
  signed_out: ['Signed out of Frog Cloud', ['sign_in'], null],
  no_credit: ['Out of credit', ['add_credit', 'use_local'], null],
  cloud_busy: ['Frog Cloud is busy', ['retry'], null],
  mic_denied: ['Allow microphone in System Settings', ['open_settings'], 'action'],
  worktree_failed: ["Couldn't make a worktree", ['use_checkout'], 'worktree'],
  clone_failed: ["Couldn't clone the repo", ['retry'], 'where'],
  hook_failed: ['A commit hook failed', ['show_output'], 'git_action'],
  gh_auth: ['Connect GitHub to open a PR', ['connect_github'], 'git_action'],
  push_rejected: ['Branch moved on GitHub', ['pull_retry'], 'git_action'],
  merge_conflict: ['This PR has conflicts', ['resolve_conflicts'], 'git_action'],
  branch_protected: ['Branch protection blocks the merge', [], 'git_action'],
  pr_not_found: ["Couldn't find that PR", [], null],
}

export function error(s: State, code: string, detail?: string | null, retryIn?: number | null): ComposerError {
  const [message, actions, control] = ERRORS[code] ?? ['Something went wrong', [], null]
  return {
    code,
    // A protected branch says why, in GitHub's words.
    message: code === 'branch_protected' && detail ? detail : message,
    actions: code === 'no_credit' && !s.defaults.local ? actions.filter((a) => a !== 'use_local') : actions,
    control,
    detail: detail ?? null,
    retryIn: retryIn ?? null,
  }
}

const hasContent = (s: State) => s.draft.text.trim() !== '' || s.draft.attachments.length > 0
const accepts = (a: Attachment) => a.type.startsWith('image/') || a.type.startsWith('text/') || a.type === 'application/pdf' || a.type === 'application/json'

function worst(prs: Pr[]): Pr | null {
  let w: Pr | null = null
  for (const p of prs) if (!w || PR_ORDER.indexOf(p.state) < PR_ORDER.indexOf(w.state)) w = p
  return w
}

/** A manager: a top-level session with sessions under it (mirrors OpenPR.Input.isManager). */
const isManager = (i: OpenPrInput) => (i.depth ?? 0) === 0 && i.hasChildren === true

/**
 * When the composer offers to open a pull request (FrogKit/Core/OpenPR.swift is the same
 * predicate, and the tests assert both). All of: its own worktree, commits ahead of the base,
 * no PR yet, not a manager, not read-only, not opted out.
 */
export function shouldOpenPr(i: OpenPrInput): boolean {
  return i.worktree && i.ahead > 0 && !i.hasPR && !isManager(i) && !i.readOnly && !i.optedOut
}

/** `[git] open_pr_when_done` as it applies now: "auto" is not implemented and reads as "ask". */
export function effectiveOpenPr(setting: OpenPrSetting | undefined): 'off' | 'ask' {
  return setting === 'off' ? 'off' : 'ask'
}

/** Whether the setting offers Open PR for this session (off never does; auto == ask). */
export function offersOpenPr(setting: OpenPrSetting | undefined, i: OpenPrInput): boolean {
  return effectiveOpenPr(setting) === 'ask' && shouldOpenPr(i)
}

/** The first-prompt marker that turns the offer off for one session: `open-pr: off`. */
export function optedOutOfOpenPr(firstPrompt: string | null | undefined): boolean {
  if (!firstPrompt) return false
  return firstPrompt.split('\n').some((line) => {
    const l = line.trim().toLowerCase()
    if (!l.startsWith('open-pr:')) return false
    const value = l.slice('open-pr:'.length).trim()
    return value === 'off' || value === 'never'
  })
}

export function derive(s: State): Derived {
  const content = hasContent(s)
  const action: Action =
    s.busy === 'working' ? (content ? 'queue' : 'stop')
    : s.busy === 'loading_model' ? 'stop'
    : s.busy === 'sending' ? 'send'
    : content ? 'send' : 'dictate'
  let gitAction: GitAction | null = null
  let prSummary: Derived['prSummary'] = null
  let canSwitchBranch = true
  // `[git] open_pr_when_done = "off"`: the branch is yours to push, so nothing is offered.
  const setting = effectiveOpenPr(s.openPrWhenDone)
  if (s.where.kind === 'session') {
    const w = s.where
    canSwitchBranch = !w.dirty
    const top = worst(w.prs)
    if (top?.state === 'merged') gitAction = 'archive'
    else if (w.dirty) gitAction = 'commit'
    else if (!top) gitAction = w.ahead > 0 ? 'open_pr' : null
    else if (top.state === 'closed') gitAction = 'reopen'
    else if (top.state === 'failing') gitAction = 'fix'
    else if (w.ahead > 0) gitAction = 'push'
    else if (top.state === 'approved') gitAction = 'merge'
    if (top) {
      const n = w.prs.length
      const k = w.prs.filter((p) => p.state === top.state).length
      const label = n === 1 ? `#${top.number}` : `${n} PRs, ${k === n ? 'all' : k} ${PR_WORD[top.state]}`
      prSummary = { count: n, worst: top.state, label }
    }
  }
  if (gitAction === 'open_pr' && setting === 'off') gitAction = null
  // The predicate decides the action's emphasis, not whether it exists: a manager can still
  // open a PR by hand, it just isn't urged to. Facts the composer doesn't have earn nothing,
  // so an absent `openPr` leaves the chip as plain as it has always been.
  const openPr = gitAction === 'open_pr' && s.openPr !== undefined && offersOpenPr(setting, s.openPr)
  return { action, sendDisabled: s.busy === 'sending' || (s.busy === 'idle' && !content), gitAction, prSummary, canSwitchBranch, openPr }
}

/** The key a model is remembered under: the folder, the cloud repo, or chat. */
function placeKey(w: Where): string {
  switch (w.kind) {
    case 'folder': return w.folder
    case 'cloud': return 'cloud'
    case 'chat': return 'chat'
    case 'session': return w.repo ?? 'session'
  }
}

type Out = [State, Effect[]]

function send(s: State): Out {
  if (!hasContent(s)) return [s, []]
  const text = s.draft.text.trim()
  const attachments = s.draft.attachments
  if (s.busy === 'sending') return [s, []]
  if (s.busy === 'loading_model') return [{ ...s, pending: 'draft' }, []]
  if (s.busy === 'working') {
    return [{ ...s, draft: { text: '', attachments: [], caret: 0 }, lastSent: text, queued: s.queued + 1 }, [{ type: 'queued', text, attachments }]]
  }
  const next: State = { ...s, busy: 'sending', pending: 'draft', error: null }
  if (s.where.kind === 'session') return [next, [{ type: 'submit', text, attachments }]]
  return [next, [{ type: 'start_session', where: s.where, text, attachments }]]
}

/** A turn a git action asks for (Fix, Resolve conflicts): the draft stays put. */
function sendAside(s: State, text: string): Out {
  if (s.busy === 'working') return [{ ...s, queued: s.queued + 1 }, [{ type: 'queued', text, attachments: [] }]]
  return [{ ...s, busy: 'sending', pending: 'aside', error: null }, [{ type: 'submit', text, attachments: [] }]]
}

function setMode(s: State, mode: Mode): Out {
  if (mode === 'yolo' && !s.yoloConfirmed) return [{ ...s, confirm: 'yolo' }, []]
  if (mode === s.mode) return [s, []]
  return [{ ...s, mode, confirm: null }, [{ type: 'set_mode', mode }]]
}

function switchModel(s: State, model: Model | null, place: string): Out {
  if (!model || model.id === s.model.id) return [s, []]
  const moved = model.place !== s.model.place
  return [{ ...s, model, notice: moved ? `Switched to ${model.name} ${place}` : s.notice }, [{ type: 'set_model', model }]]
}

export function reduce(s: State, i: Intent): Out {
  switch (i.type) {
    case 'type':
      return [{ ...s, draft: { ...s.draft, text: i.text, caret: i.caret ?? i.text.length } }, []]
    case 'attach': {
      const refused = i.files.filter((f) => f.size > MAX_ATTACHMENT || !accepts(f))
      const ok = i.files.filter((f) => !refused.includes(f))
      const draft = { ...s.draft, attachments: [...s.draft.attachments, ...ok] }
      if (!refused.length) return [{ ...s, draft, error: s.error?.code === 'attach_refused' ? null : s.error }, []]
      const why = (f: Attachment) => `${f.name} (${f.size > MAX_ATTACHMENT ? 'over 20 MB' : 'not a supported type'})`
      const e: ComposerError = { code: 'attach_refused', message: `Couldn't attach ${refused.map(why).join(', ')}`, actions: [], control: null, detail: null, retryIn: null }
      return [{ ...s, draft, error: e }, []]
    }
    case 'remove_attachment':
      return [{ ...s, draft: { ...s.draft, attachments: s.draft.attachments.filter((_, n) => n !== i.index) } }, []]
    case 'suggestion':
      if (s.where.kind === 'session' || s.draft.text !== '') return [s, []]
      return [{ ...s, draft: { ...s.draft, text: i.text, caret: i.text.length } }, []]
    case 'recall':
      if (s.draft.text !== '' || !s.lastSent) return [s, []]
      return [{ ...s, draft: { ...s.draft, text: s.lastSent, caret: s.lastSent.length } }, []]
    case 'send':
      return send(s)
    case 'action': {
      const a = derive(s).action
      if (a === 'dictate') return [s, [{ type: 'start_dictation' }]]
      if (a === 'stop') return reduce(s, { type: 'stop' })
      return send(s)
    }
    case 'ack': {
      const sent = s.pending === 'draft'
      return [{
        ...s,
        busy: 'working',
        pending: null,
        error: null,
        draft: sent ? { text: '', attachments: [], caret: 0 } : s.draft,
        lastSent: sent ? s.draft.text.trim() : s.lastSent,
      }, []]
    }
    case 'send_failed':
      return [{ ...s, busy: 'idle', pending: null, error: error(s, i.code, null, i.retryIn ?? null) }, []]
    case 'turn_done':
      return [{ ...s, busy: 'idle', queued: 0 }, []]
    case 'stop':
      if (s.busy === 'working') return [s, [{ type: 'interrupt' }]]
      if (s.busy === 'loading_model') return [{ ...s, busy: 'idle', pending: null }, [{ type: 'cancel_load' }]]
      return [s, []]
    case 'esc':
      if (s.busy === 'working' || s.busy === 'loading_model') return reduce(s, { type: 'stop' })
      if (s.confirm) return [{ ...s, confirm: null }, []]
      if (s.error) return [{ ...s, error: null }, []]
      if (s.stackOpen) return [{ ...s, stackOpen: false }, []]
      return [s, []]
    case 'model_loading':
      return [{ ...s, busy: 'loading_model' }, []]
    case 'model_ready': {
      const ready: State = { ...s, busy: 'idle' }
      return s.pending === 'draft' ? send({ ...ready, pending: null }) : [ready, []]
    }
    case 'mic_denied':
      return [{ ...s, error: error(s, 'mic_denied') }, []]
    case 'set_mode':
      return setMode(s, i.mode)
    case 'cycle_mode':
      return setMode(s, MODES[(MODES.indexOf(s.mode) + 1) % MODES.length])
    case 'confirm':
      if (s.confirm === 'yolo') return [{ ...s, mode: 'yolo', yoloConfirmed: true, confirm: null }, [{ type: 'set_mode', mode: 'yolo' }]]
      if (s.confirm === 'merge' && s.where.kind === 'session') {
        const top = worst(s.where.prs)
        return [{ ...s, confirm: null }, top ? [{ type: 'merge', repo: top.repo, number: top.number }] : []]
      }
      if (s.confirm === 'archive') return [{ ...s, confirm: null }, [{ type: 'archive', discard: true }]]
      return [s, []]
    case 'cancel_confirm':
      return [{ ...s, confirm: null }, []]
    case 'pick_model': {
      if (i.model.place === 'cloud' && !s.signedIn) return [s, [{ type: 'open_login' }]]
      const memory = { ...s.memory, modelByPlace: { ...s.memory.modelByPlace, [placeKey(s.where)]: i.model } }
      const notice = s.busy === 'working' && i.model.node ? 'Swaps after this turn' : s.notice
      return [{ ...s, model: i.model, memory, notice }, [{ type: 'set_model', model: i.model }]]
    }
    case 'choose_folder': {
      const m = s.memory
      const where: Where = {
        kind: 'folder',
        folder: i.folder,
        branch: m.branchByRepo[i.folder] ?? i.branch,
        worktree: i.git && (m.worktreeByRepo[i.folder] ?? true),
        git: i.git,
        dirty: i.dirty,
      }
      const want = m.modelByPlace[i.folder] ?? (s.model.place === 'cloud' ? s.defaults.local : null)
      return switchModel({ ...s, where, notice: null, error: null }, want, 'on this Mac')
    }
    case 'choose_cloud': {
      const where: Where = { kind: 'cloud', repo: i.repo, branch: s.memory.branchByRepo[i.repo] ?? i.branch }
      const want = s.memory.modelByPlace.cloud ?? (s.model.place === 'local' ? s.defaults.cloud : null)
      return switchModel({ ...s, where, notice: null, error: null }, want, 'for Frog Cloud')
    }
    case 'just_chat':
      return switchModel({ ...s, where: { kind: 'chat' }, notice: null, error: null }, s.memory.modelByPlace.chat ?? null, '')
    case 'pick_branch': {
      if (s.where.kind !== 'folder' && s.where.kind !== 'cloud') return [s, []]
      const key = s.where.kind === 'folder' ? s.where.folder : s.where.repo
      return [{ ...s, where: { ...s.where, branch: i.branch }, memory: { ...s.memory, branchByRepo: { ...s.memory.branchByRepo, [key]: i.branch } } }, []]
    }
    case 'switch_branch':
      if (s.where.kind !== 'session' || s.where.dirty) return [s, []]
      return [s, [{ type: 'switch_branch', branch: i.branch }]]
    case 'toggle_worktree': {
      if (s.where.kind !== 'folder' || !s.where.git) return [s, []]
      const worktree = !s.where.worktree
      return [{
        ...s,
        where: { ...s.where, worktree },
        memory: { ...s.memory, worktreeByRepo: { ...s.memory.worktreeByRepo, [s.where.folder]: worktree } },
        notice: !worktree && s.where.dirty ? 'Frog will work in your checkout' : null,
        error: s.error?.control === 'worktree' ? null : s.error,
      }, []]
    }
    case 'failed':
      return [{ ...s, busy: s.busy === 'sending' ? 'idle' : s.busy, pending: s.busy === 'sending' ? null : s.pending, error: error(s, i.code, i.detail ?? null) }, []]
    case 'dismiss_error':
      return [{ ...s, error: null }, []]
    case 'error_action':
      return errorAction(s, i.action)
    case 'git_action': {
      const a = derive(s).gitAction
      if (!a || s.where.kind !== 'session') return [s, []]
      const top = worst(s.where.prs)
      switch (a) {
        case 'commit': return [s, [{ type: 'draft_commit' }]]
        case 'open_pr': return [s, [{ type: 'open_pr' }]]
        case 'push': return [s, [{ type: 'push' }]]
        case 'fix': return sendAside(s, `Fix the failing checks on #${top!.number}`)
        case 'merge': return [{ ...s, confirm: 'merge' }, []]
        case 'archive': return s.where.dirty ? [{ ...s, confirm: 'archive' }, []] : [s, [{ type: 'archive', discard: false }]]
        case 'reopen': return [s, [{ type: 'reopen', repo: top!.repo, number: top!.number }]]
      }
      return [s, []]
    }
    case 'pr_click': {
      if (s.where.kind !== 'session') return [s, []]
      const pr = s.where.prs[i.index]
      if (!pr) return [s, []]
      const url = `https://github.com/${pr.repo}/pull/${pr.number}`
      return [s, [i.alt ? { type: 'copy', text: url } : { type: 'open_url', url }]]
    }
    case 'open_stack':
      return [{ ...s, stackOpen: s.where.kind === 'session' && s.where.prs.length > 1 }, []]
    case 'close_stack':
      return [{ ...s, stackOpen: false }, []]
    case 'bind_pr':
      return i.ref.trim() ? [s, [{ type: 'bind_pr', ref: i.ref.trim() }]] : [s, []]
    case 'prs':
      if (s.where.kind !== 'session') return [s, []]
      return [{ ...s, where: { ...s.where, prs: i.prs } }, []]
  }
}

function errorAction(s: State, action: string): Out {
  const clear: State = { ...s, error: null }
  switch (action) {
    case 'restart_engine': return [clear, [{ type: 'restart_engine' }]]
    case 'sign_in': return [clear, [{ type: 'open_login' }]]
    case 'add_credit': return [clear, [{ type: 'open_billing' }]]
    case 'use_local': return s.defaults.local ? [{ ...clear, model: s.defaults.local }, [{ type: 'set_model', model: s.defaults.local }]] : [s, []]
    case 'retry': return send(clear)
    case 'open_settings': return [clear, [{ type: 'open_mic_settings' }]]
    case 'use_checkout':
      if (s.where.kind !== 'folder') return [clear, []]
      return send({ ...clear, where: { ...s.where, worktree: false } })
    case 'pull_retry': return [clear, [{ type: 'pull_push' }]]
    case 'connect_github': return [clear, [{ type: 'gh_auth_login' }]]
    case 'show_output': return [s, [{ type: 'show_output', detail: s.error?.detail ?? '' }]]
    case 'resolve_conflicts': {
      const top = s.where.kind === 'session' ? worst(s.where.prs) : null
      return top ? sendAside(clear, `Resolve the merge conflicts on #${top.number}`) : [clear, []]
    }
  }
  return [s, []]
}
