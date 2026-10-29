import { useEffect, useRef } from 'react'

// The home screen's backdrop: a dark pond seen at an angle. Drops land now and then and ring
// out in perspective, lily pads drift and bob on the swell, fireflies wander and pulse above
// the water, and reeds bend in a gusty wind. One canvas, drawn in the theme's frog green at low
// alpha so it stays mood, not content. It pauses while the tab is hidden, follows the pointer a
// little (a ripple where you click), and draws a single still frame for prefers-reduced-motion.

type Ring = { x: number; y: number; t: number; life: number; size: number }
type Pad = { x: number; y: number; r: number; a: number; spin: number; vx: number; phase: number; notch: number }
type Fly = { x: number; y: number; vx: number; vy: number; phase: number; speed: number }
type Reed = { x: number; h: number; lean: number; w: number; phase: number; head: boolean }

const rand = (a: number, b: number) => a + Math.random() * (b - a)

function rgb(color: string): [number, number, number] {
  const m = color.trim().match(/^#([0-9a-f]{6})$/i)
  if (m) { const n = parseInt(m[1], 16); return [n >> 16, (n >> 8) & 255, n & 255] }
  const r = color.match(/\d+(\.\d+)?/g)
  return r ? [Number(r[0]), Number(r[1]), Number(r[2])] : [88, 204, 111]
}

export function Pond() {
  const ref = useRef<HTMLCanvasElement>(null)
  useEffect(() => {
    const canvas = ref.current
    const ctx = canvas?.getContext('2d')
    if (!canvas || !ctx) return
    const still = matchMedia('(prefers-reduced-motion: reduce)').matches
    let w = 0, h = 0, dpr = 1, horizon = 0
    let green: [number, number, number] = [88, 204, 111]
    let rings: Ring[] = [], pads: Pad[] = [], flies: Fly[] = [], reeds: Reed[] = []
    let raf = 0, last = performance.now(), clock = 0, nextDrop = 0.6

    const theme = () => { green = rgb(getComputedStyle(canvas).getPropertyValue('--frog') || '#58cc6f') }
    const c = (a: number) => `rgba(${green[0]},${green[1]},${green[2]},${a})`
    // The pond is a plane seen from above at a slant: things squash toward the horizon.
    const depth = (y: number) => Math.max(0.15, (y - horizon) / (h - horizon))

    const seed = () => {
      const area = w * h
      pads = Array.from({ length: Math.round(Math.min(7, Math.max(3, area / 140000))) }, () => {
        const y = rand(horizon + (h - horizon) * 0.25, h * 0.98)
        return { x: rand(0, w), y, r: rand(18, 38), a: rand(0, Math.PI * 2), spin: rand(-0.02, 0.02), vx: rand(2, 6), phase: rand(0, 9), notch: rand(0.35, 0.6) }
      })
      flies = Array.from({ length: Math.round(Math.min(18, Math.max(8, w / 70))) }, () => ({
        x: rand(0, w), y: rand(h * 0.15, h * 0.85), vx: rand(-8, 8), vy: rand(-5, 5), phase: rand(0, 9), speed: rand(0.6, 1.4),
      }))
      reeds = []
      for (const side of [0, 1]) {
        const n = Math.max(5, Math.round(w / 160))
        for (let i = 0; i < n; i++) {
          const x = side ? w - rand(0, w * 0.14) : rand(0, w * 0.14)
          reeds.push({ x, h: rand(h * 0.16, h * 0.42), lean: (side ? -1 : 1) * rand(0.02, 0.12), w: rand(1, 2.2), phase: rand(0, 9), head: Math.random() < 0.45 })
        }
      }
      rings = []
    }

    const resize = () => {
      const r = canvas.getBoundingClientRect()
      dpr = Math.min(2, devicePixelRatio || 1)
      w = r.width; h = r.height; horizon = h * 0.34
      canvas.width = Math.round(w * dpr); canvas.height = Math.round(h * dpr)
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      theme(); seed()
      if (still) { for (let i = 0; i < 4; i++) drop(rand(w * 0.2, w * 0.8), rand(horizon + 40, h * 0.9), rand(0.2, 0.7)); draw(0) }
    }

    const drop = (x: number, y: number, t = 0) => rings.push({ x, y, t, life: rand(4.5, 7), size: rand(90, 190) })

    // Gusty wind from layered sines: calm stretches, then a lean.
    const wind = (t: number, x: number) => Math.sin(t * 0.5 + x * 0.004) * 0.6 + Math.sin(t * 1.7 + x * 0.01) * 0.25 + Math.max(0, Math.sin(t * 0.13)) ** 3 * 1.2

    const draw = (dt: number) => {
      clock += dt
      ctx.clearRect(0, 0, w, h)

      // Faint glints on the surface, like starlight on still water.
      for (let i = 0; i < 26; i++) {
        const gy = horizon + ((i * 97) % 100) / 100 * (h - horizon)
        const gx = ((i * 233 + clock * (6 + (i % 5))) % (w + 120)) - 60
        const len = 10 + depth(gy) * 46
        const a = 0.03 + 0.05 * (0.5 + 0.5 * Math.sin(clock * 0.8 + i))
        ctx.strokeStyle = c(a); ctx.lineWidth = 1
        ctx.beginPath(); ctx.moveTo(gx, gy); ctx.lineTo(gx + len, gy); ctx.stroke()
      }

      // Ripples: three rings per drop, ellipses flattened by depth, fading as they spread.
      if (!still) {
        nextDrop -= dt
        if (nextDrop <= 0) { drop(rand(w * 0.08, w * 0.92), rand(horizon + 20, h * 0.96)); nextDrop = rand(1.2, 3.4) }
      }
      rings = rings.filter((r) => (r.t += dt / r.life) < 1)
      for (const r of rings) {
        const d = depth(r.y)
        for (let k = 0; k < 3; k++) {
          const p = r.t - k * 0.09
          if (p <= 0) continue
          const e = 1 - (1 - p) ** 3
          const rx = e * r.size * d * 1.6
          const a = (1 - p) ** 1.6 * 0.32 * (1 - k * 0.28)
          ctx.strokeStyle = c(a); ctx.lineWidth = Math.max(0.6, 1.3 * d)
          ctx.beginPath(); ctx.ellipse(r.x, r.y, rx, rx * 0.28, 0, 0, Math.PI * 2); ctx.stroke()
        }
      }

      // Lily pads: drift sideways, bob, and get nudged by passing rings.
      for (const p of pads) {
        if (!still) { p.x += p.vx * dt; p.a += p.spin * dt; if (p.x - p.r * 2 > w) p.x = -p.r * 2 }
        let push = 0
        for (const r of rings) {
          const rx = (1 - (1 - r.t) ** 3) * r.size * depth(r.y) * 1.6
          const dist = Math.hypot((p.x - r.x) / 1, (p.y - r.y) / 0.28)
          if (Math.abs(dist - rx) < 14) push += (1 - r.t) * 1.2
        }
        const d = depth(p.y)
        const bob = Math.sin(clock * 0.9 + p.phase) * 1.2 * d - push
        const rx = p.r * d * 1.5, ry = rx * 0.34
        ctx.save(); ctx.translate(p.x, p.y + bob)
        ctx.fillStyle = c(0.07 + 0.05 * d); ctx.strokeStyle = c(0.16 + 0.1 * d); ctx.lineWidth = 1
        ctx.beginPath()
        ctx.ellipse(0, 0, rx, ry, 0, p.a + p.notch / 2, p.a + Math.PI * 2 - p.notch / 2)
        ctx.lineTo(0, 0); ctx.closePath(); ctx.fill(); ctx.stroke()
        // Veins.
        ctx.strokeStyle = c(0.06 + 0.06 * d)
        for (let v = 1; v < 6; v++) {
          const ang = p.a + p.notch / 2 + v * (Math.PI * 2 - p.notch) / 6
          ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(Math.cos(ang) * rx * 0.85, Math.sin(ang) * ry * 0.85); ctx.stroke()
        }
        ctx.restore()
      }

      // Reeds: tapered quadratic stalks bending with the wind, cattail heads on some.
      for (const r of reeds) {
        const bend = (r.lean + wind(clock, r.x) * 0.06 + Math.sin(clock * 1.3 + r.phase) * 0.015) * r.h
        const tipX = r.x + bend, tipY = h - r.h
        ctx.strokeStyle = c(0.12); ctx.lineCap = 'round'
        for (let s = 0; s < 3; s++) {
          ctx.lineWidth = r.w * (1 - s * 0.3)
          const t0 = s / 3, t1 = (s + 1) / 3
          const at = (t: number) => {
            const mx = r.x + bend * 0.2, my = h - r.h * 0.5
            const u = 1 - t
            return [u * u * r.x + 2 * u * t * mx + t * t * tipX, u * u * h + 2 * u * t * my + t * t * tipY]
          }
          const [ax, ay] = at(t0), [bx, by] = at(t1)
          ctx.beginPath(); ctx.moveTo(ax, ay); ctx.lineTo(bx, by); ctx.stroke()
        }
        if (r.head) {
          const ang = Math.atan2(tipX - (r.x + bend * 0.2), (h - r.h * 0.5) - tipY)
          ctx.save(); ctx.translate(tipX, tipY + 10); ctx.rotate(ang)
          ctx.fillStyle = c(0.14)
          ctx.beginPath(); ctx.ellipse(0, 0, 2.6, 9, 0, 0, Math.PI * 2); ctx.fill()
          ctx.restore()
        }
      }

      // Fireflies: wander on smooth noise, pulse slowly, glow.
      for (const f of flies) {
        if (!still) {
          f.vx += Math.sin(clock * 0.7 * f.speed + f.phase) * 6 * dt
          f.vy += Math.cos(clock * 0.5 * f.speed + f.phase * 1.3) * 4 * dt
          f.vx *= 0.995; f.vy *= 0.995
          f.x += f.vx * dt; f.y += f.vy * dt
          if (f.x < -20) f.x = w + 20; if (f.x > w + 20) f.x = -20
          if (f.y < h * 0.08 || f.y > h * 0.92) f.vy *= -1
        }
        const pulse = Math.max(0, Math.sin(clock * f.speed * 1.4 + f.phase)) ** 2
        const a = 0.08 + pulse * 0.5
        const g = ctx.createRadialGradient(f.x, f.y, 0, f.x, f.y, 10 + pulse * 8)
        g.addColorStop(0, c(a)); g.addColorStop(0.25, c(a * 0.35)); g.addColorStop(1, c(0))
        ctx.fillStyle = g
        ctx.beginPath(); ctx.arc(f.x, f.y, 10 + pulse * 8, 0, Math.PI * 2); ctx.fill()
        ctx.fillStyle = c(Math.min(0.9, a * 1.6))
        ctx.beginPath(); ctx.arc(f.x, f.y, 1.1, 0, Math.PI * 2); ctx.fill()
      }
    }

    const tick = (now: number) => {
      const dt = Math.min(0.05, (now - last) / 1000); last = now
      draw(dt)
      raf = requestAnimationFrame(tick)
    }
    const vis = () => { cancelAnimationFrame(raf); if (!document.hidden && !still) { last = performance.now(); raf = requestAnimationFrame(tick) } }
    // A ripple where you click on open water.
    const host = canvas.parentElement
    const click = (e: PointerEvent) => {
      if ((e.target as HTMLElement).closest('button, a, input, textarea, li')) return
      const r = canvas.getBoundingClientRect()
      const y = e.clientY - r.top
      if (y > horizon) drop(e.clientX - r.left, y)
    }
    const ro = new ResizeObserver(resize)
    ro.observe(canvas)
    const scheme = matchMedia('(prefers-color-scheme: dark)')
    scheme.addEventListener('change', theme)
    document.addEventListener('visibilitychange', vis)
    host?.addEventListener('pointerdown', click)
    resize(); vis()
    return () => { cancelAnimationFrame(raf); ro.disconnect(); scheme.removeEventListener('change', theme); document.removeEventListener('visibilitychange', vis); host?.removeEventListener('pointerdown', click) }
  }, [])
  return <canvas ref={ref} className="pond" aria-hidden="true" />
}

const STEPS = [
  { n: '1', title: 'Ask', text: 'Describe a change, a bug or a question. Pick a GitHub repo, or none to just talk.' },
  { n: '2', title: 'Frog works in a sandbox', text: 'It clones the repo into its own cloud machine, reads, edits and runs tests. Watch every step, or leave.' },
  { n: '3', title: 'Review and ship', text: 'See the diff, open a terminal, then commit or open a PR. You pay only for the tokens used.' },
]

export function HowItWorks() {
  return (
    <ol className="how">
      {STEPS.map((s) => (
        <li key={s.n}>
          <span className="how-n">{s.n}</span>
          <b>{s.title}</b>
          <span>{s.text}</span>
        </li>
      ))}
    </ol>
  )
}
