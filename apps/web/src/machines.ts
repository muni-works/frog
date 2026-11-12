import { useEffect, useState, useSyncExternalStore } from 'react'
import { API } from './auth'

// Your machines: every node, This Mac included, running one model (docs/plans/
// 2026-11-12-model-picker-and-downloads.md §1–2). The Mac app reads them from each node's
// `/node`; the web app is cloud-only, so it lists them only when the account's gateway reports
// them (`/v1/machines`), and shows none otherwise. Mirrors the Mac's `Devices.machineModels`.

export interface MachineModelOnDisk { id: string; name: string; hash: string; loaded: boolean; quant?: string | null }
export interface Machine {
  id: string
  name: string
  thisMac?: boolean
  hardware: string
  online: boolean
  /** The running model's name, and its measured decode speed. */
  model?: string | null
  decode?: number | null
  totalBytes: number
  freeBytes?: number | null
  models: MachineModelOnDisk[]
}

export type Action = 'running' | 'swaps' | 'loads'
export interface Hold { machine: string; name: string; action: Action }
export interface MachineModel { spec: string; name: string; holds: Hold[] }

/** "Qwen3-8B-MLX-4bit" → "Qwen3-8B": the quant lives on the machine page, not the pill. */
export function displayName(s: string) {
  let n = s.split('/').pop() ?? s
  for (const tail of ['-MLX-4bit', '-MLX-8bit', '-4bit', '-8bit', '-bf16', '-MLX']) if (n.endsWith(tail)) n = n.slice(0, -tail.length)
  return n
}

/** One row per model (by weights hash), each listing the machines that hold it and what picking
 *  it does there: nothing (running), swaps (the machine runs another), loads (it's idle). */
export function machineModels(machines: Machine[]): MachineModel[] {
  const rows = new Map<string, MachineModel>()
  for (const d of machines) {
    if (!d.online) continue
    for (const m of d.models) {
      const key = m.hash.slice(0, 12)
      if (!key) continue
      const action: Action = m.loaded ? 'running' : d.model ? 'swaps' : 'loads'
      const row = rows.get(key) ?? { spec: `node/${key}`, name: displayName(m.name), holds: [] }
      row.holds.push({ machine: d.id, name: d.thisMac ? 'This Mac' : d.name, action })
      rows.set(key, row)
    }
  }
  return [...rows.values()].sort((a, b) => Number(running(b)) - Number(running(a)) || a.name.localeCompare(b.name))
}

export const running = (m: MachineModel) => m.holds.some((h) => h.action === 'running')

/** What picking it does, when nothing runs it yet: "loads" beats "swaps". */
export const tag = (m: MachineModel) => (running(m) ? null : m.holds.some((h) => h.action === 'loads') ? 'loads' : 'swaps')

/** "mew, This Mac": where it is, running ones first. */
export const places = (m: MachineModel) =>
  [...m.holds].sort((a, b) => Number(b.action === 'running') - Number(a.action === 'running')).map((h) => h.name).join(', ')

/** "Qwen3-8B · 58 tok/s", "idle", "offline". */
export function runningLine(d: Machine) {
  if (!d.online) return d.thisMac ? 'not running' : 'offline'
  if (!d.model) return 'idle'
  return [displayName(d.model), d.decode ? `${Math.round(d.decode)} tok/s` : null].filter(Boolean).join(' · ')
}

export const gb = (b: number) => { const g = b / 1_073_741_824; return g >= 10 ? `${Math.round(g)} GB` : `${g.toFixed(1)} GB` }

/** "18 GB of 24 GB used". */
export const memoryLine = (d: Machine) => (d.freeBytes == null ? gb(d.totalBytes) : `${gb(d.totalBytes - Math.min(d.freeBytes, d.totalBytes))} of ${gb(d.totalBytes)} used`)

/** "Download a model" and Delete stay hidden until tang ships `/models/pull` and `/models/delete`. */
export const canPull = () => { try { return localStorage.getItem('frogModelPull') === '1' } catch { return false } }

export function useMachines(key: string | null) {
  const [machines, setMachines] = useState<Machine[]>([])
  useEffect(() => {
    if (!key) { setMachines([]); return }
    let live = true
    fetch(`${API}/v1/machines`, { headers: { authorization: `Bearer ${key}` } })
      .then((r) => (r.ok ? r.json() : { data: [] }))
      .then((v: { data?: Machine[] }) => live && setMachines(v.data ?? []))
      .catch(() => live && setMachines([]))
    return () => { live = false }
  }, [key])
  return machines
}

// "Show cloud models in the picker" (Settings › Models), shared by every picker on the page.
const SHOW_CLOUD = 'showCloudModels'
const listeners = new Set<() => void>()
export const showCloud = () => { try { return localStorage.getItem(SHOW_CLOUD) !== 'off' } catch { return true } }
export function setShowCloud(on: boolean) {
  try { localStorage.setItem(SHOW_CLOUD, on ? 'on' : 'off') } catch { /* private mode */ }
  listeners.forEach((l) => l())
}
export const useShowCloud = () => useSyncExternalStore((l) => { listeners.add(l); return () => listeners.delete(l) }, showCloud, () => true)
