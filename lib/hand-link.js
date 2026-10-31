/**
 * hand-link.js - 插件这边的那根"血管"。
 *
 * 原则（上次翻车之后定下的）：
 *   1. 插件**永远不 spawn 进程**。手是小夏自己在终端里起的，它主动来连。
 *   2. 手没起来 / 断线 / 崩了，这里只是 "not connected"，DSH 本体完全不受影响。
 *   3. 这条链路只在 /game 之后才被用到；正常对话里它连监听都不会开。
 *
 * 协议：一行一个 JSON
 *   手 -> 插件  {"hello":true,"pid":123}
 *   插件 -> 手  {"id":1,"cmd":"run","args":{...}}
 *   手 -> 插件  {"id":1,"ok":true,"data":{...}} / {"id":1,"ok":false,"error":"..."}
 */

import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { readFile } from 'node:fs/promises'

export const PIPE_NAME = 'dsh-game-player'
const PIPE_PATH = `\\\\.\\pipe\\${PIPE_NAME}`

/** 手把名片写在它自己的 TEMP 里；Host 进程的 TEMP 未必和它一样，所以几个地方都找一下。 */
function candidateCards() {
  const home = os.homedir()
  const names = ['hand.json']
  const dirs = new Set()
  dirs.add(path.join(os.tmpdir(), 'dsh-game-player'))
  dirs.add(path.join(home, 'AppData', 'Local', 'Temp', 'dsh-game-player'))
  if (process.env.TEMP) dirs.add(path.join(process.env.TEMP, 'dsh-game-player'))
  if (process.env.TMP) dirs.add(path.join(process.env.TMP, 'dsh-game-player'))
  const out = []
  for (const dir of dirs) for (const name of names) out.push(path.join(dir, name))
  return out
}

/**
 * 读"手"留的名片。返回 {pid, pipe, startedAt, path} 或 null。
 * 多个位置都有时取 startedAt 最新的那个（手重启过就会这样）。
 */
export async function readHandCard() {
  let best = null
  for (const file of candidateCards()) {
    try {
      const raw = await readFile(file, 'utf8')
      const card = JSON.parse(raw.replace(/^\uFEFF/, ''))
      if (!card?.pid) continue
      const at = Date.parse(card.startedAt ?? '') || 0
      if (!best || at > best.at) best = { ...card, path: file, at }
    } catch { /* 没有就没有 */ }
  }
  if (!best) return null
  return { pid: Number(best.pid), pipe: best.pipe ?? PIPE_NAME, startedAt: best.startedAt, path: best.path, mode: best.mode }
}

/** 进程还在不在（signal 0 只探测，不发信号）。 */
export function isPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return error?.code === 'EPERM'
  }
}

export class HandLink {
  constructor(options = {}) {
    this.log = options.log ?? (() => {})
    this.server = null
    this.socket = null
    this.hello = null
    this.seq = 0
    this.pending = new Map()
    this.waiters = []
    this.lastError = null
  }

  /** 开始监听管道。重复调用安全。 */
  async listen() {
    if (this.server) return this
    await new Promise((resolve, reject) => {
      const server = net.createServer((socket) => this.#adopt(socket))
      server.once('error', (error) => {
        this.lastError = error.message
        reject(error)
      })
      server.listen(PIPE_PATH, () => {
        server.removeAllListeners('error')
        server.on('error', (error) => { this.lastError = error.message })
        this.server = server
        this.log(`pipe listening on ${PIPE_PATH}`)
        resolve()
      })
    })
    return this
  }

  #adopt(socket) {
    // 只保留最新的一只手：旧连接直接断开，避免两处同时发键。
    if (this.socket && this.socket !== socket) {
      try { this.socket.destroy() } catch { /* ignore */ }
    }
    this.socket = socket
    socket.setEncoding('utf8')
    this.log(`hand connected (${socket.remoteAddress ?? 'local'})`)

    let buffer = ''
    socket.on('data', (chunk) => {
      buffer += chunk
      let index
      while ((index = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, index).trim()
        buffer = buffer.slice(index + 1)
        if (line) this.#onLine(line)
      }
    })
    socket.on('close', () => {
      if (this.socket === socket) {
        this.socket = null
        this.hello = null
        this.#failAll(new Error('hand disconnected'))
        this.log('hand disconnected')
      }
    })
    socket.on('error', () => { /* close 会跟上 */ })
  }

  #onLine(line) {
    let msg
    try { msg = JSON.parse(line) } catch { return }
    if (msg.hello) {
      this.hello = { pid: msg.pid, mode: msg.mode, elevated: msg.elevated === true }
      const waiters = this.waiters
      this.waiters = []
      for (const resolve of waiters) resolve(this.hello)
      return
    }
    if (msg.id == null) return
    const entry = this.pending.get(msg.id)
    if (!entry) return
    this.pending.delete(msg.id)
    clearTimeout(entry.timer)
    if (msg.ok) entry.resolve(msg.data)
    else entry.reject(new Error(msg.error ?? 'hand error'))
  }

  #failAll(error) {
    for (const [, entry] of this.pending) {
      clearTimeout(entry.timer)
      entry.reject(error)
    }
    this.pending.clear()
  }

  /** 等手连上来（它在自己那边每 500ms 重试一次）。 */
  waitForHand(timeoutMs = 10_000) {
    if (this.hello) return Promise.resolve(this.hello)
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiters = this.waiters.filter((w) => w !== onHello)
        reject(new Error('hand did not connect in time'))
      }, timeoutMs)
      const onHello = (hello) => {
        clearTimeout(timer)
        resolve(hello)
      }
      this.waiters.push(onHello)
    })
  }

  get connected() {
    return Boolean(this.socket && this.hello)
  }

  /** 发一条命令，等回包。 */
  request(cmd, args = {}, { timeoutMs = 120_000 } = {}) {
    if (!this.socket) return Promise.reject(new Error('hand is not connected'))
    const id = ++this.seq
    const payload = `${JSON.stringify({ id, cmd, args })}\n`
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`hand command '${cmd}' timed out after ${timeoutMs}ms`))
      }, timeoutMs)
      this.pending.set(id, { resolve, reject, timer })
      this.socket.write(payload, (error) => {
        if (!error) return
        this.pending.delete(id)
        clearTimeout(timer)
        reject(error)
      })
    })
  }

  async close() {
    try { this.socket?.destroy() } catch { /* ignore */ }
    this.socket = null
    this.hello = null
    if (this.server) {
      const server = this.server
      this.server = null
      await new Promise((resolve) => server.close(() => resolve()))
    }
  }
}
