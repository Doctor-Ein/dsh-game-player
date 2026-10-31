/**
 * tools.js - 只给"游戏会话"用的三个工具。普通会话里根本不存在。
 *
 * 为什么只有三个：上一个版本一次注册 7 个，任何一处 schema 不合规都让整行 fiber 起不来。
 *   game_shot  看（一帧）
 *   game_do    做 + 看（一段动作块，回一张编号宫格）
 *   game_stop  松手
 */

import { readFile } from 'node:fs/promises'

/** 一个 {x,y,w,h} 区域。宿主注册时接受 type:'json'，但转成模型的 function schema 时不接受，
 *  会报 `"json" is not valid under any of the schemas listed in the 'anyOf' keyword`。
 *  所以老老实实写成对象。 */
const REGION_SCHEMA = {
  type: 'object',
  description: 'Optional region inside the window client area, in pixels: {x, y, w, h}.',
  properties: {
    x: { type: 'number' },
    y: { type: 'number' },
    w: { type: 'number' },
    h: { type: 'number' },
  },
  additionalProperties: false,
}

const LIMITS = {
  maxSteps: 60,
  maxFrames: 12,
  defaultEvery: 1000,
  minEvery: 150,
}

function clamp(value, min, max, fallback) {
  const n = Number(value)
  if (!Number.isFinite(n)) return fallback
  return Math.min(max, Math.max(min, n))
}

const IMAGE_OUTPUT = {
  schema: {
    type: 'object',
    properties: {
      text: { type: 'string' },
      images: { type: 'array', items: { type: 'object' } },
    },
    required: ['text'],
    additionalProperties: false,
  },
  render(_args, value) {
    const images = (value?.images ?? []).map((attachment) => ({ type: 'image', attachment }))
    return [...images, { type: 'text', text: String(value?.text ?? '') }]
  },
}

async function attachPng(ctx, file, name) {
  const data = await readFile(file)
  return ctx.attachments.saveImage({ data, mediaType: 'image/png', name })
}

