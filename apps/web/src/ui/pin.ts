// The transcript's pin to its end. Pinned, the view stays at the bottom as the reply grows;
// your own scrolling (wheel, touch, the scrollbar, keys) is the only thing that unpins it, and
// scrolling back to the end pins it again. Sending always pins and brings the view down, so your
// message and the start of the reply are in view, from wherever you were reading.
//
// Before transcript phase 1 (af22536b) the scroller's ref ran on every render and threw the view
// to the end each time, so a send always showed the reply, but you couldn't scroll up while one
// streamed. Phase 1 fixed that by following only from the end, and lost the jump on send.

/** Within this of the end counts as at the end (a line, and a hairline of rounding). */
export const NEAR_END = 40
/** How long after your own input a scroll event is yours rather than the page's. */
export const YOURS_MS = 800

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
    const scrolled = () => { if (performance.now() - this.inputAt < YOURS_MS) this.pinned = atEnd(el) }
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

  /** After a render: pinned, stay at the end of what's there now. */
  follow() {
    const el = this.el
    if (!el || !this.pinned) return
    if (performance.now() < this.smoothUntil && typeof el.scrollTo === 'function') el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
    else el.scrollTop = el.scrollHeight
  }

  /** Placed somewhere on purpose (back from Documentation, the same session's last place). */
  placed() {
    if (this.el) this.pinned = atEnd(this.el)
  }
}
