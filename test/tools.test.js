import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile } from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { buildGameTools } from '../lib/tools.js'

async function fixture() {
  const dir = await mkdtemp(path.join(os.tmpdir(), 'dsh-tools-test-'))
  const png = path.join(dir, 'test.png')
  await writeFile(png, Buffer.from('89504e470d0a1a0a', 'hex'))
  const calls = []
  const state = { armed: true, hwnd: 42, handPid: 123, title: 'fixture', engineRevision: 'abc', blocks: 0,
    clientRect: { x: 0, y: 0, w: 1, h: 1 } } // Intentionally stale: never use this for cap/run.
  const results = {
    cap: { path: png, w: 50, h: 40, source: { x: -1900, y: -50, w: 101, h: 79 },
      scaleX: 50 / 101, scaleY: 40 / 79, shotId: 'snapshot-id', client: { x: -1900, y: -50, w: 101, h: 79 } },
    find: { mode: 'find', matches: [{ x: -1200, y: 0, w: 21, h: 15, center: { x: -1190, y: 7 }, score: 1 }] },
    run: { frames: [], ms: 10, trace: [] }, release: {},
  }
  const link = { connected: true, hello: { engineRevision: 'abc', pid: 123 },
    async request(cmd, args) { calls.push({ cmd, args }); return results[cmd] } }
  const host = { attachments: { async saveImage({ data, mediaType, name }) { return { size: data.length, mediaType, name } } } }
  const tools = Object.fromEntries(buildGameTools({ ctx: {}, attachCtx: host, link, state }).map(t => [t.name, t]))
  return { tools, link, state, calls, results }
}

test('shot sends window identity, reports signed origin and independent scale factors', async () => {
  const { tools, calls } = await fixture()
  const result = await tools.game_shot.execute({ overlay: true })
  assert.deepEqual(calls[0], { cmd: 'cap', args: { hwnd: 42, region: undefined, scale: .5, overlay: true } })
  assert.match(result.text, /101x79 physical pixels at screen \(-1900,-50\)/)
  assert.match(result.text, /X=0.495050, Y=0.506329/)
  assert.match(result.text, /shotId=snapshot-id/)
  assert.equal(result.images.length, 1)
})

test('find exposes exact centres and records against a specific immutable shot', async () => {
  const { tools, results, calls } = await fixture()
  const result = await tools.game_find.execute({ template: 'enter' })
  assert.equal(JSON.parse(result.text).matches[0].center.x, -1190)
  results.find = { mode: 'record', path: results.cap.path, w: 21, h: 15 }
  const record = { shotId: 'snapshot-id', region: { x: 20, y: 30, w: 21, h: 15 } }
  assert.equal((await tools.game_find.execute({ template: 'enter', record })).images.length, 1)
  assert.deepEqual(calls.at(-1).args.record, record)
})

test('mouse target survives the tool protocol unchanged; capture resolves current HWND in engine', async () => {
  const { tools, calls } = await fixture()
  const steps = [{ t: 'mouse', a: 'click', x: -1190, y: 7, btn: 'left' }]
  await tools.game_do.execute({ steps, region: { x: 5, y: 5, w: 20, h: 20 } })
  assert.deepEqual(calls[0].args.actions, steps)
  assert.equal(calls[0].args.capture.hwnd, 42)
  assert.equal(calls[0].args.capture.x, undefined)
  assert.equal(calls[0].args.requireForeground, true)
})

test('stop disarms every observation/input tool; failure does not claim successful release', async () => {
  const { tools, link, state, calls } = await fixture()
  link.request = async () => { throw new Error('disconnected') }
  assert.match((await tools.game_stop.execute()).text, /release was not confirmed/)
  assert.equal(state.armed, false)
  for (const name of ['game_shot', 'game_find', 'game_do']) await assert.rejects(tools[name].execute({}), /session stopped/)
  assert.equal(calls.length, 0)
})

test('disconnection or hand restart requires reattach', async () => {
  for (const change of [link => { link.connected = false }, link => { link.hello.pid = 456 }, link => { link.hello.engineRevision = 'stale' }]) {
    const { tools, link, state } = await fixture()
    change(link)
    await assert.rejects(tools.game_shot.execute({}), /disconnected or restarted/)
    assert.equal(state.armed, false)
  }
})

test('bounds reject invalid action blocks before any command', async () => {
  const { tools, calls } = await fixture()
  await assert.rejects(tools.game_do.execute({ steps: [] }), /non-empty/)
  await assert.rejects(tools.game_do.execute({ steps: Array(61).fill({ t: 'look' }) }), /too many/)
  assert.equal(calls.length, 0)
})
