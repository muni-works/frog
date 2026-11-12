import assert from 'node:assert/strict'
import { test } from 'node:test'
import { displayName, machineModels, memoryLine, places, runningLine, tag, type Machine } from '../src/machines'

const mac: Machine = { id: 'this-mac', name: 'studio', thisMac: true, hardware: 'M4 Max · 64 GB unified', online: true, model: null, totalBytes: 64 * 2 ** 30, freeBytes: 40 * 2 ** 30,
  models: [{ id: 'mlx-community/Qwen3-8B-4bit', name: 'Qwen3-8B-4bit', hash: 'aaaaaaaaaaaa11', loaded: false }] }
const mew: Machine = { id: 'n1', name: 'mew', hardware: 'RTX 3090 · 24 GB VRAM', online: true, model: 'Qwen3-4B', decode: 58.4, totalBytes: 24 * 2 ** 30, freeBytes: 6 * 2 ** 30,
  models: [
    { id: 'Qwen/Qwen3-4B', name: 'Qwen3-4B', hash: 'bbbbbbbbbbbb22', loaded: true },
    { id: 'mlx-community/Qwen3-8B-4bit', name: 'Qwen3-8B-4bit', hash: 'aaaaaaaaaaaa11', loaded: false },
  ] }

test('one row per model, listing every machine that holds it, running first', () => {
  const rows = machineModels([mac, mew])
  assert.deepEqual(rows.map((r) => r.spec), ['node/bbbbbbbbbbbb', 'node/aaaaaaaaaaaa'])
  assert.equal(tag(rows[0]), null)
  assert.equal(places(rows[1]), 'This Mac, mew')
  // Idle This Mac loads it; mew would swap: loads wins.
  assert.equal(tag(rows[1]), 'loads')
  assert.equal(tag(machineModels([mew])[1]), 'swaps')
})

test('offline machines offer nothing', () => {
  assert.deepEqual(machineModels([{ ...mew, online: false }]), [])
})

test('lines speak tok/s and memory', () => {
  assert.equal(runningLine(mew), 'Qwen3-4B · 58 tok/s')
  assert.equal(runningLine(mac), 'idle')
  assert.equal(runningLine({ ...mew, online: false }), 'offline')
  assert.equal(memoryLine(mew), '18 GB of 24 GB used')
  assert.equal(displayName('mlx-community/Qwen3-8B-MLX-4bit'), 'Qwen3-8B')
})
