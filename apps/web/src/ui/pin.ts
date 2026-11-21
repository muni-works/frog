// The transcript's pin to its end (docs/design/transcript/spec.md, "Following"). Sending always
// brings the view to the end, so your message and the start of the reply are in view, from
// wherever you were reading. Pinned, the view follows the reply as it grows, until the reply's
// first line would leave the top: there it holds, so a long answer reads from its start (as the
// Mac does). Your own scrolling (wheel, touch, the scrollbar, keys) releases either; scrolling
// back to the end pins it again, and an answer already held isn't held twice.
//
// Before transcript phase 1 (af22536b) the scroller's ref ran on every render and threw the view
// to the end each time, so a send always showed the reply, but you couldn't scroll up while one
// streamed. Phase 1 fixed that by following only from the end, and lost the jump on send.

/** Within this of the end counts as at the end (a line, and a hairline of rounding). */
export const NEAR_END = 40
/** How long after your own input a scroll event is yours rather than the page's. */
export const YOURS_MS = 800
/** Scrolling down to within this of the end pins again: about two lines. */
export const REPIN = 96
/** Room above a held answer's start, so it isn't flush with the top edge. */
export const HOLD_ROOM = 12

export const atEnd = (el: { scrollTop: number; scrollHeight: number; clientHeight: number }) =>
  el.scrollHeight - el.scrollTop - el.clientHeight < NEAR_END

const reduced = () => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches

export class Pin {
  pinned = true
  private el: HTMLElement | null = null
  private inputAt = -Infinity
  private smoothUntil = 0
  private off: (() => void) | null = null

  /** The scroller came (or went): listen to it for your own scrolling. */
  attach(el: HTMLElement | null) {
    this.off?.()
    this.off = null
    this.el = el
    if (!el) return
    // Your own input: it's yours from here, and a send's glide to the end stops where it is.
    const mine = () => {
      this.inputAt = performance.now()
      if (this.smoothUntil) { this.smoothUntil = 0; el.scrollTop = el.scrollTop }
    }
    const keys = (e: KeyboardEvent) => { if (/^(Arrow(Up|Down)|Page(Up|Down)|Home|End| )$/.test(e.key)) mine() }
    // Yours: up and away from the end lets go; down to near the end pins again (with room, as
    // a reply streaming fast can add a line between your last scroll and its event).
    let lastTop = el.scrollTop
    const scrolled = () => {
      const up = el.scrollTop < lastTop - 1
      lastTop = el.scrollTop
      if (performance.now() - this.inputAt >= YOURS_MS) return
      const gap = el.scrollHeight - el.scrollTop - el.clientHeight
      if (up && gap >= NEAR_END) this.pinned = false
      else if (!up && gap < REPIN) this.pinned = true
    }
    el.addEventListener('wheel', mine, { passive: true })
    el.addEventListener('touchstart', mine, { passive: true })
    el.addEventListener('touchmove', mine, { passive: true })
    el.addEventListener('pointerdown', mine)
    el.addEventListener('keydown', keys)
    el.addEventListener('scroll', scrolled, { passive: true })
    this.off = () => {
      el.removeEventListener('wheel', mine)
      el.removeEventListener('touchstart', mine)
      el.removeEventListener('touchmove', mine)
      el.removeEventListener('pointerdown', mine)
      el.removeEventListener('keydown', keys)
      el.removeEventListener('scroll', scrolled)
    }
  }

  /** You sent something: pin, and go to the end (animated, or a jump with reduced motion). */
  send() {
    this.pinned = true
    this.inputAt = -Infinity
    this.smoothUntil = reduced() ? 0 : performance.now() + 400
    this.follow()
  }

  /** The answer last held at its start (its `data-item`). */
  private held: string | null = null

  /** The reply being written, when its start would leave the top of the view following the end:
   *  where it starts (the prompt when it's the turn's first words), in the scroller's content. */
  private longAnswer(el: HTMLElement): { item: string; top: number } | null {
    const turn = el.querySelector('.tx > .turn:last-of-type')
    const say = turn?.querySelector<HTMLElement>('.say[data-item][data-writing]')
    const item = say?.dataset.item
    if (!turn || !say || !item || item === this.held) return null
    // After steps it reads from the answer; as the turn's first words, from your message.
    let tools = false
    for (const row of turn.querySelectorAll('.reply-block > [data-row="line"]')) {
      if (row.compareDocumentPosition(say) & Node.DOCUMENT_POSITION_FOLLOWING && !row.querySelector('[data-kind="thought"]') && (row as HTMLElement).dataset.kind !== 'thought') tools = true
    }
    const start = tools ? say : turn.querySelector<HTMLElement>('.me') ?? say
    const top = start.getBoundingClientRect().top - el.getBoundingClientRect().top + el.scrollTop - HOLD_ROOM
    return el.scrollHeight - top > el.clientHeight ? { item, top } : null
  }

  /** After a render: pinned, stay at the end of what's there now, or hold a long answer. */
  follow() {
    const el = this.el
    if (!el || !this.pinned) return
    const long = this.longAnswer(el)
    if (long) {
      this.held = long.item
      this.pinned = false
      this.smoothUntil = 0
      if (typeof el.scrollTo === 'function') el.scrollTo({ top: long.top, behavior: 'instant' })
      else el.scrollTop = long.top
      return
    }
    // `instant`, not a `scrollTop` write: that can lose to a wheel scroll still animating.
    const behavior: ScrollBehavior = performance.now() < this.smoothUntil ? 'smooth' : 'instant'
    if (typeof el.scrollTo === 'function') el.scrollTo({ top: el.scrollHeight, behavior })
    else el.scrollTop = el.scrollHeight
  }

  /** Placed somewhere on purpose (back from Documentation, the same session's last place). */
  placed() {
    if (this.el) this.pinned = atEnd(this.el)
  }
}