export function buildGameTools({ ctx, attachCtx, link, state }) {
  /** 附件服务在插件自己的 ctx 上；会话 ctx 没有注入 attachments。 */
  const hostCtx = attachCtx ?? ctx

  /** 客户端区域 -> 屏幕坐标（手只认屏幕坐标）。 */
  function screenRect(region, scale) {
    const base = state.clientRect
    if (!base) throw new Error('no bound window: run /game again')
    const r = region ?? {}
    const x = base.x + Math.max(0, Math.round(r.x ?? 0))
    const y = base.y + Math.max(0, Math.round(r.y ?? 0))
    const w = Math.max(8, Math.min(Math.round(r.w ?? base.w), base.w))
    const h = Math.max(8, Math.min(Math.round(r.h ?? base.h), base.h))
    return { x, y, w, h, scale: scale ?? 0.5 }
  }

  return [
    {
      name: 'game_shot',
      description:
        'Look at the bound game window: one screenshot (optionally a sub-region). '
        + 'Use it to read menus or confirm which screen you are on. For anything that moves use game_do.',
      parameters: {
        type: 'object',
        properties: {
          region: REGION_SCHEMA,
          scale: { type: 'number', description: 'Downscale 0.2-1 (default 0.5).' },
        },
        required: [],
        additionalProperties: false,
      },
      output: IMAGE_OUTPUT,
      isConcurrencySafe: () => false,
      timeoutMs: 60_000,
      async execute(args) {
        const scale = clamp(args?.scale, 0.2, 1, 0.5)
        const rect = screenRect(args?.region, scale)
        const shot = await link.request('cap', rect)
        const attachment = await attachPng(hostCtx, shot.path, 'game-shot.png')
        return {
          images: [attachment],
          text: `screenshot ${shot.w}x${shot.h} of ${state.title} (client ${state.clientRect.w}x${state.clientRect.h})`,
        }
      },
    },

    {
      name: 'game_do',
      description:
        'Run a short block of real keyboard/mouse actions and sample frames while doing it, returning one '
        + 'numbered contact sheet. Main tool: the hand presses keys at game speed while you wait, then you see '
        + 'what those few seconds did.\n'
        + 'Steps: {"t":"key","k":"w","a":"tap|down|up","ms":80,"repeat":3,"gap":60} | '
        + '{"t":"mouse","a":"click|down|up|rel|abs|wheel","btn":"left","dx":0,"dy":0,"x":0,"y":0} | '
        + '{"t":"wait","ms":300} | {"t":"look"} | '
        + '{"t":"waitfor","probe":"qte","timeoutMs":1200,"then":{"t":"mouse","a":"click","btn":"left"}}.\n'
        + 'waitfor is the reflex step: the hand polls the screen LOCALLY (every ~40ms) and fires `then` the moment '
        + 'the signal appears, or skips silently on timeout. Use it for QTEs and any "wait until it lights up" '
        + 'moment — never try to catch those with a model round-trip. `then` may be one step or an array; '
        + 'it supports key/mouse (with "repeat" for multi-click)/wait/look.\n'
        + 'Known probes: "qte_counterattack" (counter QTE: fixed 26-point cyan pattern, fire RIGHT), "qte_flag" (active/skill QTE: 12 ring + 9 fist-outline points, fire LEFT). Pass a "probes" array on one waitfor to watch several probes IN PARALLEL (each with its own gapMs and then); "holdMs" turns waitfor into a guard. You can also pass an inline '
        + 'probe object: {"region":{"x":0.55,"y":0.02,"w":0.32,"h":0.30},"color":"cyan","minPixels":120,"stride":5}, '
        + 'where region is in fractions of the window client area.\n'
        + 'Keep a block to a few seconds. Avoid long identical key holds: keep it looking human.',
      parameters: {
        type: 'object',
        properties: {
          steps: { type: 'array', items: { type: 'object' }, description: 'At most 60 steps.' },
          capture: { type: 'boolean', description: 'Sample frames while acting (default true).' },
          every: { type: 'integer', description: 'Milliseconds between frames (default 1000, min 150).' },
          maxFrames: { type: 'integer', description: 'Frames per block, 1-12 (default 6).' },
          scale: { type: 'number', description: 'Downscale for sampled frames (default 0.5).' },
          region: REGION_SCHEMA,
        },
        required: ['steps'],
        additionalProperties: false,
      },
      output: IMAGE_OUTPUT,
      isConcurrencySafe: () => false,
      timeoutMs: 180_000,
      async execute(args) {
        const steps = Array.isArray(args?.steps) ? args.steps : []
        if (!steps.length) throw new Error('steps must be a non-empty array')
        if (steps.length > LIMITS.maxSteps) throw new Error(`too many steps (${steps.length} > ${LIMITS.maxSteps})`)

        const wantCapture = args?.capture !== false
        const every = Math.round(clamp(args?.every, LIMITS.minEvery, 10_000, LIMITS.defaultEvery))
        const maxFrames = Math.round(clamp(args?.maxFrames, 1, LIMITS.maxFrames, 6))
        const scale = clamp(args?.scale, 0.2, 1, 0.5)
        const capture = wantCapture
          ? { ...screenRect(args?.region, scale), every, maxFrames }
          : { enabled: false }

        const result = await link.request('run', {
          actions: steps,
          capture,
          abortKey: 'F12',
          hwnd: state.hwnd,
          requireForeground: true,
        })
        state.blocks += 1

        const images = []
        const frames = result.frames ?? []
        if (frames.length === 1) {
          images.push(await attachPng(hostCtx, frames[0], 'game-do.png'))
        } else if (frames.length > 1) {
          const sheet = await link.request('sheet', {
            paths: frames,
            cols: frames.length <= 4 ? 2 : 3,
            cellW: 560,
            labels: result.labels ?? [],
          })
          images.push(await attachPng(hostCtx, sheet.path, 'game-do-sheet.png'))
        }

        const lines = [`block #${state.blocks}: ${steps.length} steps, ${result.ms} ms`
          + (result.aborted ? ' — ABORTED (kill switch)' : '')]
        if (result.labels?.length) lines.push(`frames: ${result.labels.join(' | ')}`)
        if (!frames.length) lines.push('no frames captured')

        // 把 trace 也回传：不带上它，就看不出"探针有没有命中、命中要等多久"，
        // 只能对着截图瞎猜。waitfor 那一条最关键（hit / waited / count）。
        const trace = Array.isArray(result.trace) ? result.trace : []
        const reflex = trace.filter((t) => t && t.t === 'waitfor')
        if (reflex.length) {
          lines.push('reflex:')
          for (const r of reflex) {
            const fires = Array.isArray(r.fires) && r.fires.length ? ` fires=[${r.fires.join(",")}]` : ''
            lines.push(`  waitfor mode=${r.mode ?? '?'} probe=${r.probe ?? '?'} hit=${r.hit} waited=${r.waited}ms count=${r.count ?? 0}${fires}`)
          }
        }
        const fired = trace.filter((t) => t && typeof t.t === 'string' && t.t.startsWith('then:'))
        if (fired.length) {
          lines.push(`fired: ${fired.map((f) => `${f.t}(${f.btn ?? f.k ?? ''}${f.repeat ? ' x' + f.repeat : ''})`).join(', ')}`)
        }
        const errs = trace.filter((t) => t && t.err)
        if (errs.length) lines.push(`errors: ${errs.map((e) => `${e.t}: ${e.err}`).join('; ')}`)
        return { images, text: lines.join('\n') }
      },
    },

    {
      name: 'game_stop',
      description: 'Release every key/button and end the play session. Use it when the stage is over or something went wrong.',
      parameters: { type: 'object', properties: {}, required: [], additionalProperties: false },
      output: IMAGE_OUTPUT,
      isConcurrencySafe: () => false,
      timeoutMs: 30_000,
      async execute() {
        try { await link.request('release', {}, { timeoutMs: 5000 }) } catch { /* 断了就算了 */ }
        state.armed = false
        return { text: 'all keys released. Type /game in a normal chat to reconnect.' }
      },
    },
  ]
}
