import assert from 'node:assert/strict'
import { test } from 'node:test'
import { catalogModel, displayName, localCatalog, localRows, machineModels, menuLocalModels, memoryLine, places, runningLine, tag, usesLine, type Machine } from '../src/machines'
import { modelName } from '../src/models'

const mac: Machine = { id: 'this-mac', name: 'studio', thisMac: true, hardware: 'M4 Max, 64 GB unified', online: true, model: null, totalBytes: 64 * 2 ** 30, freeBytes: 40 * 2 ** 30,
  models: [{ id: 'mlx-community/Qwen3-8B-4bit', name: 'Qwen3-8B-4bit', hash: 'aaaaaaaaaaaa11', loaded: false }] }
const mew: Machine = { id: 'n1', name: 'mew', hardware: 'RTX 3090, 24 GB VRAM', online: true, model: 'Qwen3-4B', decode: 58.4, totalBytes: 24 * 2 ** 30, freeBytes: 6 * 2 ** 30,
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
  assert.equal(runningLine(mew), 'Qwen3 4B, 58 tok/s')
  assert.equal(runningLine(mac), 'idle')
  assert.equal(runningLine({ ...mew, online: false }), 'offline')
  assert.equal(memoryLine(mew), '18 GB of 24 GB used')
  assert.equal(displayName('mlx-community/Qwen3-8B-MLX-4bit'), 'Qwen3 8B')
})

test('names come from the shared catalog, as on the Mac', () => {
  assert.equal(displayName('mlx-community/Qwen3-32B-4bit'), 'Qwen3 32B')
  assert.deepEqual(machineModels([mac, mew]).map((r) => r.name), ['Qwen3 4B', 'Qwen3 8B'])
  const q32 = catalogModel('mlx-community/Qwen3-32B-4bit')!
  assert.equal(usesLine(q32), 'Coding, uses tools, reasons, 32K context')
  // Frog Cloud's models carry Frog Cloud's names.
  assert.deepEqual(localCatalog.filter((m) => m.cloud).map((m) => modelName(m.cloud!)), localCatalog.filter((m) => m.cloud).map((m) => m.name))
})

test("the menu's local models are the shared catalog's, in the Mac's order", async () => {
  // Read the file itself, not the bundled import, so the web can't drift from what the Mac
  // bundles: ModelDownloads.swift's SuggestedModel.all is the same filter over the same file.
  const { readFileSync } = await import('node:fs')
  const file = JSON.parse(readFileSync(new URL('../../../catalog/local-models.json', import.meta.url), 'utf8')) as { models: { name: string; menu?: boolean; runs_on: string[] }[] }
  const mac = file.models.filter((m) => m.menu === true && m.runs_on.includes('metal')).map((m) => m.name)
  assert.ok(mac.length > 0)
  assert.deepEqual(menuLocalModels().map((m) => m.name), mac)
  assert.deepEqual(localRows([]).map((r) => r.name), mac)
  // And the Mac really does read it that way.
  const swift = readFileSync(new URL('../../macos/Frog/Model/ModelDownloads.swift', import.meta.url), 'utf8')
  assert.match(swift, /LocalCatalog\.all\.filter \{ \$0\.menu == true && \$0\.runs_on\.contains\("metal"\) \}/)
})

test('local rows say where you have a model, and keep ones the catalog does not offer', () => {
  const rows = localRows([mac, mew])
  assert.equal(rows.find((r) => r.name === 'Qwen3 8B')?.on, 'This Mac, mew')
  assert.equal(rows.find((r) => r.name === 'Qwen3 4B')?.on, 'mew')
  assert.equal(rows.find((r) => r.name === 'Qwen3 32B')?.on, null)
  const odd: Machine = { ...mew, models: [{ id: 'someone/Odd-7B', name: 'Odd-7B', hash: 'cccccccccccc33', loaded: false }] }
  assert.deepEqual(localRows([odd]).at(-1), { key: 'node/cccccccccccc', name: 'Odd 7B', on: 'mew' })
  // The same model as two builds (MLX on a Mac, bf16 on a node) is one row naming both.
  const mlx: Machine = { ...mac, models: [{ id: 'mlx-community/Qwen3-4B-4bit', name: 'Qwen3-4B-4bit', hash: 'dddddddddddd44', loaded: false }] }
  assert.equal(localRows([mlx, mew]).find((r) => r.name === 'Qwen3 4B')?.on, 'mew, This Mac')
  // Offline machines say nothing.
  assert.ok(localRows([{ ...mew, online: false }]).every((r) => r.on === null))
})
