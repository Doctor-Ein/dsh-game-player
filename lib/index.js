/**
 * index.js - dsh-game-player 宿主入口。
 *
 * 两个入口，共用同一套连接逻辑：
 *   /game 命令        —— 桌面端敲斜杠命令（QQ 那条链路不走命令路由，用不了）
 *   game_attach 工具  —— 模型自己调，任何通道都行（QQ / 桌面）
 *
 * 两者的目标一致：把「手」接上，并把 game_shot / game_do / game_stop
 * 挂到**当前这个会话**上（不新建会话）——小夏的习惯是先在会话里讲任务，
 * 再开打，然后一直在这儿指导。
 *
 * 教训：apply() 里只做注册。不 spawn 进程、不读写文件、不 await。
 */

import { appendFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { HandLink, readHandCard, isPidAlive } from './hand-link.js'
import { buildGameTools } from './tools.js'

export const name = 'dsh-game-player'
export const inject = ['commands', 'tools', 'attachments']

/** 找游戏窗口用的标题片段；可以在 /game 后面或调用工具时覆盖。 */
const DEFAULT_WINDOW = '绝区零'
const ATTACH_TOOL = 'game_attach'

const LOG_FILE = path.join(path.dirname(path.dirname(fileURLToPath(import.meta.url))), 'game-player.log')
async function log(line) {
  try {
    await appendFile(LOG_FILE, `${new Date().toISOString()} ${line}\n`, 'utf8')
  } catch { /* 日志失败不影响正事 */ }
}

function ok(text) {
  return { kind: 'success', text }
}

function fail(text) {
  return { kind: 'error', text }
}

export function apply(ctx) {
  const link = new HandLink()
  const state = {
    hwnd: null,
    title: '',
    clientRect: null,
    armed: false,
    blocks: 0,
    /** 注册到会话里的那几个工具的 disposer；重复连接或插件卸载时摘掉。 */
    activeTools: [],
  }

  /**
   * 接上手 + 绑定窗口 + 把工具挂到 targetCtx。
   * 返回一段给人看的文本（成功/失败都由调用方决定怎么呈现）。
   */
  async function connect({ wanted, targetCtx, agentId }) {
    const card = await readHandCard()
    if (!card) {
      return { error: '没找到「手」。先双击 start-gameplay.cmd（会弹 UAC，点"是"），让它停在等待界面。' }
    }
    if (!isPidAlive(card.pid)) {
      return { error: `名片里的进程 ${card.pid} 已经不在了（窗口被关了？）。重新双击 start-gameplay.cmd。` }
    }

    try {
      await link.listen()
    } catch (error) {
      const hint = /EADDRINUSE/i.test(error.message)
        ? '（管道被另一个实例占着：把 DSH 里的插件关掉再打开一次，或重启应用）'
        : ''
      return { error: `管道监听失败：${error.message}${hint}` }
    }

    let hello = null
    try {
      hello = await link.waitForHand(10_000)
    } catch {
      return { error: `手（pid ${card.pid}）在 10 秒内没有连上来。看看那个窗口是不是退出了。` }
    }

    try {
      const { windows } = await link.request('windows', { filter: wanted })
      const list = Array.isArray(windows) ? windows : []
      const picked = list.find((w) => w.title === wanted) ?? list[0]
      if (!picked) {
        const names = list.map((w) => `  - ${w.title}`).join('\n') || '  (无)'
        return { error: `没找到标题含「${wanted}」的窗口。当前可见窗口：\n${names}` }
      }
      const info = await link.request('window', { hwnd: picked.hwnd })
      state.hwnd = info.hwnd
      state.title = info.title
      state.clientRect = { x: info.clientX, y: info.clientY, w: info.clientW, h: info.clientH }
      state.armed = true
      state.blocks = 0
    } catch (error) {
      return { error: `绑定窗口失败：${error.message}` }
    }

    if (!targetCtx?.tools) {
      state.armed = false
      await log('no target ctx; tools NOT attached')
      return { error: '手接上了，但拿不到当前会话的上下文，工具挂不上去。' }
    }

    // 重复连接时先摘掉上一批，避免同名注册冲突
    for (const d of state.activeTools.splice(0)) {
      try { d?.() } catch { /* ignore */ }
    }
    for (const tool of buildGameTools({ ctx: targetCtx, attachCtx: ctx, link, state })) {
      state.activeTools.push(targetCtx.tools.register(tool))
    }
    await log(`tools attached to ${agentId ?? 'unknown'} (${state.activeTools.length}), window=${state.title}`)

    return {
      text: [
        `手已接上：pid ${hello?.pid ?? card.pid}，窗口「${state.title}」${state.clientRect.w}x${state.clientRect.h}`,
        hello?.elevated === true
          ? '权限：管理员 ✓（键鼠能进游戏）'
          : '权限：**没有管理员** —— 按键会被 Windows 静默丢弃。关掉手，用会弹 UAC 的启动器重开。',
        '工具已挂到本会话：game_shot / game_do / game_stop。直接说要干什么。',
        '紧急情况按 F12。',
      ].join('\n'),
    }
  }

  // ------------------------------------------------------------------ 入口 1：/game
  const disposeCommand = ctx.commands.register({
    name: 'game',
    description: '连接已在终端启动的「手」(game-hand)，把游戏工具挂到当前会话，直接开始玩。',
    input: { hint: '可选：窗口标题片段（默认 绝区零）' },
    handler: async (invocation) => {
      const wanted = String(invocation.rawInput ?? '').trim() || DEFAULT_WINDOW
      const agents = ctx.get('agents')
      const live = agents?.get?.(invocation.agent?.id) ?? invocation.agent
      const result = await connect({
        wanted,
        targetCtx: live?.ctx ?? invocation.agent?.ctx,
        agentId: invocation.agent?.id,
      })
      return result.error ? fail(result.error) : ok(result.text)
    },
  })

  // ------------------------------------------------------------------ 入口 2：工具
  // 给 QQ 这类不走命令路由的通道用：模型自己调用它。
  const disposeTool = ctx.tools.register({
    name: ATTACH_TOOL,
    description:
      '把手（game-hand，负责截图与键鼠）接到当前会话，之后就能用 game_shot / game_do / game_stop。'
      + '只在小夏要求开游戏模式时调用一次；普通聊天不要碰它。',
    parameters: {
      type: 'object',
      properties: {
        window: {
          type: 'string',
          description: `可选：目标窗口标题片段，默认 ${DEFAULT_WINDOW}。`,
        },
      },
      required: [],
      additionalProperties: false,
    },
    output: {
      schema: {
        type: 'object',
        properties: { text: { type: 'string' } },
        required: ['text'],
        additionalProperties: false,
      },
      render(_args, value) {
        return [{ type: 'text', text: String(value?.text ?? '') }]
      },
    },
    isConcurrencySafe: () => false,
    timeoutMs: 60_000,
    async execute(args) {
      const wanted = String(args?.window ?? '').trim() || DEFAULT_WINDOW
      const agents = ctx.get('agents')
      const me = agents?.currentInitiator?.()
      if (!me) {
        return { text: '拿不到当前会话（currentInitiator 为空），没法把工具挂上去。' }
      }
      const live = agents?.get?.(me.id) ?? me
      const result = await connect({ wanted, targetCtx: live?.ctx ?? me.ctx, agentId: me.id })
      return { text: result.error ?? result.text }
    },
  })

  return async () => {
    disposeCommand?.()
    disposeTool?.()
    for (const d of state.activeTools.splice(0)) {
      try { d?.() } catch { /* ignore */ }
    }
    await link.close()
  }
}
