/**
 * tools.js - 只给游戏会话注册的工具。
 *
 * 工具使用标准 object schema，避免宿主转换 function schema 时启动失败。
 *   game_shot  看（一帧）
 *   game_find  从原图录模板 / 返回精确坐标
 *   game_do    做 + 看（一段动作块，回一张编号宫格）
 *   game_stop  松手
 */

import { readFile } from 'node:fs/promises'

/** 一个 {x,y,w,h} 区域。宿主注册时接受 type:'json'，但转成模型的 function schema 时不接受，
 *  会报 `"json" is not valid under any of the schemas listed in the 'anyOf' keyword`。
 *  所以老老实实写成对象。 */
const REGION_SCHEMA = {
  type: 'object',
  description: 'Region in window CLIENT physical pixels (not preview pixels).',
  properties: {
    x: { type: 'integer', minimum: 0 },
    y: { type: 'integer', minimum: 0 },
    w: { type: 'integer', minimum: 1 },
    h: { type: 'integer', minimum: 1 },
  },
  required: ['x', 'y', 'w', 'h'],
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

function describeShot(shot) {
  const s = shot.source
  return `source ${s.w}x${s.h} physical pixels at screen (${s.x},${s.y}); preview ${shot.w}x${shot.h}; `
    + `scale X=${shot.scaleX.toFixed(6)}, Y=${shot.scaleY.toFixed(6)}; `
    + `1 preview pixel = ${(1 / shot.scaleX).toFixed(4)}x${(1 / shot.scaleY).toFixed(4)} physical pixels. `
    + `Screen point = (${s.x} + previewX/${shot.scaleX}, ${s.y} + previewY/${shot.scaleY}).`
}

export function buildGameTools({ ctx, attachCtx, link, state }) {
  /** 附件服务在插件自己的 ctx 上；会话 ctx 没有注入 attachments。 */
  const hostCtx = attachCtx ?? ctx

  function requireArmed() {
    if (!state.armed || !state.hwnd) throw new Error('game session stopped: reconnect with /game or game_attach')
    if (!link.connected || link.hello?.engineRevision !== state.engineRevision || Number(link.hello?.pid) !== state.handPid) {
      state.armed = false
      throw new Error('hand disconnected or restarted: reconnect with /game or game_attach')
    }
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
          overlay: { type: 'boolean', description: 'Draw grid with absolute physical screen coordinates. Default false.' },
        },
        required: [],
        additionalProperties: false,
      },
      output: IMAGE_OUTPUT,
      isConcurrencySafe: () => false,
      timeoutMs: 60_000,
      async execute(args) {
        requireArmed()
        const scale = clamp(args?.scale, 0.2, 1, 0.5)
        const shot = await link.request('cap', { hwnd: state.hwnd, region: args?.region, scale, overlay: args?.overlay === true })
        const attachment = await attachPng(hostCtx, shot.path, 'game-shot.png')
        return {
          images: [attachment],
          text: `${state.title}: ${describeShot(shot)}\nshotId=${shot.shotId}; `
            + `client origin=(${shot.client.x},${shot.client.y}), size=${shot.client.w}x${shot.client.h}. `
            + 'Grid labels and game_do mouse x/y are SCREEN physical pixels. Use game_find for exact small targets.',
        }
      },
    },

    {
      name: 'game_find',
      description: 'Locate a same-scale PNG template in a fresh screenshot, returning exact SCREEN physical bounds and center (negative coordinates allowed). '
        + 'Use center.x/y directly in game_do mouse click x/y. Never auto-clicks. '
        + 'To record a template, supply a new name and record:{shotId,region:{x,y,w,h}} from game_shot; region uses CLIENT physical pixels in the unscaled original. '
        + 'Recording returns the cropped image for review. Finding accepts that name or an absolute PNG path. '
        + 'RGB score = 1 - RMSE/255; default threshold .9. Restrict region for speed. No scale/rotation invariance; recapture templates after UI scale changes.',
      parameters: {
        type: 'object',
        properties: {
          template: { type: 'string', description: 'Saved name or absolute PNG path (finding only).' },
          record: { type: 'object', properties: { shotId: { type: 'string' }, region: REGION_SCHEMA }, required: ['shotId', 'region'], additionalProperties: false },
          region: REGION_SCHEMA,
          threshold: { type: 'number', minimum: 0.8, maximum: 1 },
          maxResults: { type: 'integer', minimum: 1, maximum: 20 },
        },
        required: ['template'],
        additionalProperties: false,
      },
      output: IMAGE_OUTPUT,
      isConcurrencySafe: () => false,
      timeoutMs: 60_000,
      async execute(args) {
        requireArmed()
        if (!args?.template) throw new Error('template is required')
        const result = await link.request('find', { ...args, hwnd: state.hwnd })
        const images = result.mode === 'record' ? [await attachPng(hostCtx, result.path, `${args.template}.png`)] : []
        return { images, text: JSON.stringify(result) }
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
        + 'Mouse abs and click x/y use absolute SCREEN physical pixels, including negatives. Click x/y moves before clicking; omit both to click current position. '
        + 'Never read click coordinates from the contact sheet: it is independently rescaled. Use game_find center. '
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
        requireArmed()
        const steps = Array.isArray(args?.steps) ? args.steps : []
        if (!steps.length) throw new Error('steps must be a non-empty array')
        if (steps.length > LIMITS.maxSteps) throw new Error(`too many steps (${steps.length} > ${LIMITS.maxSteps})`)

        const wantCapture = args?.capture !== false
        const every = Math.round(clamp(args?.every, LIMITS.minEvery, 10_000, LIMITS.defaultEvery))
        const maxFrames = Math.round(clamp(args?.maxFrames, 1, LIMITS.maxFrames, 6))
        const scale = clamp(args?.scale, 0.2, 1, 0.5)
        const capture = wantCapture
          ? { hwnd: state.hwnd, region: args?.region, scale, every, maxFrames }
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
          + (result.aborted ? ' — ABORTED (F12 or action failure; see errors)' : '')]
        if (images.length) lines.push('Contact sheet is rescaled for observation; use game_shot overlay or game_find for coordinates.')
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
        state.armed = false
        try { await link.request('release', {}, { timeoutMs: 5000 }) }
        catch (error) { return { text: `session stopped; release was not confirmed: ${error.message}. Use F12 if the hand is still running.` } }
        return { text: 'all keys released. Type /game in a normal chat to reconnect.' }
      },
    },
  ]
}
