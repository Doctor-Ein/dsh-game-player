import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'
import { once } from 'node:events'
import { engineRevision } from '../lib/hand-link.js'

test('real PowerShell 5.1 engine compiles and agrees with the host on protocol and source revision', { timeout: 15000 }, async (t) => {
  const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', fileURLToPath(new URL('./engine-stdio.ps1', import.meta.url))], { windowsHide: true })
  t.after(() => child.kill())
  let stderr = ''
  child.stderr.on('data', chunk => { stderr += chunk })
  const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]()
  const helloLine = await lines.next()
  assert.equal(helloLine.done, false, stderr)
  const hello = JSON.parse(helloLine.value)
  assert.equal(hello.engineRevision, await engineRevision())
  assert.equal(hello.engineVersion, 2)
  assert.equal(hello.coordinateSystem, 'virtual-desktop-physical')
  child.stdin.write(JSON.stringify({ id: 17, cmd: 'ping', args: {} }) + '\n')
  const pong = JSON.parse((await lines.next()).value)
  assert.equal(pong.id, 17)
  assert.equal(pong.ok, true)
  assert.equal(pong.data.engineRevision, hello.engineRevision)
  assert.ok(pong.data.desktop.w > 0 && pong.data.desktop.h > 0)
  const exit = once(child, 'exit')
  child.stdin.end()
  assert.equal((await exit)[0], 0, stderr)
})
