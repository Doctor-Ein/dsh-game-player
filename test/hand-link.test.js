import test from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import { randomUUID } from 'node:crypto'
import { once } from 'node:events'
import { HandLink, engineRevision } from '../lib/hand-link.js'

test('revision is a byte-sensitive hash of the complete runtime manifest', async () => {
  assert.match(await engineRevision(), /^[a-f0-9]{64}$/)
})

test('pipe replacement clears stale hello and rejects pending commands; close settles requests', async (t) => {
  const pipePath = `\\\\.\\pipe\\dsh-position-test-${randomUUID()}`
  const link = new HandLink({ pipePath })
  const sockets = []
  t.after(async () => { for (const s of sockets) s.destroy(); await link.close() })
  await link.listen()
  const first = net.connect(pipePath); sockets.push(first)
  await once(first, 'connect')
  first.write(JSON.stringify({ hello: true, pid: 1, engineRevision: 'old' }) + '\n')
  assert.equal((await link.waitForHand()).pid, 1)
  const pending = assert.rejects(link.request('ping'), /connection replaced/)
  const replacement = net.connect(pipePath); sockets.push(replacement)
  await once(replacement, 'connect')
  await pending
  assert.equal(link.connected, false)
  await assert.rejects(link.request('run'), /not connected/)
  replacement.write(JSON.stringify({ hello: true, pid: 2, engineRevision: 'new', engineVersion: 2 }) + '\n')
  assert.equal((await link.waitForHand()).pid, 2)
  assert.equal(link.hello.engineVersion, 2)
  const closing = assert.rejects(link.request('ping'), /link closed/)
  await link.close()
  await closing
})
